#!/usr/bin/env python3
import importlib.util
from contextlib import closing
import hashlib
import os
from pathlib import Path
import sqlite3
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("repair", Path(__file__).with_name("repair-usage-database.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class RepairTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="cbm-repair-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.path = self.root / "usage.sqlite"
        self.db = sqlite3.connect(self.path, isolation_level=None)
        self.addCleanup(self.db.close)
        self.db.executescript("""
            PRAGMA journal_mode=WAL;
            CREATE TABLE totals(day TEXT,provider TEXT,model TEXT,input INTEGER,output INTEGER,
              cached INTEGER,requests INTEGER,errors INTEGER,unknown INTEGER,nano_aiu REAL,credit_reports INTEGER,
              PRIMARY KEY(day,provider,model));
            INSERT INTO totals VALUES('2026-09-10','copilot','model',100,20,10,1,0,0,125000000,1);
            INSERT INTO totals VALUES('2026-09-10','local','model',300,40,0,1,0,0,0,0);
            CREATE TABLE seen(id TEXT,timestamp REAL,provider TEXT,PRIMARY KEY(provider,id));
            INSERT INTO seen VALUES('same',1,'copilot');
            INSERT INTO seen VALUES('same',2,'local');
            CREATE TABLE quota_history(day TEXT PRIMARY KEY,observed_at REAL,snapshot TEXT);
            INSERT INTO quota_history VALUES('2026-09-22',1,'{\"remaining\":10}');
        """)

    def test_dry_run_does_not_change_schema(self):
        self.assertFalse(module.repair(self.path)["applied"])
        self.assertEqual(module.inspect(self.db), "aggregate")

    def test_repair_preserves_all_data_and_existing_connection_can_write(self):
        result = module.repair(self.path, self.root / "backups", True)
        self.assertTrue(result["applied"])
        self.assertTrue(result["reopen_writers"])
        # A schema-reading statement refreshes this connection's cache. Do not
        # mistake this test for proof that an unmodified 0.4 writer hot-reloads.
        self.assertEqual(module.inspect(self.db), "v04")
        self.db.execute("INSERT INTO seen VALUES('new',3)")
        self.db.execute("""INSERT INTO totals(day,model,input) VALUES('2026-09-22','model',1)
                          ON CONFLICT(day,model) DO UPDATE SET input=input+excluded.input""")
        self.assertEqual(self.db.execute("SELECT input FROM totals WHERE day='2026-09-10'").fetchone()[0], 100)
        self.assertEqual(self.db.execute(f"SELECT count(*) FROM {result['archive_totals']}").fetchone()[0], 2)
        self.assertEqual(self.db.execute("SELECT count(*) FROM quota_history").fetchone()[0], 1)
        self.assertEqual(hashlib.sha256(Path(result["backup"]).read_bytes()).hexdigest(), result["sha256"])
        self.assertEqual(os.stat(result["backup"]).st_mode & 0o777, 0o600)
        with closing(sqlite3.connect(result["backup"])) as backup:
            self.assertEqual(module.inspect(backup), "aggregate")
            self.assertEqual(backup.execute("SELECT sum(input) FROM totals").fetchone()[0], 400)
        self.assertFalse(module.repair(self.path, self.root / "backups", True)["applied"])

    def test_primed_old_writer_recovers_after_reopening_not_just_file_repair(self):
        def old_write(db):
            db.execute("BEGIN IMMEDIATE")
            try:
                db.execute("INSERT OR IGNORE INTO seen VALUES('old-writer',3)")
            finally:
                db.execute("ROLLBACK")
        with self.assertRaises(sqlite3.DatabaseError):
            old_write(self.db)  # Prime the failed-prepare schema cache used by 0.4.
        module.repair(self.path, self.root / "backups", True)
        # SQLite versions differ on eager invalidation of failed prepares. The
        # supported post-repair guarantee is a reopened connection.
        with closing(sqlite3.connect(self.path, isolation_level=None)) as fresh:
            old_write(fresh)
        self.assertEqual(module.inspect(self.db), "v04")
        old_write(self.db)  # Explicit schema refresh also works for controllable clients.

    def test_failure_rolls_back_every_schema_and_data_change(self):
        def fail(stage):
            if stage == "copied":
                raise RuntimeError("injected failure")
        with self.assertRaises(RuntimeError):
            module.repair(self.path, self.root / "backups", True, fail)
        self.assertEqual(module.inspect(self.db), "aggregate")
        self.assertEqual(self.db.execute("SELECT sum(input) FROM totals").fetchone()[0], 400)

    def test_unknown_schema_or_links_fail_closed(self):
        link = self.root / "linked.sqlite"
        link.symlink_to(self.path)
        with self.assertRaises(ValueError):
            module.repair(link, self.root / "backups", True)
        self.db.execute("ALTER TABLE seen ADD COLUMN unexpected TEXT")
        with self.assertRaises(ValueError):
            module.repair(self.path, self.root / "backups", True)
        self.assertEqual(self.db.execute("SELECT count(*) FROM totals").fetchone()[0], 2)

    def test_wrong_primary_key_fails_closed(self):
        self.db.executescript("""
            DROP TABLE seen;
            CREATE TABLE seen(id TEXT,timestamp REAL,provider TEXT,PRIMARY KEY(id));
        """)
        with self.assertRaises(ValueError):
            module.repair(self.path, self.root / "backups", True)

    def test_non_private_backup_directory_fails_closed(self):
        directory = self.root / "backups"
        directory.mkdir(mode=0o755)
        with self.assertRaises(ValueError):
            module.repair(self.path, directory, True)
        self.assertEqual(module.inspect(self.db), "aggregate")


if __name__ == "__main__":
    unittest.main()
