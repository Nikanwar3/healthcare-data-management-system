--------------------------------------------------------------------------------
-- 03_create_staging.sql
--
-- stg_appointments_raw: a landing table with NO foreign keys, modeling the
-- output of an external file/HL7 feed load before it is validated and merged
-- into the production appointments table.
--
-- Why this exists: appointments itself enforces FK integrity, so a validation
-- routine run against it will (correctly) never find "appointment referencing
-- a nonexistent patient/provider". That class of defect is real, but it shows
-- up at the staging/pre-load boundary, not in already-committed production
-- data. pkg_data_quality.validate_staging_appointments demonstrates exactly
-- that pre-merge validation step against this table.
--------------------------------------------------------------------------------

CREATE TABLE stg_appointments_raw (
    stg_id              INTEGER       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    source_patient_mrn  VARCHAR(12),
    source_provider_npi VARCHAR(10),
    department_name     VARCHAR(100),
    scheduled_date       VARCHAR(30),   -- intentionally untyped: raw feed text
    appointment_type     VARCHAR(30),
    reason               VARCHAR(200),
    loaded_at            TIMESTAMP     DEFAULT CURRENT_TIMESTAMP NOT NULL
);

COMMENT ON TABLE stg_appointments_raw IS 'Unvalidated landing zone for inbound appointment feed rows. scheduled_date is deliberately stored as text to mirror a raw external extract that has not yet been type-checked.';
