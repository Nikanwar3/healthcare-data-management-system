--------------------------------------------------------------------------------
-- 01_call_clinical_reporting.sql
--
-- Example calls to pkg_clinical_reporting. Run with:
--   psql -d healthcare_dms -f plpgsql/examples/01_call_clinical_reporting.sql
--------------------------------------------------------------------------------

-- Example 1: monthly appointment summary for Q1 2025.
SELECT to_char(month_start, 'YYYY-MM') AS month,
       total_appointments, completed, cancelled, no_show, still_scheduled
FROM   pkg_clinical_reporting.monthly_appointment_summary(DATE '2025-01-01', DATE '2025-04-01');
-- Expected output: three rows (2025-01, 2025-02, 2025-03), each with
-- non-negative counts that sum to that month's total.


-- Example 2: invalid date range is rejected, not silently miscalculated.
DO $$
BEGIN
    PERFORM * FROM pkg_clinical_reporting.monthly_appointment_summary(DATE '2025-06-01', DATE '2025-01-01');
EXCEPTION
    WHEN SQLSTATE 'HC001' THEN
        RAISE NOTICE 'Caught expected error: %', SQLERRM;
END $$;
-- Expected output: "Caught expected error: start_date (2025-06-01) must not
-- be after end_date (2025-01-01)."


-- Example 3: department workload for a single department.
SELECT department_name, total_appointments, distinct_patients_seen, completion_rate_pct
FROM   pkg_clinical_reporting.department_workload_summary(
    DATE '2025-01-01', DATE '2025-10-01', 1  -- Cardiology, per 02_data/01_seed_departments_providers.sql
);


-- Example 4: invalid department_id is rejected.
DO $$
BEGIN
    PERFORM * FROM pkg_clinical_reporting.department_workload_summary(DATE '2025-01-01', DATE '2025-10-01', 9999);
EXCEPTION
    WHEN SQLSTATE 'HC002' THEN
        RAISE NOTICE 'Caught expected error: %', SQLERRM;
END $$;


-- Example 5: cancellation analysis.
SELECT department_name, cancellation_rate_pct, cancelled_missing_reason
FROM   pkg_clinical_reporting.cancellation_analysis(DATE '2025-01-01', DATE '2025-10-01')
ORDER BY cancellation_rate_pct DESC;


-- Example 6: the explicit-refcursor version of Example 3, demonstrating
-- PostgreSQL's literal equivalent of Oracle's SYS_REFCURSOR OUT parameter.
-- A refcursor only lives for the enclosing transaction, hence BEGIN/COMMIT.
BEGIN;
CALL pkg_clinical_reporting.department_workload_cursor_demo(
    DATE '2025-01-01', DATE '2025-10-01', 1, 'dept_cur'
);
FETCH ALL FROM dept_cur;
COMMIT;


-- Review what every call above wrote to the audit trail:
SELECT report_name, status, executed_at, row_count, error_message
FROM   report_execution_log
ORDER BY executed_at DESC;
-- Note: the two "invalid input" examples above (2 and 4) do NOT produce a
-- FAILURE row here -- see the "Audit-log durability note" at the top of
-- plpgsql/packages/pkg_clinical_reporting.sql for why, verified by this
-- exact example.
