--------------------------------------------------------------------------------
-- 01_create_tables.sql
--
-- Healthcare Data Management and Clinical Reporting System
-- Normalized relational schema for a synthetic healthcare organization.
--
-- Target: PostgreSQL 13+ (developed and tested against PostgreSQL 14.18).
--   - Uses GENERATED ALWAYS AS IDENTITY columns (PostgreSQL 10+), the same
--     syntax Oracle 12c+ uses, instead of the classic SERIAL/sequence +
--     trigger pattern -- no trigger exists only to pad a technology list.
--   - scheduled_date/encounter_date are TIMESTAMP (not DATE) because
--     appointments carry a time-of-day component; every other date column
--     (date_of_birth, hire_date, diagnosed_date, order_date, result_date) is
--     plain DATE since no time component is meaningful for them.
--
-- Run as a regular database role with CREATE privileges on the target
-- database (e.g. `psql -d healthcare_dms -f 01_create_tables.sql`).
-- Safe to re-run: see 00_drop_schema.sql to tear everything down first.
--------------------------------------------------------------------------------

-- ============================================================================
-- DEPARTMENTS
-- Hospital/clinic departments (e.g. Cardiology, Radiology).
-- ============================================================================
CREATE TABLE departments (
    department_id    INTEGER        GENERATED ALWAYS AS IDENTITY
                                     CONSTRAINT pk_departments PRIMARY KEY,
    department_name  VARCHAR(100)   NOT NULL,
    location         VARCHAR(100),
    phone            VARCHAR(20),
    created_at       TIMESTAMP      DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT uq_departments_name UNIQUE (department_name)
);

COMMENT ON TABLE departments IS 'Clinical/administrative departments within the organization.';

-- ============================================================================
-- PROVIDERS
-- Clinicians (physicians, nurse practitioners, etc.) who deliver care.
-- ============================================================================
CREATE TABLE providers (
    provider_id    INTEGER        GENERATED ALWAYS AS IDENTITY
                                   CONSTRAINT pk_providers PRIMARY KEY,
    npi_number     VARCHAR(10)    NOT NULL,
    first_name     VARCHAR(50)    NOT NULL,
    last_name      VARCHAR(50)    NOT NULL,
    specialty      VARCHAR(100)   NOT NULL,
    department_id  INTEGER        NOT NULL,
    email          VARCHAR(100),
    phone          VARCHAR(20),
    is_active      CHAR(1)        DEFAULT 'Y' NOT NULL,
    hire_date      DATE           NOT NULL,
    created_at     TIMESTAMP      DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT uq_providers_npi UNIQUE (npi_number),
    CONSTRAINT uq_providers_email UNIQUE (email),
    CONSTRAINT ck_providers_npi_format CHECK (npi_number ~ '^\d{10}$'),
    CONSTRAINT ck_providers_is_active CHECK (is_active IN ('Y', 'N')),
    CONSTRAINT fk_providers_department FOREIGN KEY (department_id)
        REFERENCES departments (department_id)
);

COMMENT ON TABLE providers IS 'Clinicians who see patients and order services.';
COMMENT ON COLUMN providers.npi_number IS 'National Provider Identifier, 10 digits (synthetic, not validated against the real NPPES registry).';

-- ============================================================================
-- PATIENTS
-- Synthetic patient demographic records only. No real PII/PHI is stored.
-- ============================================================================
CREATE TABLE patients (
    patient_id          INTEGER        GENERATED ALWAYS AS IDENTITY
                                       CONSTRAINT pk_patients PRIMARY KEY,
    mrn                 VARCHAR(12)    NOT NULL,
    first_name          VARCHAR(50)    NOT NULL,
    last_name           VARCHAR(50)    NOT NULL,
    date_of_birth       DATE           NOT NULL,
    gender              CHAR(1),
    phone               VARCHAR(20),
    email               VARCHAR(100),
    insurance_provider  VARCHAR(100),
    created_at          TIMESTAMP      DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT uq_patients_mrn UNIQUE (mrn),
    CONSTRAINT ck_patients_gender CHECK (gender IN ('M', 'F', 'O', 'U'))
);

COMMENT ON TABLE patients IS 'Synthetic patient demographic records (MRN = Medical Record Number). No real patient data.';
COMMENT ON COLUMN patients.gender IS 'M=Male, F=Female, O=Other, U=Unknown/Not disclosed.';

