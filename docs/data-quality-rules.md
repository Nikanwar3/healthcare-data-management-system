# Data-quality rules

This document is the single source of truth for what each
`pkg_data_quality` rule means, why it exists, and whether it is an ERROR
(blocks downstream use) or a WARNING (needs human review but does not by
itself invalidate the record). The PL/pgSQL implementation is in
`plpgsql/packages/pkg_data_quality.sql`; this file explains the reasoning,
not the syntax.

## Severity contract

| Severity | Meaning | Example consequence |
|---|---|---|
| **ERROR**   | The record is unsafe to use as-is downstream. | A staging appointment row with an unknown patient MRN must not be merged into `appointments` until corrected. |
| **WARNING** | Worth a human's attention; does not block processing. | A cancelled appointment with no `cancelled_reason` is still a valid, usable appointment record -- it's an operational gap, not a data-integrity failure. |

## Rules

| Rule | Severity | What it checks | Why |
|---|---|---|---|
| `DUPLICATE_PATIENT_IDENTIFIER` | ERROR | `UPPER(TRIM(mrn))` collides across two patient rows | The DB's `UNIQUE` constraint on `patients.mrn` already blocks an exact duplicate string; this catches the near-duplicates (case/whitespace) that constraint cannot see. |
| `MISSING_CONTACT_INFO` | WARNING | Patient has neither `phone` nor `email` | Operationally inconvenient, not a data-integrity defect -- patients can legitimately have no contact info on file at registration. |
| `INVALID_APPOINTMENT_DATE` | ERROR | Appointment `scheduled_date` is before the patient's `date_of_birth` | A logical impossibility; the record cannot be correct as entered. |
| `STALE_SCHEDULED_APPOINTMENT` | WARNING | `status = 'SCHEDULED'` but `scheduled_date` has already passed | Almost always means the record was never closed out (no-show, completed, cancelled) -- an operational backlog, not invalid data. |
| `MISSING_CANCELLATION_REASON` | WARNING | `status = 'CANCELLED'` but `cancelled_reason IS NULL` | Deliberately not a CHECK constraint (see `sql/01_schema/01_create_tables.sql`) -- missing the reason doesn't make the cancellation itself invalid. |
| `DUPLICATE_DIAGNOSIS` | WARNING | Same `(encounter_id, icd10_code, diagnosis_type)` recorded more than once | Usually a double form submission. Left un-constrained in the schema on purpose so this check has real work to do -- see the comment on the `diagnoses` table. |
| `DUPLICATE_LAB_RESULT` | WARNING | Same `(lab_order_id, result_value, result_date)` recorded more than once | Could be a genuine repeat draw or a duplicate data entry -- flagged for a human to distinguish, not auto-resolved. |
| `MISSING_REFERENCE_RANGE` | WARNING | `lab_results.reference_range_low` and `_high` both NULL | The recorded `abnormal_flag` can't be independently verified without a range on file. |
| `RESULT_ON_CANCELLED_ORDER` | ERROR | A `lab_results` row exists for a `lab_orders` row whose `status = 'CANCELLED'` | A cancelled order should produce no results; this is an inconsistent state that needs correction on one side or the other. |
| `INCOMPLETE_LAB_ORDER` | ERROR | `lab_orders.status = 'COMPLETED'` with zero `lab_results` rows | The order claims to be done but has no data to back that up. |
| `STAGING_MISSING_PATIENT_MRN` / `STAGING_UNKNOWN_PATIENT` | ERROR | Staging row has no MRN, or the MRN doesn't match any patient | Pre-merge gate: this row cannot be turned into a valid `appointments` row yet. |
| `STAGING_MISSING_PROVIDER_NPI` / `STAGING_UNKNOWN_PROVIDER` | ERROR | Same, for the provider NPI | Same reasoning. |
| `STAGING_INVALID_DATE` | ERROR | `scheduled_date` text doesn't match `YYYY-MM-DD HH24:MI` | Can't be parsed into a `DATE` at merge time. |

## What this project deliberately does *not* do

- **It never infers a diagnosis from an abnormal lab value.** `abnormal_flag`
  on `lab_results` is a recorded classification (set by the ordering/
  resulting workflow), not something this reporting layer derives, and no
  query here joins an abnormal result to a diagnosis to "explain" it. That
  judgment belongs to a clinician.
- **It does not flag every lab result outside its reference range as an
  error.** `HIGH`/`LOW`/`CRITICAL` are expected, routine clinical outcomes --
  only the *absence* of a reference range, or inconsistency with a cancelled
  order, is treated as a data-quality issue.
