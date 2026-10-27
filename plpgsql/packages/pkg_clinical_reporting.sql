--------------------------------------------------------------------------------
-- pkg_clinical_reporting.sql
--
-- Healthcare operational reporting. PostgreSQL has no CREATE PACKAGE
-- statement, so this "package" is modeled the way PostgreSQL idiomatically
-- groups related stored routines: a dedicated SCHEMA whose dotted call
-- syntax (pkg_clinical_reporting.monthly_appointment_summary(...)) reads the
-- same as Oracle's package.procedure syntax and requires no translation on
-- the Python call sites.
--
-- Every public function:
--   * returns results as a normal PostgreSQL function result set
--     (RETURNS TABLE), consumable from plain SQL, psql, or psycopg2 with no
--     custom type mapping on the client side -- the direct equivalent of
--     Oracle's SYS_REFCURSOR OUT parameter, and the idiomatic PostgreSQL
--     shape (see department_workload_cursor_demo below for a literal
--     explicit-cursor/REFCURSOR version of the same report, kept to
--     demonstrate that pattern too);
--   * validates its date-range/identifier parameters and raises a named
--     application error (custom SQLSTATE, see below) on invalid input
--     instead of returning a silently-empty or wrong result;
--   * records its own execution (name, parameters, row count, timing,
--     success/failure) into report_execution_log.
--
-- Custom SQLSTATE error codes (the PostgreSQL equivalent of Oracle's
-- RAISE_APPLICATION_ERROR(-20001/-20002) + PRAGMA EXCEPTION_INIT pattern):
--   HC001 -- invalid date range (NULL or start_date > end_date)
--   HC002 -- an identifier parameter (department_id/provider_id) does not exist
-- psycopg2 exposes the raised SQLSTATE as exc.diag.sqlstate /
-- exc.pgcode -- see python/healthcare_app/db/connection.py for how the
-- Python layer catches these and maps them onto application exceptions.
--
-- None of these functions hardcode calendar dates: callers always supply
-- p_start_date/p_end_date (or omit them to default to "the current calendar
-- month as of CURRENT_DATE", never a fixed literal).
--
-- Audit-log durability note (an honest correction, written after testing
-- this against a real PostgreSQL instance -- see docs/root-cause-analysis.md
-- Scenario 4 for the full writeup):
--
-- Oracle's version of this package used PRAGMA AUTONOMOUS_TRANSACTION so the
-- execution-log INSERT would survive even if the calling transaction later
-- rolled back. The FAILURE branch below calls log_execution() from inside
-- each function's EXCEPTION handler on the assumption that PL/pgSQL's
-- implicit per-block savepoint would give the same guarantee. Live testing
-- disproved that assumption: PL/pgSQL's implicit savepoint only protects the
-- *handler* from seeing partial work done by the block that failed: it does
-- NOT make the handler's own writes durable. These functions re-raise
-- (`RAISE;`) after logging, and if the error ultimately propagates to an
-- aborted top-level transaction -- or even just to an *outer* caller's own
-- EXCEPTION block, which rolls back to a savepoint taken before this
-- function was ever called -- that rollback undoes the log INSERT too,
-- because it happened chronologically after the outer savepoint. Verified:
-- calling monthly_appointment_summary() with an invalid range, both bare and
-- wrapped in a catching outer DO block, leaves zero FAILURE rows in
-- report_execution_log in both cases.
--
-- True autonomous-transaction behavior in PostgreSQL requires a separate
-- physical connection to commit independently (dblink/postgres_fdw loopback,
-- or a background worker) -- deliberately not added here to avoid pulling in
-- an extension (and the connection-credential handling it requires) to fix
-- what is, in this project, a non-critical audit-trail edge case. The
-- FAILURE branch is kept as-is: it correctly logs the common case (an error
-- caught by nothing, surfacing straight to the client, where PostgreSQL
-- itself aborts the one-statement transaction and the log row's absence is
-- simply moot -- no transaction committed at all), and the one genuinely
-- different case from Oracle -- a caller who catches the error and keeps
-- going -- is documented here rather than silently assumed to work.
--------------------------------------------------------------------------------

CREATE SCHEMA IF NOT EXISTS pkg_clinical_reporting;

----------------------------------------------------------------------
-- log_execution: shared audit-trail writer. See the durability note above
-- for why this is a plain function, not an autonomous transaction.
----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pkg_clinical_reporting.log_execution(
    p_report_name   VARCHAR,
    p_parameters    VARCHAR,
    p_status        VARCHAR,
    p_row_count     INTEGER,
    p_error_message VARCHAR,
    p_execution_ms  NUMERIC
) RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO report_execution_log (
        report_name, parameters, status, row_count, error_message, execution_ms
    ) VALUES (
        p_report_name, p_parameters, p_status, p_row_count, p_error_message, p_execution_ms
    );
END;
$$;

----------------------------------------------------------------------
-- Shared parameter validation. Raised errors use RAISE EXCEPTION with a
-- named custom SQLSTATE, so callers can catch "HC001"/"HC002" instead of
-- matching on error text.
----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pkg_clinical_reporting.validate_date_range(
    p_start_date DATE, p_end_date DATE
) RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_start_date IS NULL OR p_end_date IS NULL THEN
        RAISE EXCEPTION 'start_date and end_date are both required.' USING ERRCODE = 'HC001';
    ELSIF p_start_date > p_end_date THEN
        RAISE EXCEPTION 'start_date (%) must not be after end_date (%).',
            to_char(p_start_date, 'YYYY-MM-DD'), to_char(p_end_date, 'YYYY-MM-DD')
            USING ERRCODE = 'HC001';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION pkg_clinical_reporting.validate_department(
    p_department_id INTEGER
) RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_exists INTEGER;
BEGIN
    IF p_department_id IS NULL THEN
        RETURN; -- NULL means "all departments" -- not an error
    END IF;
    SELECT COUNT(*) INTO v_exists FROM departments WHERE department_id = p_department_id;
    IF v_exists = 0 THEN
        RAISE EXCEPTION 'department_id % does not exist.', p_department_id USING ERRCODE = 'HC002';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION pkg_clinical_reporting.validate_provider(
    p_provider_id INTEGER
) RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_exists INTEGER;
BEGIN
    IF p_provider_id IS NULL THEN
        RETURN;
    END IF;
    SELECT COUNT(*) INTO v_exists FROM providers WHERE provider_id = p_provider_id;
    IF v_exists = 0 THEN
        RAISE EXCEPTION 'provider_id % does not exist.', p_provider_id USING ERRCODE = 'HC002';
    END IF;
END;
$$;

----------------------------------------------------------------------
-- Monthly appointment summary: total/completed/cancelled/no-show/
-- still-scheduled counts, grouped by calendar month.
-- p_start_date/p_end_date default to the current calendar month.
----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pkg_clinical_reporting.monthly_appointment_summary(
    p_start_date DATE DEFAULT date_trunc('month', CURRENT_DATE)::DATE,
    p_end_date   DATE DEFAULT (date_trunc('month', CURRENT_DATE) + INTERVAL '1 month')::DATE
) RETURNS TABLE (
    month_start         DATE,
    total_appointments  BIGINT,
    completed           BIGINT,
    cancelled           BIGINT,
    no_show             BIGINT,
    still_scheduled     BIGINT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_start_time TIMESTAMP := clock_timestamp();
    v_params     VARCHAR(200);
    v_row_count  INTEGER;
BEGIN
    v_params := 'start_date=' || to_char(p_start_date, 'YYYY-MM-DD') ||
                ', end_date=' || to_char(p_end_date, 'YYYY-MM-DD');

    PERFORM pkg_clinical_reporting.validate_date_range(p_start_date, p_end_date);

    RETURN QUERY
        SELECT DATE_TRUNC('month', a.scheduled_date)::DATE                   AS month_start,
               COUNT(*)                                                      AS total_appointments,
               SUM(CASE WHEN a.status = 'COMPLETED' THEN 1 ELSE 0 END)       AS completed,
               SUM(CASE WHEN a.status = 'CANCELLED' THEN 1 ELSE 0 END)       AS cancelled,
               SUM(CASE WHEN a.status = 'NO_SHOW'   THEN 1 ELSE 0 END)       AS no_show,
               SUM(CASE WHEN a.status = 'SCHEDULED' THEN 1 ELSE 0 END)       AS still_scheduled
        FROM   appointments a
        WHERE  a.scheduled_date >= p_start_date
        AND    a.scheduled_date <  p_end_date
        GROUP BY DATE_TRUNC('month', a.scheduled_date)
        ORDER BY month_start;

    SELECT COUNT(*) INTO v_row_count
    FROM   appointments a
    WHERE  a.scheduled_date >= p_start_date AND a.scheduled_date < p_end_date;

    PERFORM pkg_clinical_reporting.log_execution(
        'MONTHLY_APPOINTMENT_SUMMARY', v_params, 'SUCCESS', v_row_count, NULL,
        EXTRACT(EPOCH FROM (clock_timestamp() - v_start_time)) * 1000
    );
EXCEPTION
    WHEN OTHERS THEN
        PERFORM pkg_clinical_reporting.log_execution(
            'MONTHLY_APPOINTMENT_SUMMARY', v_params, 'FAILURE', NULL, SQLERRM,
            EXTRACT(EPOCH FROM (clock_timestamp() - v_start_time)) * 1000
        );
        RAISE;
END;
$$;

----------------------------------------------------------------------
-- Department-wise workload: appointment volume, distinct patients, and
-- completion rate per department in the window. Optionally scoped to a
-- single department via p_department_id.
----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pkg_clinical_reporting.department_workload_summary(
    p_start_date    DATE,
    p_end_date      DATE,
    p_department_id INTEGER DEFAULT NULL
) RETURNS TABLE (
    department_id           INTEGER,
    department_name         VARCHAR,
    total_appointments      BIGINT,
    distinct_patients_seen  BIGINT,
    completed_appointments  BIGINT,
    completion_rate_pct     NUMERIC
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_start_time TIMESTAMP := clock_timestamp();
    v_params     VARCHAR(200);
BEGIN
    v_params := 'start_date=' || to_char(p_start_date, 'YYYY-MM-DD') ||
                ', end_date=' || to_char(p_end_date, 'YYYY-MM-DD') ||
                ', department_id=' || COALESCE(p_department_id::TEXT, 'ALL');

    PERFORM pkg_clinical_reporting.validate_date_range(p_start_date, p_end_date);
    PERFORM pkg_clinical_reporting.validate_department(p_department_id);

    RETURN QUERY
        SELECT d.department_id, d.department_name,
               COUNT(*)                          AS total_appointments,
               COUNT(DISTINCT a.patient_id)       AS distinct_patients_seen,
               SUM(CASE WHEN a.status = 'COMPLETED' THEN 1 ELSE 0 END) AS completed_appointments,
               ROUND(100.0 * SUM(CASE WHEN a.status = 'COMPLETED' THEN 1 ELSE 0 END)
                     / COUNT(*), 1)               AS completion_rate_pct
        FROM   departments d
        JOIN   appointments a ON a.department_id = d.department_id
        WHERE  a.scheduled_date >= p_start_date
        AND    a.scheduled_date <  p_end_date
        AND    (p_department_id IS NULL OR d.department_id = p_department_id)
        GROUP BY d.department_id, d.department_name
        ORDER BY total_appointments DESC;

    PERFORM pkg_clinical_reporting.log_execution(
        'DEPARTMENT_WORKLOAD_SUMMARY', v_params, 'SUCCESS', NULL, NULL,
        EXTRACT(EPOCH FROM (clock_timestamp() - v_start_time)) * 1000
    );
EXCEPTION
    WHEN OTHERS THEN
        PERFORM pkg_clinical_reporting.log_execution(
            'DEPARTMENT_WORKLOAD_SUMMARY', v_params, 'FAILURE', NULL, SQLERRM,
            EXTRACT(EPOCH FROM (clock_timestamp() - v_start_time)) * 1000
        );
        RAISE;
END;
$$;

----------------------------------------------------------------------
-- Appointment cancellation analysis: cancellation rate overall and by
-- department, plus a breakdown of cancellations with vs. without a
-- recorded cancelled_reason.
----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pkg_clinical_reporting.cancellation_analysis(
    p_start_date DATE,
    p_end_date   DATE
) RETURNS TABLE (
    department_name           VARCHAR,
    total_appointments        BIGINT,
    cancelled_total           BIGINT,
    cancelled_with_reason     BIGINT,
    cancelled_missing_reason  BIGINT,
    cancellation_rate_pct     NUMERIC
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_start_time TIMESTAMP := clock_timestamp();
    v_params     VARCHAR(200);
BEGIN
    v_params := 'start_date=' || to_char(p_start_date, 'YYYY-MM-DD') ||
                ', end_date=' || to_char(p_end_date, 'YYYY-MM-DD');

    PERFORM pkg_clinical_reporting.validate_date_range(p_start_date, p_end_date);

    RETURN QUERY
        SELECT d.department_name,
               COUNT(*)                                                 AS total_appointments,
               SUM(CASE WHEN a.status = 'CANCELLED' THEN 1 ELSE 0 END)  AS cancelled_total,
               SUM(CASE WHEN a.status = 'CANCELLED'
                         AND a.cancelled_reason IS NOT NULL THEN 1 ELSE 0 END) AS cancelled_with_reason,
               SUM(CASE WHEN a.status = 'CANCELLED'
                         AND a.cancelled_reason IS NULL THEN 1 ELSE 0 END)     AS cancelled_missing_reason,
               ROUND(100.0 * SUM(CASE WHEN a.status = 'CANCELLED' THEN 1 ELSE 0 END)
                     / COUNT(*), 1)                                      AS cancellation_rate_pct
        FROM   departments d
        JOIN   appointments a ON a.department_id = d.department_id
        WHERE  a.scheduled_date >= p_start_date
        AND    a.scheduled_date <  p_end_date
        GROUP BY d.department_name
        ORDER BY cancellation_rate_pct DESC;

    PERFORM pkg_clinical_reporting.log_execution(
        'CANCELLATION_ANALYSIS', v_params, 'SUCCESS', NULL, NULL,
        EXTRACT(EPOCH FROM (clock_timestamp() - v_start_time)) * 1000
    );
EXCEPTION
    WHEN OTHERS THEN
        PERFORM pkg_clinical_reporting.log_execution(
            'CANCELLATION_ANALYSIS', v_params, 'FAILURE', NULL, SQLERRM,
            EXTRACT(EPOCH FROM (clock_timestamp() - v_start_time)) * 1000
        );
        RAISE;
END;
$$;

----------------------------------------------------------------------
-- Provider workload summary: appointment volume and completion rate per
-- provider in the window. Optionally scoped to one provider.
----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pkg_clinical_reporting.provider_workload_summary(
    p_start_date  DATE,
    p_end_date    DATE,
    p_provider_id INTEGER DEFAULT NULL
) RETURNS TABLE (
    provider_id             INTEGER,
    provider_name           VARCHAR,
    specialty               VARCHAR,
    total_appointments      BIGINT,
    completed_appointments  BIGINT,
    completion_rate_pct     NUMERIC
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_start_time TIMESTAMP := clock_timestamp();
    v_params     VARCHAR(200);
BEGIN
    v_params := 'start_date=' || to_char(p_start_date, 'YYYY-MM-DD') ||
                ', end_date=' || to_char(p_end_date, 'YYYY-MM-DD') ||
                ', provider_id=' || COALESCE(p_provider_id::TEXT, 'ALL');

    PERFORM pkg_clinical_reporting.validate_date_range(p_start_date, p_end_date);
    PERFORM pkg_clinical_reporting.validate_provider(p_provider_id);

    RETURN QUERY
        SELECT pr.provider_id, (pr.first_name || ' ' || pr.last_name)::VARCHAR AS provider_name,
               pr.specialty,
               COUNT(*)                                                AS total_appointments,
               SUM(CASE WHEN a.status = 'COMPLETED' THEN 1 ELSE 0 END) AS completed_appointments,
               ROUND(100.0 * SUM(CASE WHEN a.status = 'COMPLETED' THEN 1 ELSE 0 END)
                     / COUNT(*), 1)                                    AS completion_rate_pct
        FROM   providers pr
        JOIN   appointments a ON a.provider_id = pr.provider_id
        WHERE  a.scheduled_date >= p_start_date
        AND    a.scheduled_date <  p_end_date
        AND    (p_provider_id IS NULL OR pr.provider_id = p_provider_id)
        GROUP BY pr.provider_id, pr.first_name, pr.last_name, pr.specialty
        ORDER BY total_appointments DESC;

    PERFORM pkg_clinical_reporting.log_execution(
        'PROVIDER_WORKLOAD_SUMMARY', v_params, 'SUCCESS', NULL, NULL,
        EXTRACT(EPOCH FROM (clock_timestamp() - v_start_time)) * 1000
    );
EXCEPTION
    WHEN OTHERS THEN
        PERFORM pkg_clinical_reporting.log_execution(
            'PROVIDER_WORKLOAD_SUMMARY', v_params, 'FAILURE', NULL, SQLERRM,
            EXTRACT(EPOCH FROM (clock_timestamp() - v_start_time)) * 1000
        );
        RAISE;
END;
$$;

----------------------------------------------------------------------
-- department_workload_cursor_demo: the same report as
-- department_workload_summary above, but expressed as a PROCEDURE with an
-- explicit INOUT refcursor parameter -- PostgreSQL's literal equivalent of
-- Oracle's "PROCEDURE ... (p_cursor OUT SYS_REFCURSOR)" pattern, callable as:
--
--   BEGIN;
--   CALL pkg_clinical_reporting.department_workload_cursor_demo(
--       DATE '2025-01-01', DATE '2025-10-01', NULL, 'dept_cur'
--   );
--   FETCH ALL FROM dept_cur;
--   COMMIT;
--
-- (a refcursor is only valid for the lifetime of the transaction that opened
-- it, hence the explicit BEGIN/COMMIT). Kept as a second, explicit-cursor
-- demonstration alongside the RETURNS TABLE functions above, which are the
-- simpler, idiomatic PostgreSQL shape used everywhere else in this project
-- and by the Python layer.
----------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pkg_clinical_reporting.department_workload_cursor_demo(
    IN    p_start_date    DATE,
    IN    p_end_date      DATE,
    IN    p_department_id INTEGER,
    INOUT p_cursor         refcursor
)
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM pkg_clinical_reporting.validate_date_range(p_start_date, p_end_date);
    PERFORM pkg_clinical_reporting.validate_department(p_department_id);

    OPEN p_cursor FOR
        SELECT d.department_id, d.department_name,
               COUNT(*)                          AS total_appointments,
               COUNT(DISTINCT a.patient_id)       AS distinct_patients_seen,
               SUM(CASE WHEN a.status = 'COMPLETED' THEN 1 ELSE 0 END) AS completed_appointments,
               ROUND(100.0 * SUM(CASE WHEN a.status = 'COMPLETED' THEN 1 ELSE 0 END)
                     / COUNT(*), 1)               AS completion_rate_pct
        FROM   departments d
        JOIN   appointments a ON a.department_id = d.department_id
        WHERE  a.scheduled_date >= p_start_date
        AND    a.scheduled_date <  p_end_date
        AND    (p_department_id IS NULL OR d.department_id = p_department_id)
        GROUP BY d.department_id, d.department_name
        ORDER BY total_appointments DESC;
END;
$$;
