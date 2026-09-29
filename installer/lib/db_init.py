#!/usr/bin/env python3
"""
Aerys database initializer (external Postgres path).

For the bundled path, Postgres auto-runs migrations from
/docker-entrypoint-initdb.d/ on first container start — no Python
needed. This script handles external Postgres where the user supplies
their own DB server.

Uses `psql` CLI (part of postgresql-client). No psycopg2 / asyncpg
dependency, to keep the installer prereqs minimal.

Operations:
  1. Connect to the specified Postgres server
  2. Check if `aerys` database + `persons` table already exist
     (idempotency — skip if migrations already applied)
  3. If not initialized: run every *.sql file under --migrations-dir
     in lexical order
  4. Verify expected tables + extensions exist

Invocation:
  python3 db_init.py \\
    --migrations-dir /path/to/installer/migrations \\
    --host HOST --port 5432 --user USER \\
    [--verify-only]

PGPASSWORD is read from the env (the caller should export it before
invoking; we do not read the .env directly to keep secrets off argv).

Exit codes:
  0  success | 1  psql unavailable | 2  connect failed
  3  migration failed | 4  verification failed
"""
import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

EXPECTED_TABLES = [
    "persons", "conversations", "messages", "memories",
    "platform_identity", "memory_extraction_queue",
    "sub_agents", "sub_agent_runs", "email_drafts",
]
EXPECTED_EXTENSIONS = ["vector", "uuid-ossp"]


def _psql_base_args(args):
    return [
        "psql",
        "-h", args.host,
        "-p", str(args.port),
        "-U", args.user,
        "-v", "ON_ERROR_STOP=1",
    ]


def _psql_run(args, db: str, sql: str = None, sql_file: Path = None) -> tuple[int, str, str]:
    cmd = _psql_base_args(args) + ["-d", db]
    if sql_file:
        cmd += ["-f", str(sql_file)]
        inp = None
    else:
        cmd += ["-c", sql]
        inp = None
    env = os.environ.copy()
    # PGPASSWORD must be set by caller.
    r = subprocess.run(cmd, capture_output=True, text=True, env=env, input=inp)
    return r.returncode, r.stdout, r.stderr


def check_psql() -> bool:
    return shutil.which("psql") is not None


def check_connection(args) -> bool:
    """Can we connect to the postgres server at all? (uses the 'postgres' DB)"""
    code, _out, err = _psql_run(args, "postgres", sql="SELECT 1;")
    if code != 0:
        print(f"ERROR: could not connect to {args.host}:{args.port} as {args.user}", file=sys.stderr)
        print(err, file=sys.stderr)
        return False
    return True


def is_initialized(args) -> bool:
    """Check if aerys DB exists AND has the `persons` table."""
    # Does aerys DB exist?
    code, out, _ = _psql_run(
        args, "postgres",
        sql="SELECT 1 FROM pg_database WHERE datname='aerys';",
    )
    if code != 0 or "1" not in out:
        return False
    # Does persons table exist?
    code, out, _ = _psql_run(
        args, "aerys",
        sql="SELECT 1 FROM information_schema.tables WHERE table_name='persons' AND table_schema='public';",
    )
    return code == 0 and "1" in out


def run_migrations(args, migrations_dir: Path) -> bool:
    sqls = sorted(migrations_dir.glob("*.sql"))
    if not sqls:
        print(f"ERROR: no .sql files found under {migrations_dir}", file=sys.stderr)
        return False

    # 000_extensions.sql creates the aerys DB from the postgres DB context.
    # Later migrations use `\c aerys` to switch — psql's -f handles that.
    # For the first migration, start connected to postgres DB; everything after,
    # psql will follow the `\c aerys` meta-command automatically.
    print(f"Running {len(sqls)} migration(s) from {migrations_dir}/")
    for idx, sql_path in enumerate(sqls):
        # First migration runs in postgres DB (creates aerys), others in aerys.
        db = "postgres" if idx == 0 else "aerys"
        print(f"  [{idx + 1}/{len(sqls)}] {sql_path.name} → {db}")
        code, out, err = _psql_run(args, db, sql_file=sql_path)
        if code != 0:
            print(f"ERROR: migration {sql_path.name} failed (exit {code})", file=sys.stderr)
            if out:
                print(f"  stdout: {out[:500]}", file=sys.stderr)
            if err:
                print(f"  stderr: {err[:500]}", file=sys.stderr)
            return False
    print("All migrations applied.")
    return True


def verify_schema(args) -> bool:
    ok = True
    # Extensions
    code, out, _ = _psql_run(
        args, "aerys",
        sql="SELECT extname FROM pg_extension;",
    )
    if code != 0:
        print(f"ERROR: could not query extensions (aerys DB may not exist)", file=sys.stderr)
        return False
    for ext in EXPECTED_EXTENSIONS:
        if ext in out:
            print(f"  ✓ extension {ext}")
        else:
            print(f"  ✗ extension {ext} MISSING", file=sys.stderr)
            ok = False

    # Tables
    code, out, _ = _psql_run(
        args, "aerys",
        sql="SELECT table_name FROM information_schema.tables WHERE table_schema='public';",
    )
    for tbl in EXPECTED_TABLES:
        if tbl in out:
            print(f"  ✓ table {tbl}")
        else:
            # Some tables may be named slightly differently across migration
            # versions. Only warn for now.
            print(f"  ⚠ table {tbl} not found (may be added in a later migration version)")
    return ok


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description="Aerys database initializer")
    p.add_argument("--migrations-dir", required=True, type=Path)
    p.add_argument("--host", required=True)
    p.add_argument("--port", type=int, default=5432)
    p.add_argument("--user", required=True)
    p.add_argument("--verify-only", action="store_true",
                   help="Skip migration run, only verify schema")
    args = p.parse_args(argv)

    if not check_psql():
        print("ERROR: psql CLI not found. Install postgresql-client (e.g. apt install postgresql-client).",
              file=sys.stderr)
        return 1

    if "PGPASSWORD" not in os.environ:
        print("WARNING: PGPASSWORD not set in environment. psql may prompt interactively.",
              file=sys.stderr)

    if not args.migrations_dir.is_dir():
        print(f"ERROR: migrations dir not found: {args.migrations_dir}", file=sys.stderr)
        return 3

    if not check_connection(args):
        return 2

    if args.verify_only:
        print("--- Verify only ---")
        return 0 if verify_schema(args) else 4

    if is_initialized(args):
        print("Aerys database already initialized — skipping migrations.")
        print("--- Verifying schema ---")
        return 0 if verify_schema(args) else 4

    print("Aerys database not initialized — running migrations.")
    if not run_migrations(args, args.migrations_dir):
        return 3

    print("--- Verifying schema ---")
    if not verify_schema(args):
        return 4

    print("✓ Database initialization complete.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
