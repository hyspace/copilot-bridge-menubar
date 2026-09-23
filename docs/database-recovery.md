# 0.4 database recovery and maintenance

The shelved provider-aggregation preview previously changed the shared database
from `(day, model)` totals and two-column `seen` rows to provider-aware keys.
Running 0.4.0 against that schema fails with
`table seen has 3 columns but 2 values were supplied`. This is a persistence
failure, not a GitHub credit API parameter error or simply a heatmap refresh delay.

The maintained 0.4 app refuses incompatible schemas before migration or cleanup.
Its insert names `seen(id,timestamp)` explicitly. Provider aggregation is not
part of this maintenance branch and must use its own database.

## Explicit repair

Inspect first (read-only):

```sh
python3 scripts/repair-usage-database.py \
  --database "$HOME/Library/Application Support/CopilotBridgeMenuBar/usage.sqlite"
```

Apply only after confirming no aggregate-version process remains:

```sh
python3 scripts/repair-usage-database.py \
  --database "$HOME/Library/Application Support/CopilotBridgeMenuBar/usage.sqlite" \
  --backup-dir "$HOME/Library/Application Support/CopilotBridgeMenuBar/DatabaseBackups" \
  --apply
```

The utility:

1. Rejects unknown schemas, unexpected primary keys, triggers/views, non-owned
   files, symlinks and hard links.
2. Takes a short SQLite writer lock. It backs up through the SQLite backup API,
   including committed WAL data, and verifies integrity before changing tables.
   The backup has mode `0600` in an owner-only directory. A prepared manifest
   records its SHA-256.
3. Archives the complete provider-aware tables under unique names, preserving
   every provider. Copies only Copilot totals and deduplication IDs to the
   original 0.4 table layout.
4. Preserves quota history, provider quota history, prior migration artifacts
   and legacy tables. It verifies active totals, IDs and quota snapshots
   before atomically committing and recording the backup in
   `usage_recovery_history`.
5. Rolls back every schema/data change on failure. Re-running an already repaired
   database is a no-op.

It does **not** replace or unlink the live database/WAL files, restart the app,
or create estimated token/credit history. **Restart 0.4 after a successful repair
to reopen its writer connection**, preferably when no requests are active.
Failed statement preparation can retain the old three-column schema in a live
connection even after the database file has been repaired. A successful schema
read also refreshes it, but 0.4 has no explicit hot-reload control for its writer.
The utility reports `reopen_writers: true`; a repaired file alone is not proof
that the running writer has recovered. Verify new usage and diagnostics after
the controlled restart. Run repairs with 0.4 only; an old
aggregate executable can still reopen or remigrate shared data and is unsafe.

Old migration markers/legacy tables remain for preservation. A future aggregate
importer must recognize these recovery artifacts in its **separate** database,
rather than blindly rerunning its original in-place migration.

## Limits of historical recovery

Original 0.4 consumes authenticated usage events without logging their numeric
fields. On a failed SQLite write it logged only the error, losing that event.
Request counts, HTTP 200 responses or account balance differences are not enough
to reconstruct token amounts or per-request billing. Missing history must not
be filled with fabricated zeroes or account-wide balance deltas.

The maintenance build adds a private, bounded `UsageRecovery` journal of typed
usage metadata, retry and deduplication. It contains no prompt/response bodies
or channel credentials. Old/corrupt entries remain for explicit recovery; they
are never force-imported past the deduplication window.

## Validation

```sh
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-database-repair.py
swift test --disable-sandbox
```

Tests cover a primed failed-prepare cache and reopened writer, WAL-inclusive backups, rollback after
an injected failure, unchanged quota history, other-provider preservation,
idempotency, invalid schemas/links, journal replay and crash-after-commit dedup.
Native tests use temporary roots and random ports, never the real 4142 listener.

New quota failure logs contain the stage (`network`, `http`, `decode`, `persist`,
`history`), HTTP status when available, attempt ID, elapsed time, and error
domain/code. They exclude response bodies and credentials.
