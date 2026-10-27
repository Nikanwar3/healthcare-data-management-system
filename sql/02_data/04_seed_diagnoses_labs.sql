--------------------------------------------------------------------------------
-- 04_seed_diagnoses_labs.sql
--
-- For every CLOSED clinical encounter: always adds one PRIMARY diagnosis,
-- sometimes a SECONDARY diagnosis, and sometimes (roughly half the time) a
-- lab order with 1-3 result rows. Abnormal flags are assigned independently
-- of diagnosis -- this project does not infer a diagnosis from a lab value,
-- per the "do not treat every abnormal result as a diagnosis" rule in
-- docs/data-quality-rules.md.
--
-- Note: Oracle PL/SQL lets you declare an ad hoc `TYPE x IS RECORD (...)`
-- inline; PL/pgSQL does not support anonymous record types the same way, so
-- the ICD-10/lab-test lookup tables below use parallel arrays (code/
-- description, code/name/unit/lo/hi) indexed together instead of an array of
-- records -- same data, a PL/pgSQL-idiomatic shape.
--------------------------------------------------------------------------------

DO $$
DECLARE
    v_dx_codes TEXT[] := ARRAY[
        'I10', 'E11.9', 'J06.9', 'M54.5', 'E78.5', 'J45.909',
        'K21.9', 'M25.511', 'R51', 'N39.0', 'Z00.00', 'F41.9'
    ];
    v_dx_descriptions TEXT[] := ARRAY[
        'Essential (primary) hypertension',
        'Type 2 diabetes mellitus without complications',
        'Acute upper respiratory infection, unspecified',
        'Low back pain',
        'Hyperlipidemia, unspecified',
        'Unspecified asthma, uncomplicated',
        'Gastro-esophageal reflux disease without esophagitis',
        'Pain in right shoulder',
        'Headache',
        'Urinary tract infection, site not specified',
        'General adult medical examination without abnormal findings',
        'Anxiety disorder, unspecified'
    ];

    v_test_codes TEXT[] := ARRAY['CBC-WBC', 'LIPID-LDL', 'BMP-GLU', 'TSH', 'HBA1C'];
    v_test_names TEXT[] := ARRAY[
        'White Blood Cell Count', 'LDL Cholesterol', 'Fasting Glucose',
        'Thyroid Stimulating Hormone', 'Hemoglobin A1c'
    ];
    v_test_units TEXT[] := ARRAY['K/uL', 'mg/dL', 'mg/dL', 'mIU/L', '%'];
    v_test_lo    NUMERIC[] := ARRAY[4.0, 0, 70, 0.4, 4.0];
    v_test_hi    NUMERIC[] := ARRAY[11.0, 100.0, 99.0, 4.0, 5.6];

    v_diag_counter  INTEGER := 0;
    v_lab_order_id  INTEGER;
    v_num_results   INTEGER;
    v_value_num     NUMERIC;
    v_flag          VARCHAR(10);
    v_test_idx      INTEGER;
    v_dx_count      INTEGER := array_length(v_dx_codes, 1);
    v_test_count    INTEGER := array_length(v_test_codes, 1);
    enc RECORD;
BEGIN
    FOR enc IN (SELECT encounter_id, patient_id, provider_id, encounter_date
                FROM clinical_encounters
                WHERE encounter_status = 'CLOSED'
                ORDER BY encounter_id) LOOP

        v_diag_counter := v_diag_counter + 1;

        -- Always one PRIMARY diagnosis.
        INSERT INTO diagnoses (encounter_id, icd10_code, diagnosis_description, diagnosis_type, diagnosed_date)
        VALUES (
            enc.encounter_id,
            v_dx_codes[MOD(v_diag_counter, v_dx_count) + 1],
            v_dx_descriptions[MOD(v_diag_counter, v_dx_count) + 1],
            'PRIMARY',
            enc.encounter_date::DATE
        );

        -- ~35% of encounters also get a SECONDARY diagnosis.
        IF MOD(v_diag_counter, 3) = 0 THEN
            INSERT INTO diagnoses (encounter_id, icd10_code, diagnosis_description, diagnosis_type, diagnosed_date)
            VALUES (
                enc.encounter_id,
                v_dx_codes[MOD(v_diag_counter * 5, v_dx_count) + 1],
                v_dx_descriptions[MOD(v_diag_counter * 5, v_dx_count) + 1],
                'SECONDARY',
                enc.encounter_date::DATE
            );
        END IF;

        -- ~50% of encounters generate a lab order with 1-3 results.
        IF MOD(v_diag_counter, 2) = 0 THEN
            INSERT INTO lab_orders (
                encounter_id, patient_id, provider_id, order_date,
                test_code, test_name, priority, status
            ) VALUES (
                enc.encounter_id, enc.patient_id, enc.provider_id, enc.encounter_date::DATE,
                'PANEL-' || LPAD(MOD(v_diag_counter, 99)::TEXT, 2, '0'), 'Standard Panel',
                CASE WHEN MOD(v_diag_counter, 11) = 0 THEN 'STAT' ELSE 'ROUTINE' END,
                'COMPLETED'
            ) RETURNING lab_order_id INTO v_lab_order_id;

            v_num_results := 1 + MOD(v_diag_counter, 3);

            FOR i IN 1 .. v_num_results LOOP
                v_test_idx := MOD(v_diag_counter + i, v_test_count) + 1;

                -- Spread values around the reference range so ~15% land outside it.
                v_value_num := ROUND((v_test_lo[v_test_idx] + (v_test_hi[v_test_idx] - v_test_lo[v_test_idx]) *
                                      (-0.15 + random() * 1.30))::NUMERIC, 1);

                IF v_value_num < v_test_lo[v_test_idx] THEN
                    v_flag := CASE WHEN v_value_num < v_test_lo[v_test_idx] * 0.5 THEN 'CRITICAL' ELSE 'LOW' END;
                ELSIF v_value_num > v_test_hi[v_test_idx] THEN
                    v_flag := CASE WHEN v_value_num > v_test_hi[v_test_idx] * 1.5 THEN 'CRITICAL' ELSE 'HIGH' END;
                ELSE
                    v_flag := 'NORMAL';
                END IF;

                INSERT INTO lab_results (
                    lab_order_id, result_value, result_unit,
                    reference_range_low, reference_range_high,
                    abnormal_flag, result_date, performed_by
                ) VALUES (
                    v_lab_order_id, v_value_num::TEXT, v_test_units[v_test_idx],
                    v_test_lo[v_test_idx], v_test_hi[v_test_idx],
                    v_flag, enc.encounter_date::DATE + 1, 'Laboratory Services'
                );
            END LOOP;
        END IF;
    END LOOP;

    RAISE NOTICE 'Seeded diagnoses and labs for % closed encounters.', v_diag_counter;
END $$;
