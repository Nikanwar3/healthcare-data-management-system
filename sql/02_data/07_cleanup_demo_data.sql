--------------------------------------------------------------------------------
-- 07_cleanup_demo_data.sql
--
-- Removes all rows (but keeps the schema/tables/indexes/packages intact) so
-- the seed scripts can be re-run from a clean slate. A single TRUNCATE ...
-- CASCADE across all tables handles FK dependencies regardless of order and
-- resets every GENERATED ALWAYS AS IDENTITY counter back to its start value
-- via RESTART IDENTITY (PostgreSQL 10+) -- no manual ALTER TABLE needed.
--
-- This is data-only cleanup. To drop the schema entirely, use
-- sql/01_schema/00_drop_schema.sql instead.
--------------------------------------------------------------------------------

TRUNCATE TABLE
    report_execution_log, stg_appointments_raw, lab_results, lab_orders,
    diagnoses, clinical_encounters, appointments, patients, providers, departments
RESTART IDENTITY CASCADE;
