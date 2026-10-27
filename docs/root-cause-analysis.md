# Root-cause analysis: debugging scenarios

**Scenarios 1-3 are deliberately constructed, educational examples.** None
of them describes a bug that actually occurred in this project's history --
they exist to demonstrate debugging and root-cause methodology against this
specific schema, the way a real defect in this domain would present and get
resolved. Each scenario gives the buggy SQL side by side with the fix so the
difference is concrete, not hypothetical. **Scenario 4 is different: it is a
genuine bug in this project's own first draft**, found and fixed by actually
running the code against a live database -- see its section for the real
commands and output.

---

## Scenario 1: Incorrect appointment totals caused by an inappropriate join

### Symptoms
A "total appointments per provider" report is handed to clinic
administrators. Providers who are newly hired, or who had a slow month,
appear to have *zero* appointments -- even providers known to have a full
schedule show suspiciously low counts. The numbers also silently shrink
further whenever a provider's appointments happen not to have an associated
`clinical_encounters` row yet (e.g. anything not yet marked COMPLETED).

### Reproduction
```sql
-- BUGGY: INNER JOIN to clinical_encounters silently drops every
-- appointment that hasn't produced an encounter yet (anything SCHEDULED,
-- CANCELLED, or NO_SHOW -- which, per the seed mix in
-- 02_data/03_seed_appointments_encounters.sql, is ~35% of all appointments).
SELECT pr.provider_id, pr.first_name, pr.last_name, COUNT(*) AS appointment_count
FROM   providers pr
JOIN   appointments a       ON a.provider_id = pr.provider_id
JOIN   clinical_encounters ce ON ce.appointment_id = a.appointment_id
GROUP BY pr.provider_id, pr.first_name, pr.last_name;
```
Run this against the seed data and compare to the real appointment count per
provider (`SELECT provider_id, COUNT(*) FROM appointments GROUP BY
provider_id`) -- the buggy query undercounts every provider by roughly a
third, and silently omits any provider whose appointments are *all*
non-COMPLETED (zero rows returned for that provider instead of a `0`).

### Root cause
The second `JOIN` is an `INNER JOIN` against a table that only has a row
for *completed* appointments (`clinical_encounters.appointment_id` is
populated only when an appointment reaches `COMPLETED` status -- see
`sql/01_schema/01_create_tables.sql`). An `INNER JOIN` requires a match in
*both* tables, so any appointment without an encounter is excluded from the
result entirely -- not counted as zero, simply absent, which makes the bug
easy to miss in a quick visual scan of the output.

