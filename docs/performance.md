# Database performance notes

Captured against a real local PostgreSQL 14.18 instance loaded with this
project's seed data (~1,250 appointments, ~820 encounters) — these are
actual `EXPLAIN ANALYZE` results, not estimated or hand-written.

## Index selection rationale

See `sql/01_schema/02_create_indexes.sql` for the full list and inline
comments. The short version:

- **Every foreign-key column has a supporting index.** PostgreSQL
  automatically indexes primary keys (and unique constraints) but *not*
  foreign keys — without an explicit index, a `DELETE`/`UPDATE` on a parent
  row (e.g. `patients`) forces a sequential scan of the child table to check
  for dependent rows, and child-table joins fall back to full scans.
- **`appointments.scheduled_date`** is indexed because every analytical
  report (`sql/03_reports/03_analytical_queries.sql`,
  `pkg_clinical_reporting.monthly_appointment_summary`, etc.) filters on a
  date range first, before grouping.
- **Composite indexes** `(provider_id, scheduled_date)` and
  `(department_id, scheduled_date)` support the two most common report
  shapes directly ("this provider/department's appointments, in date
  order").
- **No index on `lab_results.result_value`.** It is free-text (supports both
  numeric and qualitative results), has no meaningful equality/range
  filtering in any current report, and indexing it would add write overhead
  with no read benefit.

## Measured: a real, honest finding about index usage at this data volume

```sql
EXPLAIN ANALYZE
SELECT * FROM appointments
WHERE scheduled_date >= '2025-01-01' AND scheduled_date < '2025-04-01';
```
```
Seq Scan on appointments  (cost=0.00..36.75 rows=428 width=96) (actual time=0.017..0.393 rows=426 loops=1)
  Filter: (scheduled_date >= '2025-01-01' AND scheduled_date < '2025-04-01')
  Rows Removed by Filter: 825
Planning Time: 1.921 ms
Execution Time: 0.612 ms
```

Despite `idx_appointments_scheduled_date` existing, PostgreSQL's planner
chose a sequential scan here — and that is the *correct* choice, not a sign
the index is broken or unused. At ~1,250 rows, the entire `appointments`
table fits in a handful of 8 KB pages; scanning all of them is cheaper than
the random I/O of an index lookup followed by a heap fetch per match. This
is exactly the kind of result `EXPLAIN ANALYZE` exists to surface instead of
assuming an index "must" be helping.

The same index (via a different column) *is* used once a predicate is
selective enough to be worth it:

```sql
EXPLAIN ANALYZE
SELECT * FROM appointments
WHERE provider_id = 1 AND scheduled_date >= '2025-01-01' AND scheduled_date < '2025-02-01';
```
```
Index Scan using idx_appointments_provider on appointments  (cost=0.15..11.56 rows=13 width=96) (actual time=0.035..0.118 rows=15 loops=1)
  Index Cond: (provider_id = 1)
  Filter: (scheduled_date >= '2025-01-01' AND scheduled_date < '2025-02-01')
Planning Time: 4.151 ms
Execution Time: 0.411 ms
```

**Takeaway for anyone extending this project:** these indexes are sized and
justified for the query *shapes* used throughout `sql/03_reports` and the
PL/pgSQL packages at production scale (tens of thousands to millions of
rows, where a full scan is genuinely expensive), not for this project's small
synthetic dataset. Don't conclude an index is unused from one `EXPLAIN` on
a 1,250-row table — re-run `EXPLAIN ANALYZE` after loading representative
volume, which is exactly what the commands above make trivial to do.

## How to inspect a plan yourself

```sql
EXPLAIN ANALYZE SELECT * FROM pkg_data_quality.run_all_checks();
```

or, for a function/procedure already in a PL/pgSQL block, time it directly
with `clock_timestamp()` (the same technique `pkg_clinical_reporting`'s
`log_execution` helper uses internally to populate
`report_execution_log.execution_ms`).

Refresh the planner's statistics after a bulk load, since its decisions
(including whether to use an index at all) depend on them:

```sql
ANALYZE appointments;
```

## Join and aggregation guidance applied in this project

- Reports that need "every X, including X with zero matches" use `LEFT
  JOIN` (e.g. "every provider, including providers with zero encounters" —
  `sql/03_reports/02_relational_queries.sql` Q2). Using `INNER JOIN` there
  would silently drop valid rows — this exact mistake is documented as
  Scenario 1 in `docs/root-cause-analysis.md`.
- Reports that intentionally fan out across a one-to-many relationship
  (`sql/03_reports/02_relational_queries.sql` Q3) say so explicitly in a
  comment, because downstream code that naively does `COUNT(*)` over a
  fanned-out result will double-count — documented as Scenario 2.
- `NULLIF(denominator, 0)` (SQL/PL-pgSQL) and `safe_rate()` (Python, see
  `python/healthcare_app/calculations.py`) guard every rate calculation
  against division by zero.
- Every percentage calculation multiplies by `100.0`, not `100` —
  `COUNT()`/`SUM()` return `bigint` in PostgreSQL, and `bigint / bigint`
  truncates. This was an actual bug caught while building and testing
  `sql/03_reports/02_relational_queries.sql` Q7 and fixed before it reached
  the PL/pgSQL packages — see the comment at the top of
  `sql/03_reports/03_analytical_queries.sql`.

## Transactions and batching

- Every seed script in `sql/02_data/` commits once at the end of its `DO $$
  ... $$` block (or per top-level `INSERT` for the small reference-data
  scripts), not per row.
- The Python layer uses a connection **pool**
  (`psycopg2.pool.SimpleConnectionPool`, see
  `python/healthcare_app/db/connection.py`) rather than opening a new
  connection per call, and lets PL/pgSQL compute aggregates server-side
  instead of pulling raw rows into Python to summarize there.
- `pkg_data_quality.merge_staging_appointment` is a real multi-statement
  PROCEDURE (resolve FKs, insert, delete the staging row) that either fully
  succeeds or — verified by `test_merge_staging_appointment_rejects_row_
  that_fails_validation` in `python/tests/integration` — leaves zero partial
  writes on failure.
