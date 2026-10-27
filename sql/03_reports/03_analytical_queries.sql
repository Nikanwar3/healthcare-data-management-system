--------------------------------------------------------------------------------
-- 03_analytical_queries.sql
--
-- Business-question analytical reports. Queries use named bind parameters
-- (:start_date / :end_date) for date-range parameters -- these are supplied
-- by the Python layer or pkg_clinical_reporting, never hardcoded literals, so
-- the reports stay correct regardless of when they are run. A psql-runnable
-- version with \set substitution variables is shown for Q1 as a template;
-- the same substitution applies to every other query here.
--
-- Note on division: COUNT(*)/SUM(...) return bigint in PostgreSQL, and
-- bigint / bigint truncates. Every percentage below multiplies by 100.0 (not
-- 100) to force numeric division before ROUND -- a one-character difference
-- that silently produces whole-number percentages if forgotten (an easy,
-- realistic bug -- see docs/root-cause-analysis.md).
--------------------------------------------------------------------------------

-- Runnable standalone (psql) parameter block:
-- \set start_date '2025-01-01'
-- \set end_date '2025-10-01'


-- Q1. "Monthly appointment statistics: how many appointments, by status,
--      per calendar month?"
SELECT DATE_TRUNC('month', a.scheduled_date)                       AS month_start,
       COUNT(*)                                                    AS total_appointments,
       SUM(CASE WHEN a.status = 'COMPLETED' THEN 1 ELSE 0 END)     AS completed,
       SUM(CASE WHEN a.status = 'CANCELLED' THEN 1 ELSE 0 END)     AS cancelled,
       SUM(CASE WHEN a.status = 'NO_SHOW'   THEN 1 ELSE 0 END)     AS no_show,
       SUM(CASE WHEN a.status = 'SCHEDULED' THEN 1 ELSE 0 END)     AS still_scheduled
FROM   appointments a
WHERE  a.scheduled_date >= :'start_date'::DATE
AND    a.scheduled_date <  :'end_date'::DATE
GROUP BY DATE_TRUNC('month', a.scheduled_date)
ORDER BY month_start;
-- Expected output: one row per calendar month in range, status columns
-- summing to total_appointments. Equivalent to
-- pkg_clinical_reporting.monthly_appointment_summary.


-- Q2. "Department-wise patient visit counts: distinct patients seen per
--      department in the window."
SELECT d.department_name,
       COUNT(DISTINCT a.patient_id) AS distinct_patients_seen,
       COUNT(*)                     AS total_appointments
FROM   departments d
JOIN   appointments a ON a.department_id = d.department_id
WHERE  a.scheduled_date >= :'start_date'::DATE
AND    a.scheduled_date <  :'end_date'::DATE
GROUP BY d.department_name
ORDER BY distinct_patients_seen DESC;


-- Q3. "Provider workload: appointment volume and completion rate per
--      provider in the window."
SELECT pr.provider_id, pr.first_name || ' ' || pr.last_name AS provider_name,
       pr.specialty,
       COUNT(*) AS total_appointments,
       SUM(CASE WHEN a.status = 'COMPLETED' THEN 1 ELSE 0 END) AS completed_appointments,
       ROUND(100.0 * SUM(CASE WHEN a.status = 'COMPLETED' THEN 1 ELSE 0 END)
             / COUNT(*), 1) AS completion_rate_pct
FROM   providers pr
JOIN   appointments a ON a.provider_id = pr.provider_id
WHERE  a.scheduled_date >= :'start_date'::DATE
AND    a.scheduled_date <  :'end_date'::DATE
GROUP BY pr.provider_id, pr.first_name, pr.last_name, pr.specialty
ORDER BY total_appointments DESC;


-- Q4. "Appointment cancellation rate, overall and by department."
SELECT d.department_name,
       COUNT(*) AS total_appointments,
       SUM(CASE WHEN a.status = 'CANCELLED' THEN 1 ELSE 0 END) AS cancelled,
       ROUND(100.0 * SUM(CASE WHEN a.status = 'CANCELLED' THEN 1 ELSE 0 END)
             / COUNT(*), 1) AS cancellation_rate_pct
FROM   departments d
JOIN   appointments a ON a.department_id = d.department_id
WHERE  a.scheduled_date >= :'start_date'::DATE
AND    a.scheduled_date <  :'end_date'::DATE
GROUP BY d.department_name
ORDER BY cancellation_rate_pct DESC;


-- Q5. "Completed vs. still-scheduled appointments, by month (operational
--      backlog indicator)."
SELECT DATE_TRUNC('month', scheduled_date) AS month_start,
       SUM(CASE WHEN status = 'COMPLETED' THEN 1 ELSE 0 END) AS completed,
       SUM(CASE WHEN status = 'SCHEDULED' THEN 1 ELSE 0 END) AS still_scheduled
