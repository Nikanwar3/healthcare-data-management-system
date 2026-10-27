--------------------------------------------------------------------------------
-- 05_seed_dirty_data_demo.sql
--
-- EDUCATIONAL / SIMULATED DEFECTS ONLY.
--
-- Everything inserted by this script is a deliberately broken record, added
-- so that pkg_data_quality and sql/03_reports/03_analytical_queries.sql have
-- real findings to report instead of an empty result set. Each block names
-- the specific rule it is meant to trip. Do not run this script against
-- anything other than the disposable demo database.
--------------------------------------------------------------------------------

-- 1) Duplicate diagnosis rows on the same encounter (same ICD-10 + type,
--    entered twice -- e.g. a double form submission).
INSERT INTO diagnoses (encounter_id, icd10_code, diagnosis_description, diagnosis_type, diagnosed_date)
SELECT encounter_id, icd10_code, diagnosis_description, diagnosis_type, diagnosed_date
FROM   diagnoses
WHERE  diagnosis_id = (SELECT MIN(diagnosis_id) FROM diagnoses WHERE diagnosis_type = 'PRIMARY');

INSERT INTO diagnoses (encounter_id, icd10_code, diagnosis_description, diagnosis_type, diagnosed_date)
SELECT encounter_id, icd10_code, diagnosis_description, diagnosis_type, diagnosed_date
FROM   diagnoses
WHERE  diagnosis_id = (SELECT MAX(diagnosis_id) FROM diagnoses WHERE diagnosis_type = 'PRIMARY');

-- 2) Duplicate lab result rows: same order, same value, same result date,
--    entered twice (double data entry from the instrument interface).
INSERT INTO lab_results (lab_order_id, result_value, result_unit, reference_range_low, reference_range_high, abnormal_flag, result_date, performed_by)
SELECT lab_order_id, result_value, result_unit, reference_range_low, reference_range_high, abnormal_flag, result_date, performed_by
FROM   lab_results
WHERE  lab_result_id = (SELECT MIN(lab_result_id) FROM lab_results);

-- 3) Lab result with missing reference-range information (both bounds NULL)
--    -- the test exists but no normal range was ever recorded for it.
INSERT INTO lab_results (lab_order_id, result_value, result_unit, reference_range_low, reference_range_high, abnormal_flag, result_date, performed_by)
SELECT lab_order_id, '12.4', 'ng/mL', NULL, NULL, 'NORMAL', order_date, 'Laboratory Services'
FROM   lab_orders
WHERE  lab_order_id = (SELECT MIN(lab_order_id) FROM lab_orders);

-- 4) Lab order left COMPLETED with zero associated results (data entry was
--    never finished, but the status was advanced anyway).
INSERT INTO lab_orders (encounter_id, patient_id, provider_id, order_date, test_code, test_name, priority, status)
SELECT encounter_id, patient_id, provider_id, encounter_date::DATE, 'PANEL-99', 'Standard Panel', 'ROUTINE', 'COMPLETED'
FROM   clinical_encounters
WHERE  encounter_id = (SELECT MAX(encounter_id) FROM clinical_encounters);

-- 5) Staging appointment feed rows: a mix of one clean row and several rows
--    with broken references / bad values, mirroring a raw external extract
--    that has NOT yet been validated or merged into appointments.
INSERT INTO stg_appointments_raw (source_patient_mrn, source_provider_npi, department_name, scheduled_date, appointment_type, reason) VALUES
    ('MRN000001', '1000000001', 'Cardiology', '2025-09-15 09:00', 'FOLLOW_UP', 'Routine follow-up');          -- clean
INSERT INTO stg_appointments_raw (source_patient_mrn, source_provider_npi, department_name, scheduled_date, appointment_type, reason) VALUES
    ('MRN999999', '1000000001', 'Cardiology', '2025-09-16 10:00', 'FOLLOW_UP', 'Nonexistent patient MRN');     -- unknown patient
INSERT INTO stg_appointments_raw (source_patient_mrn, source_provider_npi, department_name, scheduled_date, appointment_type, reason) VALUES
    ('MRN000002', '9999999999', 'Cardiology', '2025-09-16 11:00', 'FOLLOW_UP', 'Nonexistent provider NPI');    -- unknown provider
INSERT INTO stg_appointments_raw (source_patient_mrn, source_provider_npi, department_name, scheduled_date, appointment_type, reason) VALUES
    ('MRN000003', '1000000002', 'Cardiology', 'NOT-A-DATE',    'FOLLOW_UP', 'Malformed date from feed');       -- invalid date text
INSERT INTO stg_appointments_raw (source_patient_mrn, source_provider_npi, department_name, scheduled_date, appointment_type, reason) VALUES
    (NULL,        '1000000003', 'Family Medicine', '2025-09-17 09:30', 'NEW_PATIENT', 'Missing patient MRN'); -- missing required value
