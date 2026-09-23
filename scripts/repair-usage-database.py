#!/usr/bin/env python3
"""Restore the 0.4.x table contract without replacing the live SQLite/WAL files.

Default: inspect only. --apply requires an explicit private backup directory.
All original aggregate rows are retained in archive tables, including other
providers. No historical token amounts are inferred or reconstructed.
Reopen existing 0.4 writer connections afterwards: failed statement preparation
can retain the old schema cache even after this transaction commits.
"""
import argparse
from contextlib import closing
import datetime
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import stat
import time
import uuid

TOTAL_COLUMNS = ("day", "model", "input", "output", "cached", "requests",
                 "errors", "unknown", "nano_aiu", "credit_reports")


def columns(db, table):
    return [r[1] for r in db.execute(f"PRAGMA table_info({table})")]


def inspect(db):
    seen, totals = columns(db, "seen"), columns(db, "totals")
    def primary_key(table):
        return [r[1] for r in sorted(db.execute(f"PRAGMA table_info({table})"), key=lambda r: r[5]) if r[5]]
    if seen == ["id", "timestamp"] and set(totals) == set(TOTAL_COLUMNS):
        if primary_key("totals") != ["day", "model"] or primary_key("seen") != ["id"]:
            raise ValueError("Unexpected 0.4 primary key; no changes made.")
        return "v04"
    if set(seen) == {"id", "timestamp", "provider"} and set(totals) == set(TOTAL_COLUMNS) | {"provider"}:
        if primary_key("totals") != ["day", "provider", "model"] or primary_key("seen") != ["provider", "id"]:
            raise ValueError("Unexpected aggregate primary key; no changes made.")
        return "aggregate"
    raise ValueError("Unrecognized usage schema; no changes made.")


def verify(db):
    if db.execute("PRAGMA quick_check").fetchall() != [("ok",)]:
        raise ValueError("Database integrity check failed.")


def private_json(path, value):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(value, f, indent=2)
        f.write("\n")
        f.flush()
        os.fsync(f.fileno())