-- ============================================================================
-- APPOINTMENTS
-- Scheduled visits linking a patient, provider, and department.
-- ============================================================================
CREATE TABLE appointments (
    appointment_id    INTEGER        GENERATED ALWAYS AS IDENTITY
                                     CONSTRAINT pk_appointments PRIMARY KEY,
    patient_id        INTEGER        NOT NULL,
    provider_id       INTEGER        NOT NULL,
    department_id     INTEGER        NOT NULL,
    scheduled_date    TIMESTAMP      NOT NULL,
    appointment_type  VARCHAR(30)    NOT NULL,
    status            VARCHAR(20)    DEFAULT 'SCHEDULED' NOT NULL,
    reason            VARCHAR(200),
    cancelled_reason  VARCHAR(200),
    created_at        TIMESTAMP      DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT fk_appointments_patient FOREIGN KEY (patient_id)
        REFERENCES patients (patient_id),
    CONSTRAINT fk_appointments_provider FOREIGN KEY (provider_id)
        REFERENCES providers (provider_id),
    CONSTRAINT fk_appointments_department FOREIGN KEY (department_id)
        REFERENCES departments (department_id),
    CONSTRAINT ck_appointments_type CHECK (appointment_type IN
        ('NEW_PATIENT', 'FOLLOW_UP', 'ANNUAL_PHYSICAL', 'URGENT', 'TELEHEALTH', 'PROCEDURE')),
    CONSTRAINT ck_appointments_status CHECK (status IN
        ('SCHEDULED', 'COMPLETED', 'CANCELLED', 'NO_SHOW'))
);

COMMENT ON TABLE appointments IS 'Scheduled patient visits. status drives downstream reporting (completed vs. cancelled vs. no-show).';
COMMENT ON COLUMN appointments.cancelled_reason IS 'Expected to be populated when status = CANCELLED. Deliberately NOT enforced by a CHECK constraint so the data-quality package (pkg_data_quality) has a real, non-trivial business rule to detect -- see docs/root-cause-analysis.md.';

-- ============================================================================
-- CLINICAL_ENCOUNTERS
-- The actual clinical visit/documentation tied to a completed appointment.
-- ============================================================================
CREATE TABLE clinical_encounters (
    encounter_id      INTEGER        GENERATED ALWAYS AS IDENTITY
                                     CONSTRAINT pk_encounters PRIMARY KEY,
    appointment_id    INTEGER        NOT NULL,
    patient_id        INTEGER        NOT NULL,
    provider_id       INTEGER        NOT NULL,
    encounter_date    TIMESTAMP      NOT NULL,
    encounter_type    VARCHAR(30)    NOT NULL,
    chief_complaint   VARCHAR(200),
    notes             VARCHAR(1000),
    encounter_status  VARCHAR(20)    DEFAULT 'OPEN' NOT NULL,
    created_at        TIMESTAMP      DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT uq_encounters_appointment UNIQUE (appointment_id),
    CONSTRAINT fk_encounters_appointment FOREIGN KEY (appointment_id)
        REFERENCES appointments (appointment_id),
    CONSTRAINT fk_encounters_patient FOREIGN KEY (patient_id)
        REFERENCES patients (patient_id),
    CONSTRAINT fk_encounters_provider FOREIGN KEY (provider_id)
        REFERENCES providers (provider_id),
    CONSTRAINT ck_encounters_type CHECK (encounter_type IN
        ('OFFICE_VISIT', 'TELEHEALTH', 'EMERGENCY', 'INPATIENT')),
    CONSTRAINT ck_encounters_status CHECK (encounter_status IN
        ('OPEN', 'CLOSED', 'AMENDED'))
);

COMMENT ON TABLE clinical_encounters IS 'One encounter per completed appointment (enforced by UNIQUE on appointment_id). Deliberately minimal clinical notes field to avoid storing unnecessary sensitive detail.';

-- ============================================================================
-- DIAGNOSES
-- ICD-10 coded diagnoses recorded during an encounter.
-- No UNIQUE constraint on (encounter_id, icd10_code): duplicate diagnosis
-- rows are a realistic data-entry error, and pkg_data_quality.detect_
-- duplicate_diagnoses() is the mechanism intended to catch them, not a
-- hard constraint that would mask the scenario entirely.
-- ============================================================================
CREATE TABLE diagnoses (
    diagnosis_id            INTEGER        GENERATED ALWAYS AS IDENTITY
                                           CONSTRAINT pk_diagnoses PRIMARY KEY,
    encounter_id             INTEGER        NOT NULL,
    icd10_code               VARCHAR(10)    NOT NULL,
    diagnosis_description    VARCHAR(200)   NOT NULL,
    diagnosis_type           VARCHAR(10)    DEFAULT 'PRIMARY' NOT NULL,
    diagnosed_date            DATE           NOT NULL,
    created_at               TIMESTAMP      DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT fk_diagnoses_encounter FOREIGN KEY (encounter_id)
        REFERENCES clinical_encounters (encounter_id),
    CONSTRAINT ck_diagnoses_type CHECK (diagnosis_type IN ('PRIMARY', 'SECONDARY'))
);