### Fix
Either drop the join entirely (appointment counts don't need encounter data)
or, if encounter-level fields are genuinely needed, use `LEFT JOIN` so
every appointment is retained regardless of whether it has a matching
encounter:
```sql
-- FIXED: LEFT JOIN keeps every appointment; encounter columns are NULL
-- for appointments that never reached COMPLETED.
SELECT pr.provider_id, pr.first_name, pr.last_name, COUNT(a.appointment_id) AS appointment_count
FROM   providers pr
JOIN   appointments a         ON a.provider_id = pr.provider_id
LEFT JOIN clinical_encounters ce ON ce.appointment_id = a.appointment_id
GROUP BY pr.provider_id, pr.first_name, pr.last_name;
```
This is exactly the reasoning already applied in
`sql/03_reports/02_relational_queries.sql` Q2 ("list every provider together
with their encounter count, including providers who have never seen a
patient") and in `plpgsql/packages/pkg_clinical_reporting.sql`'s
`provider_workload_summary`, which joins `providers` to `appointments`
directly and never touches `clinical_encounters` at all for a pure
appointment-count report.

### Regression test
```sql
-- Sum of per-provider appointment counts must equal the grand total --
-- this fails under the buggy INNER JOIN version and passes under the fix.
SELECT
    (SELECT COUNT(*) FROM appointments) AS grand_total,
    (SELECT SUM(appointment_count) FROM (
        SELECT pr.provider_id, COUNT(a.appointment_id) AS appointment_count
        FROM   providers pr
        JOIN   appointments a ON a.provider_id = pr.provider_id
        GROUP BY pr.provider_id
    ) t) AS summed_total;
-- Expected: grand_total = summed_total. A mismatch means a report query
-- somewhere is dropping appointments via an inappropriate join.
```

---

## Scenario 2: Duplicate report rows caused by a one-to-many relationship

### Symptoms
A report meant to show "one row per appointment, with diagnosis
information" is handed to someone who then computes "total appointments" by
counting rows in the report output (`SELECT COUNT(*) FROM report_output`).
The number comes out *higher* than the true appointment count from
`appointments` directly -- sometimes dramatically so for patients with
multiple diagnoses per visit.

### Reproduction
```sql
-- BUGGY (as a counting source): this is a legitimate detail report (see
-- sql/03_reports/02_relational_queries.sql Q3) -- the bug is in how its
-- output gets (mis)used downstream, not in the query itself.
SELECT a.appointment_id, a.scheduled_date, d.icd10_code, d.diagnosis_type
FROM   appointments a
JOIN   clinical_encounters ce ON ce.appointment_id = a.appointment_id
JOIN   diagnoses d            ON d.encounter_id = ce.encounter_id
WHERE  a.status = 'COMPLETED';

-- Someone then runs:
SELECT COUNT(*) FROM ( <query above> );  -- WRONG way to count appointments
```
Any completed appointment whose encounter has both a PRIMARY and a
SECONDARY diagnosis (seeded for ~35% of encounters, see
`sql/02_data/04_seed_diagnoses_labs.sql`) appears **twice** in this result
set -- once per diagnosis row -- because the join to `diagnoses` fans out
one encounter into N rows.

### Root cause
`clinical_encounters` to `diagnoses` is a one-to-many relationship. A join
across a one-to-many relationship is correct when the goal is "one row per
diagnosis" (which is what this query actually produces), but it stops being
a valid source for "one row per appointment" the moment any encounter has
more than one diagnosis. The query itself has no bug; the defect is
treating its fanned-out row count as if it still meant "appointment count."

### Fix
Count distinct appointments explicitly, never `COUNT(*)` over a fanned-out
join:
```sql
-- FIXED: COUNT(DISTINCT appointment_id) is immune to the diagnosis fan-out.
SELECT COUNT(DISTINCT a.appointment_id) AS true_appointment_count
FROM   appointments a
JOIN   clinical_encounters ce ON ce.appointment_id = a.appointment_id
JOIN   diagnoses d            ON d.encounter_id = ce.encounter_id
WHERE  a.status = 'COMPLETED';
```
or, better, compute the appointment count from `appointments` directly and
treat the diagnosis-joined query purely as a detail/drill-down view, never
as a counting source -- which is why
`sql/03_reports/02_relational_queries.sql` Q3 is explicitly commented as "an
intentional fan-out join" and why none of `pkg_clinical_reporting`'s
aggregate procedures join through to `diagnoses` at all.

### Regression test
```sql
-- The fanned-out detail view's distinct appointment count must match the
-- appointment table's own count for the same filter.
SELECT
    (SELECT COUNT(*) FROM appointments WHERE status = 'COMPLETED') AS direct_count,
    (SELECT COUNT(DISTINCT a.appointment_id)
     FROM   appointments a
     JOIN   clinical_encounters ce ON ce.appointment_id = a.appointment_id
     JOIN   diagnoses d            ON d.encounter_id = ce.encounter_id
     WHERE  a.status = 'COMPLETED') AS joined_distinct_count;
-- Expected: direct_count = joined_distinct_count. (A plain, non-DISTINCT
-- COUNT(*) over the joined query would NOT match -- that mismatch is the bug.)
```

---

## Scenario 3: A database operation failing because of an invalid foreign-key reference

### Symptoms
An appointment-booking operation fails with an unhandled PostgreSQL error
instead of a clear "that provider doesn't exist" message. In the Python
layer, this would otherwise surface as a raw `psycopg2.errors.
ForeignKeyViolation` traceback if not translated (see
`healthcare_app.db.connection._translate_postgres_error`).

### Reproduction
```sql
-- Simulated/educational: provider_id 999999 does not exist.
INSERT INTO appointments (patient_id, provider_id, department_id, scheduled_date, appointment_type, status)
VALUES (1, 999999, 1, CURRENT_DATE + 7, 'FOLLOW_UP', 'SCHEDULED');
```
```
ERROR:  insert or update on table "appointments" violates foreign key constraint "fk_appointments_provider"
DETAIL:  Key (provider_id)=(999999) is not present in table "providers".
```
(Verified against this project's actual schema -- SQLSTATE `23503`,
`foreign_key_violation`.)

### Root cause
The calling code (application or ad hoc script) supplied a `provider_id`
that does not exist in `providers`, and the foreign key
`fk_appointments_provider` correctly rejected the insert. This is the
constraint working as designed -- the "defect" being analyzed here is that,
upstream of this point, nothing validated the provider reference *before*
attempting the insert, so the failure surfaces late, as a generic
constraint violation, instead of early with a specific, actionable message.
This is exactly the class of problem `stg_appointments_raw` and
`pkg_data_quality.validate_staging_appointments` exist to catch pre-emptively
(see `sql/01_schema/03_create_staging.sql`) for feed-driven appointment
creation, and why `pkg_clinical_reporting.validate_provider` (helper in
`plpgsql/packages/pkg_clinical_reporting.sql`) checks `provider_id`
existence explicitly, with a custom SQLSTATE (`HC002`), rather than letting
every caller rediscover this failure mode by hitting `23503` directly.

### Fix
1. **Validate before writing**, using the existing
   `pkg_data_quality.validate_staging_appointments` pre-merge check for
   feed-driven inserts (and `pkg_data_quality.merge_staging_appointment`,
   which does exactly this before every insert it performs), or an
   existence check before any direct insert:
   ```sql
   DO $$
   DECLARE
       v_provider_exists INTEGER;
   BEGIN
       SELECT COUNT(*) INTO v_provider_exists FROM providers WHERE provider_id = 999999;
       IF v_provider_exists = 0 THEN
           RAISE EXCEPTION 'provider_id 999999 does not exist.' USING ERRCODE = 'HC002';
       END IF;
       -- proceed with INSERT ...
   END $$;
   ```
2. **Translate the error at the application boundary** so it never reaches
   an end user as a raw SQLSTATE -- already implemented in
   `healthcare_app.db.connection._translate_postgres_error`, which maps
   `HC002` to `InvalidIdentifierError`. A plain `23503` from a direct
   constraint violation (as opposed to the package's own validation) is
   intentionally left as a generic `ReportExecutionError` in this project,
   since fixing the real defect is "validate first," not "parse more
   PostgreSQL error codes" -- see
   `python/tests/unit/test_db_connection.py::TestTranslatePostgresError`.

### Regression test
`python/tests/integration/test_postgres_integration.py
::test_department_workload_summary_rejects_unknown_department` and
`::test_merge_staging_appointment_unknown_stg_id_raises` are the live,
**actually passing** versions of this regression test (see the root README's
"Test results" for the captured `pytest` run). The equivalent standalone
SQL check:
```sql
DO $$
BEGIN
    INSERT INTO appointments (patient_id, provider_id, department_id, scheduled_date, appointment_type, status)
    VALUES (1, 999999, 1, CURRENT_DATE + 7, 'FOLLOW_UP', 'SCHEDULED');
    RAISE EXCEPTION 'Regression test FAILED: insert with an invalid provider_id should have been rejected.';
EXCEPTION
    WHEN foreign_key_violation THEN
        RAISE NOTICE 'Regression test PASSED: invalid provider_id was correctly rejected (23503).';
END $$;
```

---

## Scenario 4: A real bug found while building this project -- an incorrect assumption about PL/pgSQL transaction durability

Unlike Scenarios 1–3 above, this one is not a constructed teaching example.
It is a genuine defect in this project's own first draft, found by actually
running the code against a live PostgreSQL instance.

### Symptoms
`pkg_clinical_reporting`'s functions log every execution to
`report_execution_log`, including a `FAILURE` row when parameter validation
rejects bad input. The first draft's header comment claimed this would work
"the same way" as Oracle's `PRAGMA AUTONOMOUS_TRANSACTION` -- a logging
`INSERT` that survives even if the error that triggered it later aborts the
whole transaction. Live testing showed otherwise: after deliberately calling
`monthly_appointment_summary()` with an inverted date range (expected to
fail and log a `FAILURE` row), `report_execution_log` contained **zero**
`FAILURE` rows.

### Reproduction
```sql
-- Exact commands used to catch this:
SELECT * FROM pkg_clinical_reporting.monthly_appointment_summary('2025-06-01', '2025-01-01');
-- ERROR: start_date (2025-06-01) must not be after end_date (2025-01-01).
SELECT COUNT(*) FROM report_execution_log WHERE status = 'FAILURE';
--  count
-- -------
--      0
```
Even wrapping the call in an outer handler that catches the error and
continues does not help:
```sql
DO $$
BEGIN
    PERFORM * FROM pkg_clinical_reporting.monthly_appointment_summary('2025-06-01', '2025-01-01');
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Caught at caller level: %', SQLERRM;
END $$;
SELECT COUNT(*) FROM report_execution_log WHERE status = 'FAILURE';
--  count
-- -------
--      0
```

### Root cause
PL/pgSQL wraps every `BEGIN ... EXCEPTION ... END` block in an implicit
savepoint. Entering the exception handler rolls back to that savepoint
*before* the handler runs -- so the handler's own `log_execution()` INSERT
executes against a clean state. But that rollback-to-savepoint is not a
commit: the INSERT is still part of the same, still-open transaction. When
the function re-raises (`RAISE;`) and nothing eventually absorbs the error --
or even when an *outer* caller catches it, because the outer block's own
savepoint was taken *before* the inner function was ever called -- rolling
back to that outer savepoint undoes every nested statement since then,
including the inner handler's INSERT. Savepoints nest; rolling back to an
outer one erases everything nested inside it, regardless of what an inner
handler already did. True autonomous-transaction behavior requires a
separate physical connection (`dblink`/`postgres_fdw`) to commit
independently -- there is no way to get it from savepoints alone.

### Fix
Given the choice between (a) adding `dblink` as a dependency to chase full
parity with Oracle's audit-log guarantee for a non-critical audit trail, or
(b) documenting the real, tested behavior accurately, this project chose
(b): the misleading comment was rewritten to describe exactly what was
verified (see the "Audit-log durability note" at the top of
`plpgsql/packages/pkg_clinical_reporting.sql`), and the root README's "Known,
real, documented limitations" section states it plainly instead of silently
assuming the Oracle-equivalent behavior. No code change was needed once the
actual, tested semantics were understood -- the `SUCCESS`-path logging
(the common case) was never affected, only the `FAILURE`-path one.

### Regression test
There is no automated test asserting the *absence* of a `FAILURE` row --
that would be testing PostgreSQL's own documented transaction semantics, not
this project's code. Instead, the exact verification commands above are
preserved in `plpgsql/examples/01_call_clinical_reporting.sql`'s closing
comment, so anyone can re-run them and see the same result.