def repair(database, backup_directory=None, apply=False, checkpoint=lambda _: None):
    database = Path(database).absolute()
    info = database.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1:
        raise ValueError("Refusing a linked or non-owned database.")
    # Resolve parent aliases such as /var, not an unsafe final symlink.
    database = database.parent.resolve() / database.name
    connection = sqlite3.connect(database.as_uri() + ("?mode=rw" if apply else "?mode=ro"),
                                 uri=True, timeout=5, isolation_level=None)
    try:
        verify(connection)
        mode = inspect(connection)
        report = {"operation": "restore-v04-table-contract", "schema": mode, "applied": False}
        if not apply or mode == "v04":
            return report
        if not backup_directory:
            raise ValueError("--backup-dir is required for a repair.")
        backup_directory = Path(backup_directory).absolute()
        backup_directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        directory_info = backup_directory.lstat()
        if not stat.S_ISDIR(directory_info.st_mode) or directory_info.st_uid != os.getuid() or directory_info.st_mode & 0o077:
            raise ValueError("Backup directory must be private, owned and not a symlink.")
        stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        transaction = stamp + "-" + uuid.uuid4().hex[:12]
        backup = backup_directory / f"{transaction}.before-v04-repair.sqlite"
        archive_totals, archive_seen = "aggregate_totals_" + transaction.replace("-", "_"), "aggregate_seen_" + transaction.replace("-", "_")
        connection.execute("BEGIN IMMEDIATE")
        try:
            if inspect(connection) == "v04":
                connection.execute("ROLLBACK")
                return report | {"schema": "v04"}
            # Do not reinterpret triggers or views created by an unknown schema.
            if connection.execute("SELECT count(*) FROM sqlite_master WHERE type IN ('trigger','view')").fetchone()[0]:
                raise ValueError("Unexpected triggers/views; manual review is required.")
            expected = connection.execute(f"SELECT {','.join(TOTAL_COLUMNS)} FROM totals WHERE provider='copilot' ORDER BY day,model").fetchall()
            expected_seen = connection.execute("SELECT id,timestamp FROM seen WHERE provider='copilot' ORDER BY id").fetchall()
            quota = connection.execute("SELECT * FROM quota_history ORDER BY day").fetchall()
            # The writer lock prevents changes between backup and schema repair.
            # A separate read-only connection is used by SQLite's backup API.
            fd = os.open(backup, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            os.close(fd)
            deadline = time.monotonic() + 15
            def progress(_status, _remaining, _total):
                if time.monotonic() > deadline:
                    raise TimeoutError("Backup timed out; no schema changes made.")
            with closing(sqlite3.connect(database.as_uri() + "?mode=ro", uri=True, timeout=5)) as source:
                with closing(sqlite3.connect(backup)) as destination:
                    source.backup(destination, pages=128, sleep=0.01, progress=progress)
                    destination.execute("PRAGMA journal_mode=DELETE")
                    verify(destination)
            with backup.open("rb") as f:
                os.fsync(f.fileno())
            digest = hashlib.sha256(backup.read_bytes()).hexdigest()
            private_json(backup_directory / f"{transaction}.prepared.json", {
                **report, "database": str(database), "backup": str(backup), "sha256": digest,
                "archive_totals": archive_totals, "archive_seen": archive_seen,
            })
            directory_fd = os.open(backup_directory, os.O_RDONLY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
            checkpoint("backed-up")
            connection.execute(f"ALTER TABLE totals RENAME TO {archive_totals}")
            connection.execute(f"ALTER TABLE seen RENAME TO {archive_seen}")
            connection.execute("""CREATE TABLE totals(
                day TEXT NOT NULL, model TEXT NOT NULL,
                input INTEGER NOT NULL DEFAULT 0, output INTEGER NOT NULL DEFAULT 0,
                cached INTEGER NOT NULL DEFAULT 0, requests INTEGER NOT NULL DEFAULT 0,
                errors INTEGER NOT NULL DEFAULT 0, unknown INTEGER NOT NULL DEFAULT 0,
                nano_aiu REAL NOT NULL DEFAULT 0, credit_reports INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY(day,model))""")
            connection.execute("CREATE TABLE seen(id TEXT PRIMARY KEY,timestamp REAL NOT NULL)")
            connection.execute(f"INSERT INTO totals({','.join(TOTAL_COLUMNS)}) SELECT {','.join(TOTAL_COLUMNS)} FROM {archive_totals} WHERE provider='copilot'")
            connection.execute(f"INSERT INTO seen(id,timestamp) SELECT id,timestamp FROM {archive_seen} WHERE provider='copilot'")
            checkpoint("copied")
            if connection.execute(f"SELECT {','.join(TOTAL_COLUMNS)} FROM totals ORDER BY day,model").fetchall() != expected:
                raise ValueError("Token/billing totals changed during repair.")
            if connection.execute("SELECT id,timestamp FROM seen ORDER BY id").fetchall() != expected_seen:
                raise ValueError("Deduplication data changed during repair.")
            if connection.execute("SELECT * FROM quota_history ORDER BY day").fetchall() != quota:
                raise ValueError("Account quota history changed during repair.")
            if inspect(connection) != "v04":
                raise ValueError("The repaired schema does not match 0.4.x.")
            verify(connection)
            connection.execute("""CREATE TABLE IF NOT EXISTS usage_recovery_history(
                id TEXT PRIMARY KEY, created_at TEXT NOT NULL, operation TEXT NOT NULL,
                backup_file TEXT NOT NULL, backup_sha256 TEXT NOT NULL,
                totals_archive TEXT NOT NULL, seen_archive TEXT NOT NULL)""")
            connection.execute("INSERT INTO usage_recovery_history VALUES(?,?,?,?,?,?,?)", (
                transaction, datetime.datetime.now(datetime.timezone.utc).isoformat(), report["operation"],
                str(backup), digest, archive_totals, archive_seen))
            checkpoint("before-commit")
            connection.execute("COMMIT")
            return report | {"applied": True, "schema": "v04", "backup": str(backup),
                             "sha256": digest, "copilot_rows": len(expected),
                             "reopen_writers": True,
                             "quota_days": len(quota), "archive_totals": archive_totals, "archive_seen": archive_seen}
        except BaseException:
            if connection.in_transaction:
                connection.execute("ROLLBACK")
            raise
    finally:
        connection.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--database", type=Path, required=True)
    parser.add_argument("--backup-dir", type=Path)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    print(json.dumps(repair(args.database, args.backup_dir, args.apply), indent=2))
