# Architecture

## Layers

```
sql/             PostgreSQL DDL (schema, indexes, staging), seed data, ad hoc reporting SQL.
plpgsql/         PL/pgSQL composite type, "packages" (schema-scoped function/procedure groups), views, example calls.
python/
  healthcare_app/  Application layer: config, db connectivity, services, exporters, CLI.
  tests/           pytest unit tests (no DB) + integration tests (real, disposable PostgreSQL database).
docs/            This document, root-cause-analysis.md, performance notes, data-quality rules.
```

## Design principle: push logic down to the database, keep Python thin

Aggregation, business rules, and data-quality checks live in SQL/PL-pgSQL
(`pkg_clinical_reporting`, `pkg_data_quality`), not in Python. The Python
layer's job is connectivity, parameter marshaling, exception translation, and
export formatting -- not re-implementing report math in a second language.
`python/tests/unit` verifies that plumbing without a database;
`python/tests/integration` verifies the SQL/PL-pgSQL is actually correct, by
running it against a real, disposable PostgreSQL database built from this
project's own scripts (see `python/tests/integration/README.md`).

## Why PostgreSQL, not Oracle

An earlier version of this project targeted Oracle Database. No Oracle
instance (local install or Docker) was available in this project's
development environment, so that version's PL/SQL and integration tests were
written to spec but never executed -- a real, documented limitation. This
version targets PostgreSQL 14+ instead specifically so every claim below, and
every test in `python/tests/integration`, could be verified by actually
running it, not just reviewed by eye. PL/pgSQL is close enough to Oracle
PL/SQL (same block structure, cursors, exception handling, `%TYPE`/`%ROWTYPE`)
that the skill being demonstrated -- procedural SQL with real business logic,
not just DDL -- transfers directly.

## "Packages" in PostgreSQL

PostgreSQL has no `CREATE PACKAGE`. This project models an Oracle package as
a dedicated PostgreSQL **schema** holding related functions/procedures:
`pkg_clinical_reporting.monthly_appointment_summary(...)` reads the same as
Oracle's `package.procedure` dotted call syntax and needs no translation on
the Python call sites. See the header comments in
`plpgsql/packages/pkg_clinical_reporting.sql` and
`plpgsql/packages/pkg_data_quality.sql` for the full set of mapping decisions
(SYS_REFCURSOR -> RETURNS TABLE, PIPELINED functions -> RETURNS SETOF,
RAISE_APPLICATION_ERROR -> RAISE EXCEPTION ... USING ERRCODE).

## Request flow (reporting)

```
CLI
   -> healthcare_app.services.ReportingService / DataQualityService
       -> healthcare_app.db.connection.PostgresDatabase
           -> psycopg2
               -> pkg_clinical_reporting / pkg_data_quality (PL/pgSQL)
                   -> tables/views (SQL)
```

Reporting functions `RETURNS TABLE`; data-quality checks `RETURNS SETOF
pkg_data_quality.dq_finding`. Both map directly onto `list[dict]` in Python
via `psycopg2.extras.RealDictCursor` (see `PostgresDatabase.call_function`).
One function (`pkg_clinical_reporting.department_workload_cursor_demo`) is
additionally implemented as a PROCEDURE with an explicit `INOUT refcursor`
parameter -- PostgreSQL's literal equivalent of Oracle's `SYS_REFCURSOR OUT`
pattern -- kept alongside the simpler `RETURNS TABLE` version specifically to
demonstrate that pattern too (see `plpgsql/examples/01_call_clinical_reporting.sql`).

## Schema overview

```
departments ---< providers ---< appointments >--- patients
                                     |
                                     v (1:1 once completed)
                            clinical_encounters ---< diagnoses
                                     |
                                     +---< lab_orders ---< lab_results

stg_appointments_raw   (unvalidated landing table, no FKs -- see sql/01_schema/03_create_staging.sql)
report_execution_log   (audit trail written by the PL/pgSQL packages)
```

Full column-level detail lives in `sql/01_schema/01_create_tables.sql`,
commented inline with the reasoning behind each constraint choice (e.g. why
`appointments.cancelled_reason` is NOT constrained by a CHECK).

## Why no triggers

Primary keys use `GENERATED ALWAYS AS IDENTITY` (PostgreSQL 10+, same syntax
as Oracle 12c+) instead of a `SERIAL`/sequence + `BEFORE INSERT` trigger
pattern, and `report_execution_log` is written explicitly by the PL/pgSQL
functions rather than via an audit trigger. Both choices are deliberate: a
trigger that exists only to add a technology to the list, rather than to
satisfy a requirement the rest of the design couldn't meet more simply, is
unneeded surface area.

## Why a staging table, and a real merge procedure

`sql/01_schema/03_create_staging.sql` explains the staging table in full, but
briefly: `appointments` enforces referential integrity via foreign keys, so a
validation routine run against *production* appointment rows can never find
an appointment referencing a nonexistent patient/provider -- the constraint
already prevents that state from existing. `stg_appointments_raw` models the
pre-merge landing zone for an external feed, where that validation is a real
and necessary step. `pkg_data_quality.validate_staging_appointments`
demonstrates it, and `pkg_data_quality.merge_staging_appointment` goes one
step further than the project's Oracle predecessor: it's a real stored
PROCEDURE that re-validates a row, resolves its foreign keys, inserts the
appointment, and removes the staging row -- atomically, as one transaction.

## A genuine, tested difference from Oracle: audit-log durability

Oracle's `PRAGMA AUTONOMOUS_TRANSACTION` lets a logging `INSERT` survive even
if the calling transaction later rolls back. PostgreSQL has no equivalent
without an extension (dblink/postgres_fdw), which this project deliberately
does not add. Live testing (not assumption) showed that PL/pgSQL's implicit
per-block savepoint does *not* give the same guarantee for a FAILURE-path
audit row once the triggering error is re-raised to an aborting transaction.
The full writeup, including the exact commands used to verify it, is in the
header comment of `plpgsql/packages/pkg_clinical_reporting.sql` and in
`docs/root-cause-analysis.md` Scenario 4.
