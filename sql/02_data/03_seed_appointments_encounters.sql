--------------------------------------------------------------------------------
-- 03_seed_appointments_encounters.sql
--
-- Generates ~9 months of synthetic appointment history (2025-01 .. 2025-09)
-- for every active provider, then creates a clinical_encounters row for every
-- COMPLETED appointment.
--
-- Status mix is intentionally imperfect:
--   65% COMPLETED, 15% CANCELLED, 10% NO_SHOW, 10% SCHEDULED
-- The SCHEDULED bucket is left in place even though these dates are now in
-- the past -- that is a deliberate, realistic data-quality defect ("stale
-- scheduled appointment never closed out") picked up later by
-- pkg_data_quality.detect_inconsistent_statuses(). Roughly half of the
-- CANCELLED rows are left without a cancelled_reason for the same reason
-- (see the comment on appointments.cancelled_reason in 01_create_tables.sql).
--------------------------------------------------------------------------------

DO $$
DECLARE
    v_patient_count   INTEGER;
    v_patient_id      INTEGER;
    v_status          VARCHAR(20);
    v_roll            NUMERIC;
    v_appt_date       TIMESTAMP;
    v_appt_type       VARCHAR(30);
    v_appt_id         INTEGER;
    v_cancel_reason   VARCHAR(200);

    v_appt_types TEXT[] := ARRAY[
        'NEW_PATIENT', 'FOLLOW_UP', 'ANNUAL_PHYSICAL', 'URGENT', 'TELEHEALTH', 'PROCEDURE'
    ];
    v_cancel_reasons TEXT[] := ARRAY[
        'Patient requested reschedule', 'Provider unavailable', 'Insurance verification failed'
    ];

    v_appt_counter NUMERIC := 0;
    prov RECORD;
BEGIN
    SELECT COUNT(*) INTO v_patient_count FROM patients;

    FOR prov IN (SELECT provider_id, department_id
                 FROM providers
                 WHERE is_active = 'Y'
                 ORDER BY provider_id) LOOP

        FOR month_offset IN 0 .. 8 LOOP  -- Jan 2025 .. Sep 2025
            FOR appt_in_month IN 1 .. (8 + MOD(prov.provider_id * 7 + month_offset, 8)) LOOP
                v_appt_counter := v_appt_counter + 1;

                v_patient_id := TRUNC(1 + random() * v_patient_count);
                IF v_patient_id > v_patient_count THEN
                    v_patient_id := v_patient_count;
                END IF;

                v_appt_date := (DATE '2025-01-01' + (month_offset || ' months')::INTERVAL)
                               + (TRUNC(random() * 27) || ' days')::INTERVAL
                               + ((TRUNC(8 + random() * 9)::TEXT || ' hours')::INTERVAL);

                v_appt_type := v_appt_types[TRUNC(1 + random() * array_length(v_appt_types, 1))];

                v_roll := random() * 100;
                IF v_roll < 65 THEN
                    v_status := 'COMPLETED';
                ELSIF v_roll < 80 THEN
                    v_status := 'CANCELLED';
                ELSIF v_roll < 90 THEN
                    v_status := 'NO_SHOW';
                ELSE
                    v_status := 'SCHEDULED';  -- stale on purpose, see header comment
                END IF;

                IF v_status = 'CANCELLED' AND MOD(v_appt_counter::INTEGER, 2) = 0 THEN
                    v_cancel_reason := v_cancel_reasons[TRUNC(1 + random() * array_length(v_cancel_reasons, 1))];
                ELSE
                    v_cancel_reason := NULL;  -- left blank even when CANCELLED, on purpose half the time
                END IF;

                INSERT INTO appointments (
                    patient_id, provider_id, department_id, scheduled_date,
                    appointment_type, status, reason, cancelled_reason
                ) VALUES (
                    v_patient_id, prov.provider_id, prov.department_id, v_appt_date,
                    v_appt_type, v_status, 'Routine scheduling', v_cancel_reason
                )
                RETURNING appointment_id INTO v_appt_id;

                IF v_status = 'COMPLETED' THEN
                    INSERT INTO clinical_encounters (
                        appointment_id, patient_id, provider_id, encounter_date,
                        encounter_type, chief_complaint, notes, encounter_status
                    ) VALUES (
                        v_appt_id, v_patient_id, prov.provider_id, v_appt_date,
                        CASE WHEN v_appt_type = 'TELEHEALTH' THEN 'TELEHEALTH' ELSE 'OFFICE_VISIT' END,
                        'Synthetic chief complaint #' || v_appt_counter,
                        'Synthetic encounter notes for demo purposes only.',
                        'CLOSED'
                    );
                END IF;
            END LOOP;
        END LOOP;
    END LOOP;

    RAISE NOTICE 'Generated % synthetic appointments across 9 months.', v_appt_counter;
END $$;
