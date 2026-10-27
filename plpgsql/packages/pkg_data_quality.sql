--------------------------------------------------------------------------------
-- pkg_data_quality.sql
--
-- Data-quality rule engine. Each function RETURNS SETOF pkg_data_quality.
-- dq_finding (see 00_types.sql), so every rule can be queried directly from
-- SQL:
--     SELECT * FROM pkg_data_quality.detect_duplicate_diagnoses();
-- or combined:
--     SELECT * FROM pkg_data_quality.run_all_checks();
--
-- (PostgreSQL SETOF functions don't need Oracle's TABLE()/PIPELINED
-- machinery -- a plain `SELECT * FROM function_name()` already streams rows,
-- which is why this file has no equivalent of Oracle's "PIPE ROW" calls.)
--
-- Severity contract (see docs/data-quality-rules.md for the full rationale):
--   ERROR   -- the record is unsafe to use downstream as-is; an operation
--             that depends on it (e.g. merging a staging row into
--             appointments) should be blocked until corrected.
--   WARNING -- worth a human's attention, but does not by itself invalidate
--             the record or block processing.
--
-- No function here infers a clinical diagnosis from an abnormal lab value --
-- that judgment belongs to a clinician, not this reporting layer.
--
-- Custom SQLSTATE error codes used in this file:
--   HC002 -- an identifier parameter (stg_id) does not exist
--   HC003 -- merge_staging_appointment: the staging row fails one or more
--            data-quality checks and cannot be safely merged
--------------------------------------------------------------------------------

CREATE SCHEMA IF NOT EXISTS pkg_data_quality;
-- pkg_data_quality.dq_finding is created by 00_types.sql, which must run
-- before this file.

CREATE OR REPLACE FUNCTION pkg_data_quality.log_execution(
    p_report_name VARCHAR,
    p_parameters  VARCHAR,
    p_status      VARCHAR,
    p_row_count   INTEGER,
    p_error_message VARCHAR
) RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO report_execution_log (report_name, parameters, status, row_count, error_message)
    VALUES (p_report_name, p_parameters, p_status, p_row_count, p_error_message);
END;
$$;

----------------------------------------------------------------------
-- Patients whose MRN collides case/whitespace-insensitively with another
-- patient's MRN. (Exact duplicates are already prevented by the UNIQUE
-- constraint on patients.mrn -- this catches the near-duplicates that
-- constraint cannot see, e.g. ' mrn000012' vs 'MRN000012'.)
----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pkg_data_quality.detect_duplicate_patient_identifiers()
RETURNS SETOF pkg_data_quality.dq_finding
LANGUAGE plpgsql
AS $$
DECLARE
    rec RECORD;
BEGIN
    FOR rec IN (
        SELECT UPPER(TRIM(mrn)) AS normalized_mrn, COUNT(*) AS occurrence_count,
               STRING_AGG(patient_id::TEXT, ',' ORDER BY patient_id) AS patient_ids
        FROM   patients
        GROUP BY UPPER(TRIM(mrn))
        HAVING COUNT(*) > 1
    ) LOOP
        RETURN NEXT ROW(
            'DUPLICATE_PATIENT_IDENTIFIER', 'ERROR', 'PATIENT', rec.patient_ids,
            'MRN ' || rec.normalized_mrn || ' is shared by ' || rec.occurrence_count ||
                ' patient records (case/whitespace-insensitive match).',
            'Merge or correct the duplicate patient records before using them in reporting.'
        )::pkg_data_quality.dq_finding;
    END LOOP;
    RETURN;
END;
$$;

----------------------------------------------------------------------
-- Patients with neither a phone number nor an email on file.
--
-- Written with an EXPLICIT cursor (DECLARE ... CURSOR, OPEN, FETCH, CLOSE)
-- rather than the implicit `FOR rec IN (SELECT ...) LOOP` style used
-- everywhere else in this file, to demonstrate both cursor forms in this
-- project. The implicit form is preferred elsewhere (less code, same
-- result) -- this one function is the deliberate exception.
----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pkg_data_quality.detect_missing_contact_info()
RETURNS SETOF pkg_data_quality.dq_finding
LANGUAGE plpgsql
AS $$
DECLARE
    v_cursor CURSOR FOR
        SELECT patient_id, mrn
        FROM   patients
        WHERE  phone IS NULL AND email IS NULL;
    rec RECORD;
