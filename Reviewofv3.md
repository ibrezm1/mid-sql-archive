Here’s a focused review—this is a solid pattern, but a few sharp edges are worth tightening.

---

### Overall design

- **Good stuff:**
  - **Metadata-driven:** `ArchiveConfig` + `ProcessingLog` is clean and extensible.
  - **Dynamic SQL hardening:** `QUOTENAME` for identifiers and `sp_executesql` with parameters for values is the right pattern.
  - **Linked server support:** `TargetLinkedServer` + `TargetFullName` construction is clear and flexible.
  - **Central logging:** `ProcessingLog` with `DurationMs` and `ErrorMessage` gives you good observability.

- **Main risk area:** Transaction handling with `BEGIN DISTRIBUTED TRANSACTION` inside dynamic SQL and error handling outside it.

---

### Transaction and error handling

This is the biggest thing I’d revisit.

- **Distributed transaction scope:**
  - `BEGIN DISTRIBUTED TRANSACTION` and `COMMIT TRANSACTION` live *inside* the dynamic SQL.
  - The `CATCH` block in the outer script does `IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;`—but the transaction is started and committed inside the dynamic batch, so:
    - On success, `@@TRANCOUNT` is likely `0` in the outer scope.
    - On failure inside the dynamic SQL, you may end up with:
      - An uncommitted distributed transaction, or
      - A rollback that already happened inside the dynamic batch (if you add it later), making the outer `ROLLBACK` a no-op or error-prone.

- **Recommendation:**
  - Move **TRY/CATCH and rollback logic inside the dynamic SQL** around the `BEGIN DISTRIBUTED TRANSACTION` block, e.g.:

    ```sql
    BEGIN TRY
        BEGIN DISTRIBUTED TRANSACTION;

        -- INSERT/DELETE batch

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW; -- bubble up to outer CATCH if you want
    END CATCH;
    ```

  - Or: avoid `BEGIN DISTRIBUTED TRANSACTION` unless you actually need cross-server atomicity; for local-only operations, a normal `BEGIN TRANSACTION` outside the dynamic SQL is simpler and safer.

---

### Test mode logic

Right now there’s some leftover/hacky bits:

- **Inside the TEST block:**

  ```sql
  SET @SQL = N'
      SELECT @RowsOut = COUNT(*) 
      FROM ... WHERE ... < @CutoffDate;';

  EXEC sp_executesql @SQL, @Params, @BatchSize, @CutoffDate, @RowsOut = @SQL OUTPUT;
  ```

  - `@Params` doesn’t define `@RowsOut`.
  - `@RowsOut = @SQL OUTPUT` is clearly wrong (and you later “fix” it with `@CountSQL`).

- **Then later:**

  ```sql
  IF @TestMode = 1
  BEGIN
      DECLARE @CountSQL NVARCHAR(MAX) = N'SELECT @Cnt = COUNT(*) FROM ... WHERE ... < @CutoffDate';
      EXEC sp_executesql @CountSQL, N'@CutoffDate DATETIME, @Cnt INT OUTPUT', @CutoffDate, @Cnt = @TotalRowsAffected OUTPUT;
  END
  ```

- **Recommendation:**
  - Drop the earlier `@SQL`/`@Params` test-mode block entirely and keep only the clean `@CountSQL` version:

    ```sql
    IF @TestMode = 1
    BEGIN
        DECLARE @CountSQL NVARCHAR(MAX) =
            N'SELECT @Cnt = COUNT(*) FROM ' + QUOTENAME(@SourceSchema) + '.' + QUOTENAME(@SourceTable) +
            ' WHERE ' + QUOTENAME(@DateColumn) + ' < @CutoffDate';

        EXEC sp_executesql
            @CountSQL,
            N'@CutoffDate DATETIME, @Cnt INT OUTPUT',
            @CutoffDate,
            @Cnt = @TotalRowsAffected OUTPUT;

        SET @LogActionType = 'TEST-' + @ActionType;
    END
    ```

  - You don’t need `@BatchSize` in test mode at all.

