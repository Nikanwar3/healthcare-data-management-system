--------------------------------------------------------------------------------
-- 02_create_indexes.sql
--
-- Indexes supporting the query patterns used throughout sql/03_reports and
-- plpgsql/packages. Every foreign key gets a supporting index (PostgreSQL,
-- like Oracle, does NOT auto-index FK columns, unlike primary keys), plus a
-- handful of composite indexes aimed at specific report shapes.
--------------------------------------------------------------------------------

-- Foreign-key lookup indexes -------------------------------------------------
CREATE INDEX idx_providers_department        ON providers (department_id);

CREATE INDEX idx_appointments_patient        ON appointments (patient_id);
CREATE INDEX idx_appointments_provider       ON appointments (provider_id);
CREATE INDEX idx_appointments_department     ON appointments (department_id);

CREATE INDEX idx_encounters_appointment      ON clinical_encounters (appointment_id);
CREATE INDEX idx_encounters_patient          ON clinical_encounters (patient_id);
CREATE INDEX idx_encounters_provider         ON clinical_encounters (provider_id);

CREATE INDEX idx_diagnoses_encounter         ON diagnoses (encounter_id);

CREATE INDEX idx_lab_orders_encounter        ON lab_orders (encounter_id);
CREATE INDEX idx_lab_orders_patient          ON lab_orders (patient_id);
CREATE INDEX idx_lab_orders_provider         ON lab_orders (provider_id);

CREATE INDEX idx_lab_results_order           ON lab_results (lab_order_id);

-- Report-pattern indexes -----------------------------------------------------

-- Monthly appointment summaries and date-range filtering (03_reports/03, 04).
CREATE INDEX idx_appointments_scheduled_date ON appointments (scheduled_date);

-- Appointment status breakdowns (completed vs. cancelled vs. no-show).
CREATE INDEX idx_appointments_status         ON appointments (status);

-- Provider workload summaries: "this provider's appointments, in date order".
CREATE INDEX idx_appointments_provider_date  ON appointments (provider_id, scheduled_date);

-- Department-wise workload over a date range.
CREATE INDEX idx_appointments_dept_date      ON appointments (department_id, scheduled_date);

-- Duplicate/abnormal lab-result detection and lab summary reports.
CREATE INDEX idx_lab_results_abnormal        ON lab_results (abnormal_flag);

-- ICD-10 frequency analysis.
CREATE INDEX idx_diagnoses_icd10             ON diagnoses (icd10_code);

-- Patient lookups by MRN are already covered by the UNIQUE constraint's
-- implicit index (uq_patients_mrn) -- no separate index needed.