FROM   appointments
WHERE  scheduled_date >= :'start_date'::DATE
AND    scheduled_date <  :'end_date'::DATE
GROUP BY DATE_TRUNC('month', scheduled_date)
ORDER BY month_start;


-- Q6. "Laboratory result summary: abnormal-result rate per test."
SELECT lo.test_name,
       COUNT(*) AS total_results,
       SUM(CASE WHEN lr.abnormal_flag <> 'NORMAL' THEN 1 ELSE 0 END) AS abnormal_results,
       ROUND(100.0 * SUM(CASE WHEN lr.abnormal_flag <> 'NORMAL' THEN 1 ELSE 0 END)
             / COUNT(*), 1) AS abnormal_rate_pct
FROM   lab_orders lo
JOIN   lab_results lr ON lr.lab_order_id = lo.lab_order_id
GROUP BY lo.test_name
ORDER BY abnormal_rate_pct DESC;
-- Business rule reminder: abnormal_flag is a recorded lab classification,
-- not a diagnosis. This report never joins to diagnoses to "explain" an
-- abnormal result -- that inference is a clinical judgment, out of scope
-- for this reporting layer.


-- Q7. "Duplicate diagnosis records: same encounter, same ICD-10 code, same
--      diagnosis_type, entered more than once."
SELECT encounter_id, icd10_code, diagnosis_type, COUNT(*) AS occurrence_count
FROM   diagnoses
GROUP BY encounter_id, icd10_code, diagnosis_type
HAVING COUNT(*) > 1
ORDER BY occurrence_count DESC, encounter_id;
-- Expected output in the seed dataset: exactly the rows intentionally
-- duplicated by 02_data/05_seed_dirty_data_demo.sql.


-- Q8. "Incomplete records: lab orders marked COMPLETED with zero result
--      rows."
SELECT lo.lab_order_id, lo.encounter_id, lo.test_name, lo.status, lo.order_date
FROM   lab_orders lo
WHERE  lo.status = 'COMPLETED'
AND    NOT EXISTS (SELECT 1 FROM lab_results lr WHERE lr.lab_order_id = lo.lab_order_id)
ORDER BY lo.order_date DESC;


-- Q9. "Missing relationships: appointments with no corresponding clinical
--      encounter despite being marked COMPLETED."
SELECT a.appointment_id, a.patient_id, a.provider_id, a.scheduled_date
FROM   appointments a
WHERE  a.status = 'COMPLETED'
AND    NOT EXISTS (
    SELECT 1 FROM clinical_encounters ce WHERE ce.appointment_id = a.appointment_id
)
ORDER BY a.scheduled_date DESC;
-- Expected output: 0 rows against appointments/clinical_encounters, because
-- 03_seed_appointments_encounters.sql always pairs the two for COMPLETED
-- status. This query is the regression test for Scenario 3 in
-- docs/root-cause-analysis.md (it would NOT be empty if that defect
-- reappeared). For *pre-load* missing-relationship detection (feed rows
-- that reference a patient/provider that doesn't exist yet), see Q10.


-- Q10. "Staging feed validation: appointment rows referencing an unknown
--       patient MRN or provider NPI, or carrying an unparsable date,
--       before they are merged into appointments."
SELECT s.stg_id, s.source_patient_mrn, s.source_provider_npi, s.scheduled_date,
       CASE WHEN s.source_patient_mrn IS NULL THEN 'Missing patient MRN'
            WHEN NOT EXISTS (SELECT 1 FROM patients p WHERE p.mrn = s.source_patient_mrn)
                THEN 'Unknown patient MRN'
       END AS patient_issue,
       CASE WHEN s.source_provider_npi IS NULL THEN 'Missing provider NPI'
            WHEN NOT EXISTS (SELECT 1 FROM providers pr WHERE pr.npi_number = s.source_provider_npi)
                THEN 'Unknown provider NPI'
       END AS provider_issue,
       CASE WHEN NOT (s.scheduled_date ~ '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$')
                THEN 'Unparsable scheduled_date: ' || s.scheduled_date
       END AS date_issue
FROM   stg_appointments_raw s
WHERE  s.source_patient_mrn IS NULL
OR     NOT EXISTS (SELECT 1 FROM patients p WHERE p.mrn = s.source_patient_mrn)
OR     s.source_provider_npi IS NULL
OR     NOT EXISTS (SELECT 1 FROM providers pr WHERE pr.npi_number = s.source_provider_npi)
OR     NOT (s.scheduled_date ~ '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$')
ORDER BY s.stg_id;
-- This is the SQL equivalent of pkg_data_quality.validate_staging_appointments.
