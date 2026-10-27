--------------------------------------------------------------------------------
-- 00_drop_schema.sql
--
-- Destructive. Drops every object owned by this project, in FK-safe order
-- (CASCADE additionally guarantees this regardless of order), so
-- 01_create_tables.sql can be re-run cleanly. Intended for a disposable
-- development/demo database only -- never point this at a shared database.
--
-- Each DROP uses IF EXISTS, so the script can be re-run even if a prior run
-- left the schema partially created.
--------------------------------------------------------------------------------

DROP TABLE IF EXISTS report_execution_log CASCADE;
DROP TABLE IF EXISTS stg_appointments_raw CASCADE;
DROP TABLE IF EXISTS lab_results CASCADE;
DROP TABLE IF EXISTS lab_orders CASCADE;
DROP TABLE IF EXISTS diagnoses CASCADE;
DROP TABLE IF EXISTS clinical_encounters CASCADE;
DROP TABLE IF EXISTS appointments CASCADE;
DROP TABLE IF EXISTS patients CASCADE;
DROP TABLE IF EXISTS providers CASCADE;
DROP TABLE IF EXISTS departments CASCADE;

DROP VIEW IF EXISTS v_active_providers CASCADE;
DROP VIEW IF EXISTS v_completed_appointment_detail CASCADE;

DROP SCHEMA IF EXISTS pkg_clinical_reporting CASCADE;
DROP SCHEMA IF EXISTS pkg_data_quality CASCADE;

DROP TYPE IF EXISTS dq_finding CASCADE;
