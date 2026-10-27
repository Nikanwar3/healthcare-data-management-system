# PostgreSQL integration tests

These tests exercise real SQL/PL-pgSQL against a live PostgreSQL server:
`pkg_clinical_reporting`, `pkg_data_quality`, table/index/constraint DDL, and
the seed data scripts.

## How this differs from a typical "integration test" setup

The `pg_test_db` session fixture in `conftest.py` **creates its own disposable
database** (`POSTGRES_TEST_DB`, default `healthcare_dms_test`) by running this
project's actual `sql/01_schema/*`, `plpgsql/packages/*`, `plpgsql/views/*`,
and `sql/02_data/*` files against it, runs every test in this directory
against that database, and **drops it** when the session ends. It never
touches the `healthcare_dms` database used for interactive development.

## Running

```bash
export POSTGRES_HOST=localhost
export POSTGRES_USER=your_username
# export POSTGRES_PASSWORD=...   (omit for local trust/peer auth)
cd python
source .venv/bin/activate
pytest -m postgres tests/integration -v
```

Without `POSTGRES_HOST`/`POSTGRES_USER` pointing at a reachable server, these
tests **skip** (not fail, not pass) -- see the project README's test results
section for the actual, captured output of this exact command.

## Status in this repository

**These tests have been executed against a real, local PostgreSQL 14.18
instance** as part of building this project -- see the root README's "Test
results" section for the literal `pytest` output. This is the one part of
this project that could not be verified in the predecessor Oracle-based
version (no Oracle instance was available there); the switch to PostgreSQL
was made specifically so this class of test could actually run instead of
only being documented.
