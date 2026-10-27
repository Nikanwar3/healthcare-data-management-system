--------------------------------------------------------------------------------
-- 06_validate_data.sql
--
-- Post-load sanity checks: row counts per table and a handful of structural
-- spot-checks. This is NOT the data-quality rule engine (see pkg_data_quality
-- and sql/03_reports/03_analytical_queries.sql for that) -- it only confirms
-- the seed scripts ran and produced a plausible volume of data.
--------------------------------------------------------------------------------

SELECT 'departments' AS table_name, COUNT(*) AS row_count FROM departments
UNION ALL SELECT 'providers', COUNT(*) FROM providers
UNION ALL SELECT 'patients', COUNT(*) FROM patients
UNION ALL SELECT 'appointments', COUNT(*) FROM appointments
UNION ALL SELECT 'clinical_encounters', COUNT(*) FROM clinical_encounters
UNION ALL SELECT 'diagnoses', COUNT(*) FROM diagnoses
UNION ALL SELECT 'lab_orders', COUNT(*) FROM lab_orders
UNION ALL SELECT 'lab_results', COUNT(*) FROM lab_results
UNION ALL SELECT 'stg_appointments_raw', COUNT(*) FROM stg_appointments_raw
UNION ALL SELECT 'report_execution_log', COUNT(*) FROM report_execution_log
ORDER BY table_name;

-- Appointment status distribution -- confirms the seed mix (65/15/10/10).
SELECT status, COUNT(*) AS appointment_count,
       ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct_of_total
FROM   appointments
GROUP BY status
ORDER BY appointment_count DESC;

-- Every COMPLETED appointment should have exactly one encounter.
SELECT a.appointment_id
FROM   appointments a
LEFT JOIN clinical_encounters ce ON ce.appointment_id = a.appointment_id
WHERE  a.status = 'COMPLETED'
AND    ce.encounter_id IS NULL;
-- Expect 0 rows. If this returns rows, 03_seed_appointments_encounters.sql
-- did not run to completion.

-- Every encounter should have at least one PRIMARY diagnosis.
SELECT ce.encounter_id
FROM   clinical_encounters ce
WHERE  NOT EXISTS (
    SELECT 1 FROM diagnoses d
    WHERE  d.encounter_id = ce.encounter_id
    AND    d.diagnosis_type = 'PRIMARY'
);
-- Expect 0 rows.

-- Lab results should always trace back to a lab order (guaranteed by the FK,
-- this just confirms volume looks right).
SELECT COUNT(*) AS orders_with_results
FROM   lab_orders lo
WHERE  EXISTS (SELECT 1 FROM lab_results lr WHERE lr.lab_order_id = lo.lab_order_id);