COMMENT ON TABLE diagnoses IS 'ICD-10 diagnoses per encounter. An encounter may have one primary and multiple secondary diagnoses.';

-- ============================================================================
-- LAB_ORDERS
-- Laboratory test orders placed during an encounter.
-- ============================================================================
CREATE TABLE lab_orders (
    lab_order_id    INTEGER        GENERATED ALWAYS AS IDENTITY
                                   CONSTRAINT pk_lab_orders PRIMARY KEY,
    encounter_id    INTEGER        NOT NULL,
    patient_id      INTEGER        NOT NULL,
    provider_id     INTEGER        NOT NULL,
    order_date      DATE           NOT NULL,
    test_code       VARCHAR(20)    NOT NULL,
    test_name       VARCHAR(100)   NOT NULL,
    priority        VARCHAR(10)    DEFAULT 'ROUTINE' NOT NULL,
    status          VARCHAR(20)    DEFAULT 'ORDERED' NOT NULL,
    created_at      TIMESTAMP      DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT fk_lab_orders_encounter FOREIGN KEY (encounter_id)
        REFERENCES clinical_encounters (encounter_id),
    CONSTRAINT fk_lab_orders_patient FOREIGN KEY (patient_id)
        REFERENCES patients (patient_id),
    CONSTRAINT fk_lab_orders_provider FOREIGN KEY (provider_id)
        REFERENCES providers (provider_id),
    CONSTRAINT ck_lab_orders_priority CHECK (priority IN ('ROUTINE', 'URGENT', 'STAT')),
    CONSTRAINT ck_lab_orders_status CHECK (status IN
        ('ORDERED', 'IN_PROGRESS', 'COMPLETED', 'CANCELLED'))
);

COMMENT ON TABLE lab_orders IS 'Laboratory test orders. A single order can yield multiple result rows (e.g. a metabolic panel).';

-- ============================================================================
-- LAB_RESULTS
-- Result rows tied to a lab order. result_value is VARCHAR to support both
-- numeric (e.g. "5.4") and qualitative (e.g. "Positive") results.
-- ============================================================================
CREATE TABLE lab_results (
    lab_result_id         INTEGER        GENERATED ALWAYS AS IDENTITY
                                         CONSTRAINT pk_lab_results PRIMARY KEY,
    lab_order_id           INTEGER        NOT NULL,
    result_value           VARCHAR(50)    NOT NULL,
    result_unit            VARCHAR(20),
    reference_range_low    NUMERIC,
    reference_range_high   NUMERIC,
    abnormal_flag          VARCHAR(10)    DEFAULT 'NORMAL' NOT NULL,
    result_date            DATE           NOT NULL,
    performed_by           VARCHAR(100),
    created_at             TIMESTAMP      DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT fk_lab_results_order FOREIGN KEY (lab_order_id)
        REFERENCES lab_orders (lab_order_id),
    CONSTRAINT ck_lab_results_flag CHECK (abnormal_flag IN
        ('NORMAL', 'LOW', 'HIGH', 'CRITICAL')),
    CONSTRAINT ck_lab_results_range CHECK (
        reference_range_low IS NULL
        OR reference_range_high IS NULL
        OR reference_range_high >= reference_range_low
    )
);

COMMENT ON TABLE lab_results IS 'Individual result values for a lab order. abnormal_flag is a recorded business classification, not an automatic diagnosis.';

-- ============================================================================
-- REPORT_EXECUTION_LOG
-- Metadata trail for PL/pgSQL report executions (used by pkg_clinical_
-- reporting and pkg_data_quality to record what ran, when, and with what
-- outcome).
-- ============================================================================
CREATE TABLE report_execution_log (
    log_id          INTEGER        GENERATED ALWAYS AS IDENTITY
                                   CONSTRAINT pk_report_execution_log PRIMARY KEY,
    report_name     VARCHAR(100)   NOT NULL,
    parameters      VARCHAR(500),
    executed_at     TIMESTAMP      DEFAULT CURRENT_TIMESTAMP NOT NULL,
    status          VARCHAR(20)    NOT NULL,
    row_count       INTEGER,
    error_message   VARCHAR(500),
    execution_ms    NUMERIC,
    CONSTRAINT ck_report_log_status CHECK (status IN ('SUCCESS', 'FAILURE'))
);

COMMENT ON TABLE report_execution_log IS 'Audit trail of PL/pgSQL report/validation executions, written by the reporting packages themselves.';
