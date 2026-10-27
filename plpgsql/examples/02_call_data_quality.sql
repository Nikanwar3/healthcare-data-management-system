--------------------------------------------------------------------------------
-- 02_call_data_quality.sql
--
-- Example calls to pkg_data_quality. Every check function returns
-- SETOF pkg_data_quality.dq_finding, so it can be queried directly with
-- plain SQL -- no OUT parameters or cursor loops needed for the common case.
--------------------------------------------------------------------------------

-- Example 1: run every in-table check at once.
SELECT severity, rule_name, entity_type, entity_id, finding_description, recommended_action
FROM   pkg_data_quality.run_all_checks()
ORDER BY CASE severity WHEN 'ERROR' THEN 1 ELSE 2 END, rule_name, entity_id;
-- Expected output against the seeded demo data: a mix of ERROR rows
-- (INCOMPLETE_LAB_ORDER from 02_data/05_seed_dirty_data_demo.sql is
-- guaranteed) and WARNING rows (DUPLICATE_DIAGNOSIS, DUPLICATE_LAB_RESULT,
-- MISSING_REFERENCE_RANGE guaranteed; STALE_SCHEDULED_APPOINTMENT and
-- MISSING_CANCELLATION_REASON from the ~10%/50% seed mix).


-- Example 2: count findings by severity -- the "should this block a
-- release/merge?" summary a CI job or ops dashboard would check.
SELECT severity, COUNT(*) AS finding_count
FROM   pkg_data_quality.run_all_checks()
GROUP BY severity;


-- Example 3: validate the raw appointment feed before merging it into
-- appointments -- this is the pre-load gate described in
-- sql/01_schema/03_create_staging.sql.
SELECT rule_name, entity_id, finding_description, recommended_action
FROM   pkg_data_quality.validate_staging_appointments()
ORDER BY entity_id, rule_name;
-- Expected output against 02_data/05_seed_dirty_data_demo.sql: 4 findings
-- (unknown patient MRN, unknown provider NPI, invalid date, missing MRN) --
-- the one clean staging row produces no findings.


-- Example 4: validate a single staging row by id.
SELECT rule_name, finding_description
FROM   pkg_data_quality.validate_staging_appointments(1);
-- Expected output: 0 rows (stg_id 1 is the deliberately clean row).


-- Example 5: an unknown stg_id raises a custom HC002 error rather than
-- silently returning an empty result.
DO $$
BEGIN
    PERFORM * FROM pkg_data_quality.validate_staging_appointments(999999);
EXCEPTION
    WHEN SQLSTATE 'HC002' THEN
        RAISE NOTICE 'Caught expected error: %', SQLERRM;
END $$;


-- Example 6: merge the one clean staging row into appointments. This is a
-- PROCEDURE (CALL, not SELECT) because it performs DML, not just reporting.
CALL pkg_data_quality.merge_staging_appointment(1);
-- Expected: 1 new SCHEDULED row in appointments, and stg_id 1 removed from
-- stg_appointments_raw.


-- Example 7: attempting to merge a staging row that fails validation is
-- rejected -- no appointment is inserted and the staging row is not removed.
DO $$
BEGIN
    CALL pkg_data_quality.merge_staging_appointment(2);  -- unknown patient MRN
EXCEPTION
    WHEN SQLSTATE 'HC003' THEN
        RAISE NOTICE 'Caught expected error: %', SQLERRM;
END $$;
