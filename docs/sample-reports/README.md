# Sample report outputs

**This is real, captured output from this project's own seed data**, run
against a local PostgreSQL 14.18 instance — not hand-constructed or
estimated. Because `sql/02_data/03_seed_appointments_encounters.sql` assigns
appointment status/dates using PostgreSQL's `random()` by design (see that
file's header comment), exact counts will differ slightly on a fresh
re-seed; the shapes, column names, and internal consistency (e.g. status
columns summing to totals) will not.

## Monthly appointment summary (`pkg_clinical_reporting.monthly_appointment_summary`)

```sql
SELECT * FROM pkg_clinical_reporting.monthly_appointment_summary('2025-01-01', '2025-04-01');
```

| month_start | total_appointments | completed | cancelled | no_show | still_scheduled |
|---|---|---|---|---|---|
| 2025-01-01 | 146 | 91 | 29 | 12 | 14 |
| 2025-02-01 | 142 | 95 | 16 | 13 | 18 |
| 2025-03-01 | 138 | 82 | 24 | 19 | 13 |

## Department workload summary (`pkg_clinical_reporting.department_workload_summary`)

```sql
SELECT * FROM pkg_clinical_reporting.department_workload_summary('2025-01-01', '2025-10-01', 1);
```

| department_id | department_name | total_appointments | distinct_patients_seen | completed_appointments | completion_rate_pct |
|---|---|---|---|---|---|
| 1 | Cardiology | 213 | 57 | 138 | 64.8 |

## Cancellation analysis (`pkg_clinical_reporting.cancellation_analysis`)

```sql
SELECT * FROM pkg_clinical_reporting.cancellation_analysis('2025-01-01', '2025-10-01');
```

| department_name | cancellation_rate_pct | cancelled_missing_reason |
|---|---|---|
| Cardiology | 17.8 | 14 |
| Laboratory Services | 17.3 | 9 |
| Orthopedics | 15.3 | 15 |
| Family Medicine | 15.1 | 20 |
| Pediatrics | 14.5 | 12 |
| Endocrinology | 11.4 | 13 |

## Data-quality findings (`pkg_data_quality.run_all_checks`)

```sql
SELECT severity, COUNT(*) FROM pkg_data_quality.run_all_checks() GROUP BY severity;
```

| severity | finding_count |
|---|---|
| WARNING | 206 |
| ERROR | 1 |

The single guaranteed `ERROR` is `INCOMPLETE_LAB_ORDER` — seeded
deterministically by `sql/02_data/05_seed_dirty_data_demo.sql`.

## Staging validation (`pkg_data_quality.validate_staging_appointments`)

```sql
SELECT rule_name, entity_id, finding_description FROM pkg_data_quality.validate_staging_appointments();
```

| rule_name | entity_id | finding_description |
|---|---|---|
| STAGING_UNKNOWN_PATIENT | 2 | source_patient_mrn MRN999999 does not match any patient. |
| STAGING_UNKNOWN_PROVIDER | 3 | source_provider_npi 9999999999 does not match any provider. |
| STAGING_INVALID_DATE | 4 | scheduled_date 'NOT-A-DATE' is not in YYYY-MM-DD HH24:MI format. |
| STAGING_MISSING_PATIENT_MRN | 5 | Row has no source_patient_mrn value. |

Deterministic and exactly reproducible on every re-seed (these five staging
rows, unlike the random appointment volume, are hardcoded in
`sql/02_data/05_seed_dirty_data_demo.sql`). `stg_id = 1` is the deliberately
clean row and produces zero findings — verified in both
`plpgsql/examples/02_call_data_quality.sql` and
`python/tests/integration/test_postgres_integration.py`.