BEGIN
    OPEN v_cursor;
    LOOP
        FETCH v_cursor INTO rec;
        EXIT WHEN NOT FOUND;
        RETURN NEXT ROW(
            'MISSING_CONTACT_INFO', 'WARNING', 'PATIENT', rec.patient_id::TEXT,
            'Patient ' || rec.mrn || ' has no phone number or email on file.',
            'Collect at least one contact method at the next encounter.'
        )::pkg_data_quality.dq_finding;
    END LOOP;
    CLOSE v_cursor;
    RETURN;
END;
$$;

----------------------------------------------------------------------
-- Appointments scheduled before the patient's own date of birth -- a
-- logical impossibility, always an ERROR.
----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pkg_data_quality.detect_invalid_appointment_dates()
RETURNS SETOF pkg_data_quality.dq_finding
LANGUAGE plpgsql
AS $$
DECLARE
    rec RECORD;
BEGIN
    FOR rec IN (
        SELECT a.appointment_id, a.scheduled_date, p.mrn, p.date_of_birth
        FROM   appointments a
        JOIN   patients p ON p.patient_id = a.patient_id
        WHERE  a.scheduled_date::DATE < p.date_of_birth
    ) LOOP
        RETURN NEXT ROW(
            'INVALID_APPOINTMENT_DATE', 'ERROR', 'APPOINTMENT', rec.appointment_id::TEXT,
            'Appointment scheduled ' || to_char(rec.scheduled_date, 'YYYY-MM-DD') ||
                ' is before patient ' || rec.mrn || '''s date of birth (' ||
                to_char(rec.date_of_birth, 'YYYY-MM-DD') || ').',
            'Correct the scheduled_date or verify the linked patient_id is correct.'
        )::pkg_data_quality.dq_finding;
    END LOOP;
    RETURN;
END;
$$;

----------------------------------------------------------------------
-- SCHEDULED appointments whose date has already passed (p_as_of_date), and
-- CANCELLED appointments with no cancelled_reason recorded.
----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pkg_data_quality.detect_inconsistent_statuses(
    p_as_of_date DATE DEFAULT CURRENT_DATE
) RETURNS SETOF pkg_data_quality.dq_finding
LANGUAGE plpgsql
AS $$
DECLARE
    v_as_of DATE := COALESCE(p_as_of_date, CURRENT_DATE);
    rec RECORD;
BEGIN
    FOR rec IN (
        SELECT appointment_id, scheduled_date
        FROM   appointments
        WHERE  status = 'SCHEDULED'
        AND    scheduled_date < v_as_of
    ) LOOP
        RETURN NEXT ROW(
            'STALE_SCHEDULED_APPOINTMENT', 'WARNING', 'APPOINTMENT', rec.appointment_id::TEXT,
            'Appointment was scheduled for ' || to_char(rec.scheduled_date, 'YYYY-MM-DD') ||
                ', which has passed, but status is still SCHEDULED.',
            'Update status to COMPLETED, CANCELLED, or NO_SHOW to reflect what actually happened.'
        )::pkg_data_quality.dq_finding;
    END LOOP;

    FOR rec IN (
        SELECT appointment_id, scheduled_date
        FROM   appointments
        WHERE  status = 'CANCELLED'
        AND    cancelled_reason IS NULL
    ) LOOP
        RETURN NEXT ROW(
            'MISSING_CANCELLATION_REASON', 'WARNING', 'APPOINTMENT', rec.appointment_id::TEXT,
            'Appointment cancelled (originally scheduled ' ||
                to_char(rec.scheduled_date, 'YYYY-MM-DD') || ') has no cancelled_reason recorded.',
            'Follow up with scheduling staff to record why the appointment was cancelled.'
        )::pkg_data_quality.dq_finding;
    END LOOP;
    RETURN;
END;
$$;

----------------------------------------------------------------------
-- Duplicate diagnosis rows: same encounter, ICD-10 code, and diagnosis_type
-- recorded more than once.
----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pkg_data_quality.detect_duplicate_diagnoses()
RETURNS SETOF pkg_data_quality.dq_finding
LANGUAGE plpgsql
AS $$
DECLARE
    rec RECORD;
BEGIN
    FOR rec IN (
        SELECT encounter_id, icd10_code, diagnosis_type, COUNT(*) AS occurrence_count
        FROM   diagnoses
        GROUP BY encounter_id, icd10_code, diagnosis_type
        HAVING COUNT(*) > 1
    ) LOOP
        RETURN NEXT ROW(
            'DUPLICATE_DIAGNOSIS', 'WARNING', 'ENCOUNTER', rec.encounter_id::TEXT,
            'Encounter has ' || rec.occurrence_count || ' ' || rec.diagnosis_type ||
                ' diagnosis rows for ICD-10 ' || rec.icd10_code || '.',
            'Review the encounter and remove the duplicate diagnosis entry.'
        )::pkg_data_quality.dq_finding;
    END LOOP;
    RETURN;
END;
$$;

----------------------------------------------------------------------
-- Duplicate lab result rows: same order, value, and result date recorded
-- more than once (e.g. instrument double-submission).
----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pkg_data_quality.detect_duplicate_lab_results()
RETURNS SETOF pkg_data_quality.dq_finding
LANGUAGE plpgsql
AS $$
DECLARE
    rec RECORD;
BEGIN
    FOR rec IN (
        SELECT lab_order_id, result_value, result_date, COUNT(*) AS occurrence_count
        FROM   lab_results
        GROUP BY lab_order_id, result_value, result_date
        HAVING COUNT(*) > 1
    ) LOOP
        RETURN NEXT ROW(
            'DUPLICATE_LAB_RESULT', 'WARNING', 'LAB_ORDER', rec.lab_order_id::TEXT,
            'Lab order has the same result (' || rec.result_value || ' on ' ||
                to_char(rec.result_date, 'YYYY-MM-DD') || ') recorded ' ||
                rec.occurrence_count || ' times.',
            'Confirm with the lab whether this is a true repeat test or a duplicate data entry.'
        )::pkg_data_quality.dq_finding;
    END LOOP;
    RETURN;
END;
$$;

----------------------------------------------------------------------
-- Lab results with no reference range recorded at all.
----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pkg_data_quality.detect_missing_reference_ranges()
RETURNS SETOF pkg_data_quality.dq_finding
LANGUAGE plpgsql
AS $$
DECLARE
    rec RECORD;
BEGIN
    FOR rec IN (
        SELECT lab_result_id, lab_order_id
        FROM   lab_results
        WHERE  reference_range_low IS NULL
        AND    reference_range_high IS NULL
    ) LOOP
        RETURN NEXT ROW(
            'MISSING_REFERENCE_RANGE', 'WARNING', 'LAB_RESULT', rec.lab_result_id::TEXT,
            'Lab result on order ' || rec.lab_order_id || ' has no reference range recorded, ' ||
                'so its abnormal_flag cannot be independently verified.',
            'Populate reference_range_low/high for this test, or confirm the test is qualitative.'
        )::pkg_data_quality.dq_finding;
    END LOOP;
    RETURN;
END;
$$;

----------------------------------------------------------------------
-- Lab results attached to a lab order that was subsequently CANCELLED -- an
-- inconsistent state (a cancelled order should not have results).
----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pkg_data_quality.detect_results_on_cancelled_orders()
RETURNS SETOF pkg_data_quality.dq_finding
LANGUAGE plpgsql
AS $$
DECLARE
    rec RECORD;
BEGIN
    FOR rec IN (
        SELECT lr.lab_result_id, lr.lab_order_id
        FROM   lab_results lr
        JOIN   lab_orders lo ON lo.lab_order_id = lr.lab_order_id
        WHERE  lo.status = 'CANCELLED'
    ) LOOP
        RETURN NEXT ROW(
            'RESULT_ON_CANCELLED_ORDER', 'ERROR', 'LAB_RESULT', rec.lab_result_id::TEXT,
            'Lab result exists for order ' || rec.lab_order_id || ', but that order''s status is CANCELLED.',
            'Determine whether the order was wrongly cancelled or the result was wrongly recorded, then correct one side.'
        )::pkg_data_quality.dq_finding;
    END LOOP;
    RETURN;
END;
$$;

----------------------------------------------------------------------
-- Lab orders marked COMPLETED with zero associated result rows.
----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pkg_data_quality.detect_incomplete_lab_orders()
RETURNS SETOF pkg_data_quality.dq_finding
LANGUAGE plpgsql
AS $$
DECLARE
    rec RECORD;
BEGIN
    FOR rec IN (
        SELECT lo.lab_order_id, lo.test_name, lo.order_date
        FROM   lab_orders lo
        WHERE  lo.status = 'COMPLETED'
        AND    NOT EXISTS (SELECT 1 FROM lab_results lr WHERE lr.lab_order_id = lo.lab_order_id)
    ) LOOP
        RETURN NEXT ROW(
            'INCOMPLETE_LAB_ORDER', 'ERROR', 'LAB_ORDER', rec.lab_order_id::TEXT,
            'Order for ' || rec.test_name || ' (placed ' || to_char(rec.order_date, 'YYYY-MM-DD') ||
                ') is marked COMPLETED but has no result rows.',
            'Either enter the missing results or revert the order status to IN_PROGRESS.'
        )::pkg_data_quality.dq_finding;
    END LOOP;
    RETURN;
END;
$$;

----------------------------------------------------------------------
-- Pre-merge validation of the raw appointment feed landing table: unknown
-- patient MRN / provider NPI, missing required values, or an unparsable
-- scheduled_date. Optionally scoped to one staging row via p_stg_id (raises
-- a custom HC002 error if that row does not exist).
----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pkg_data_quality.validate_staging_appointments(
    p_stg_id INTEGER DEFAULT NULL
) RETURNS SETOF pkg_data_quality.dq_finding
LANGUAGE plpgsql
AS $$
DECLARE
    v_exists INTEGER;
    rec RECORD;
BEGIN
    IF p_stg_id IS NOT NULL THEN
        SELECT COUNT(*) INTO v_exists FROM stg_appointments_raw WHERE stg_id = p_stg_id;
        IF v_exists = 0 THEN
            RAISE EXCEPTION 'stg_id % does not exist in stg_appointments_raw.', p_stg_id
                USING ERRCODE = 'HC002';
        END IF;
    END IF;

    FOR rec IN (
        SELECT s.stg_id, s.source_patient_mrn, s.source_provider_npi, s.scheduled_date
        FROM   stg_appointments_raw s
        WHERE  (p_stg_id IS NULL OR s.stg_id = p_stg_id)
    ) LOOP
        IF rec.source_patient_mrn IS NULL THEN
            RETURN NEXT ROW('STAGING_MISSING_PATIENT_MRN', 'ERROR', 'STAGING_ROW',
                rec.stg_id::TEXT, 'Row has no source_patient_mrn value.',
                'Reject the row and request a corrected extract from the source system.')::pkg_data_quality.dq_finding;
        ELSIF NOT EXISTS (SELECT 1 FROM patients p WHERE p.mrn = rec.source_patient_mrn) THEN
            RETURN NEXT ROW('STAGING_UNKNOWN_PATIENT', 'ERROR', 'STAGING_ROW',
                rec.stg_id::TEXT, 'source_patient_mrn ' || rec.source_patient_mrn || ' does not match any patient.',
                'Confirm the patient was registered before the appointment was fed in, then retry.')::pkg_data_quality.dq_finding;
        END IF;

        IF rec.source_provider_npi IS NULL THEN
            RETURN NEXT ROW('STAGING_MISSING_PROVIDER_NPI', 'ERROR', 'STAGING_ROW',
                rec.stg_id::TEXT, 'Row has no source_provider_npi value.',
                'Reject the row and request a corrected extract from the source system.')::pkg_data_quality.dq_finding;
        ELSIF NOT EXISTS (SELECT 1 FROM providers pr WHERE pr.npi_number = rec.source_provider_npi) THEN
            RETURN NEXT ROW('STAGING_UNKNOWN_PROVIDER', 'ERROR', 'STAGING_ROW',
                rec.stg_id::TEXT, 'source_provider_npi ' || rec.source_provider_npi || ' does not match any provider.',
                'Confirm the provider roster is current, then retry.')::pkg_data_quality.dq_finding;
        END IF;

        IF NOT (COALESCE(rec.scheduled_date, 'X') ~ '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$') THEN
            RETURN NEXT ROW('STAGING_INVALID_DATE', 'ERROR', 'STAGING_ROW',
                rec.stg_id::TEXT, 'scheduled_date ''' || rec.scheduled_date || ''' is not in YYYY-MM-DD HH24:MI format.',
                'Fix the date format at the source and resubmit the row.')::pkg_data_quality.dq_finding;
        END IF;
    END LOOP;

    PERFORM pkg_data_quality.log_execution(
        'VALIDATE_STAGING_APPOINTMENTS', 'stg_id=' || COALESCE(p_stg_id::TEXT, 'ALL'), 'SUCCESS', NULL, NULL
    );
    RETURN;
EXCEPTION
    WHEN OTHERS THEN
        PERFORM pkg_data_quality.log_execution(
            'VALIDATE_STAGING_APPOINTMENTS', 'stg_id=' || COALESCE(p_stg_id::TEXT, 'ALL'), 'FAILURE', NULL, SQLERRM
        );
        RAISE;
END;
$$;

----------------------------------------------------------------------
-- Union of every check above (excluding validate_staging_appointments,
-- which is pre-merge and run separately as part of a load pipeline).
--
-- This is noticeably simpler than the Oracle original, which had to re-wrap
-- every row returned by `SELECT * FROM TABLE(detect_x())` in a fresh
-- DQ_FINDING_OBJ constructor before piping it onward, because PIPE ROW
-- requires an expression of the function's exact declared element type and
-- a flattened TABLE() query result doesn't carry that type. PostgreSQL's
-- SETOF-of-composite-type functions have no such restriction: the rows
-- returned by one function already have the right type, so they can be
-- selected from directly and combined with a plain UNION ALL.
----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pkg_data_quality.run_all_checks()
RETURNS SETOF pkg_data_quality.dq_finding
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY SELECT * FROM pkg_data_quality.detect_duplicate_patient_identifiers();
    RETURN QUERY SELECT * FROM pkg_data_quality.detect_missing_contact_info();
    RETURN QUERY SELECT * FROM pkg_data_quality.detect_invalid_appointment_dates();
    RETURN QUERY SELECT * FROM pkg_data_quality.detect_inconsistent_statuses();
    RETURN QUERY SELECT * FROM pkg_data_quality.detect_duplicate_diagnoses();
    RETURN QUERY SELECT * FROM pkg_data_quality.detect_duplicate_lab_results();
    RETURN QUERY SELECT * FROM pkg_data_quality.detect_missing_reference_ranges();
    RETURN QUERY SELECT * FROM pkg_data_quality.detect_results_on_cancelled_orders();
    RETURN QUERY SELECT * FROM pkg_data_quality.detect_incomplete_lab_orders();

    PERFORM pkg_data_quality.log_execution('RUN_ALL_CHECKS', NULL, 'SUCCESS', NULL, NULL);
    RETURN;
EXCEPTION
    WHEN OTHERS THEN
        PERFORM pkg_data_quality.log_execution('RUN_ALL_CHECKS', NULL, 'FAILURE', NULL, SQLERRM);
        RAISE;
END;
$$;

----------------------------------------------------------------------
-- merge_staging_appointment: a real stored PROCEDURE (not just a read-only
-- report) that the Oracle version of this project did not have -- it only
-- validated the staging feed, it never actually merged a row. This closes
-- that gap: re-validates one staging row (defense in depth -- do not trust
-- that the caller already called validate_staging_appointments), and if (and
-- only if) it is clean, resolves the patient/provider foreign keys, inserts
-- the appointment, and removes the now-merged staging row, atomically.
--
-- Demonstrates, together: a stored PROCEDURE (CALL, not SELECT), DML inside
-- PL/pgSQL, parameter/business-rule validation via exceptions with a named
-- SQLSTATE, and a multi-statement transaction where every write succeeds
-- together or (via the automatic rollback PostgreSQL performs when an
-- uncaught error aborts a transaction) none of them do.
----------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pkg_data_quality.merge_staging_appointment(
    p_stg_id INTEGER
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_row           stg_appointments_raw%ROWTYPE;
    v_patient_id    INTEGER;
    v_provider_id   INTEGER;
    v_department_id INTEGER;
    v_finding_count INTEGER;
    v_appt_type     VARCHAR(30);
BEGIN
    SELECT * INTO v_row FROM stg_appointments_raw WHERE stg_id = p_stg_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'stg_id % does not exist in stg_appointments_raw.', p_stg_id
            USING ERRCODE = 'HC002';
    END IF;

    SELECT COUNT(*) INTO v_finding_count
    FROM   pkg_data_quality.validate_staging_appointments(p_stg_id);

    IF v_finding_count > 0 THEN
        RAISE EXCEPTION
            'stg_id % failed % data-quality check(s); run validate_staging_appointments(%) for details.',
            p_stg_id, v_finding_count, p_stg_id
            USING ERRCODE = 'HC003';
    END IF;

    SELECT patient_id INTO STRICT v_patient_id FROM patients WHERE mrn = v_row.source_patient_mrn;
    SELECT provider_id, department_id INTO STRICT v_provider_id, v_department_id
        FROM providers WHERE npi_number = v_row.source_provider_npi;

    v_appt_type := CASE
        WHEN v_row.appointment_type IN
            ('NEW_PATIENT', 'FOLLOW_UP', 'ANNUAL_PHYSICAL', 'URGENT', 'TELEHEALTH', 'PROCEDURE')
        THEN v_row.appointment_type
        ELSE 'FOLLOW_UP'
    END;

    INSERT INTO appointments (
        patient_id, provider_id, department_id, scheduled_date, appointment_type, status, reason
    ) VALUES (
        v_patient_id, v_provider_id, v_department_id,
        v_row.scheduled_date::TIMESTAMP, v_appt_type, 'SCHEDULED', v_row.reason
    );

    DELETE FROM stg_appointments_raw WHERE stg_id = p_stg_id;
END;
$$;