---

### Dynamic SQL and looping

- **Loop inside dynamic SQL:**
  - You’re doing:

    ```sql
    DECLARE @RowsAffected INT = 1;
    DECLARE @Total INT = 0;

    WHILE @RowsAffected > 0
    BEGIN
        BEGIN DISTRIBUTED TRANSACTION;
        -- INSERT/DELETE TOP (@BatchSize)
        SET @RowsAffected = @@ROWCOUNT;
        SET @Total = @Total + @RowsAffected;
        COMMIT TRANSACTION;
        IF @RowsAffected > 0 WAITFOR DELAY '00:00:00.100';
    END
    SET @RowsOut = @Total;
    ```

  - This is logically fine, but:
    - Long-running loops inside a single dynamic batch can be harder to monitor/kill.
    - You only log once per config, not per batch iteration—so you lose granularity.

- **Alternative pattern (optional improvement):**
  - Keep the loop in the outer T-SQL, and let the dynamic SQL do **one batch at a time**:
    - Easier to:
      - Log per batch if you want.
      - Adjust delays.
      - Handle partial failures.

If you’re happy with coarse logging and a single “big” operation per table, your current pattern is acceptable—just be aware of the tradeoff.

---

### Metadata and safety

- **Identifiers:**
  - `SourceSchema`, `SourceTable`, `DateColumn`, `TargetSchema`, `TargetTable`, `TargetLinkedServer`, `TargetDatabase` are all used via `QUOTENAME`—good.
  - Still, you should treat `ArchiveConfig` as **admin-only**; if untrusted users can write to it, they can still cause mischief (e.g., pointing to unexpected tables).

- **Date column:**
  - You assume `DateColumn` exists and is comparable to `DATETIME`.
  - If someone misconfigures it (e.g., typo, non-date column), you’ll get runtime errors.
  - Optional hardening:
    - Pre-validation step that checks `COL_LENGTH` / `INFORMATION_SCHEMA.COLUMNS` for existence and type, and logs a config error instead of failing mid-run.

- **Retention logic:**
  - `SET @CutoffDate = DATEADD(DAY, -@RetentionDays, GETDATE());` is fine.
  - You might want a check like `IF @RetentionDays <= 0` → log and skip, to avoid accidental “delete everything” configs.

---

### Logging and observability

- **Good:**
  - `BatchNumber` per run and `ProcessingOrder` per config give you a nice timeline.
  - `DurationMs` and `RowsAffected` are exactly what you want for trend analysis.

- **Possible enhancements:**
  - **Per-iteration logging** (optional): if you ever need to debug performance or throttling, logging per batch iteration (e.g., every N batches) can help.
  - **Include target info in log:** adding `TargetTable` or `TargetLinkedServer` to `ProcessingLog` can be useful when the same source table has multiple archive targets.

---

### Linked server specifics

- **Target name construction:**

  ```sql
  IF @TargetLinkedServer IS NOT NULL AND @TargetTable IS NOT NULL
      SET @TargetFullName = [linked].[db].[schema].[table]
  ELSE IF @TargetTable IS NOT NULL
      SET @TargetFullName = [db].[schema].[table]
  ```

  - Works fine for `ARCHIVE`.
  - For `DELETE`, `@TargetFullName` is unused, which is okay but slightly confusing—could be set only when `@ActionType = 'ARCHIVE'` for clarity.

- **Operational note:**
  - `BEGIN DISTRIBUTED TRANSACTION` will require MSDTC and proper linked server configuration; if this is run in environments where that’s not guaranteed, you may want:
    - A flag in `ArchiveConfig` like `UseDistributedTran BIT`, or
    - Logic that uses local `BEGIN TRANSACTION` when `@TargetLinkedServer IS NULL`.

---

If you want, next step we can refactor this into two clean “engines”:

1. A **local-only engine** (no distributed transactions, simpler error handling).
2. A **cross-server engine** (explicit distributed transaction handling with TRY/CATCH inside the dynamic SQL).

That separation often makes the code easier to reason about and safer to operate.