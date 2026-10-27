--------------------------------------------------------------------------------
-- 02_seed_patients.sql
--
-- Generates 60 synthetic patients via a PL/pgSQL anonymous block (first/last
-- name pools, derived DOB and gender). All values are fabricated -- no real
-- patient data. MRNs follow the pattern MRN000001 .. MRN000060.
--------------------------------------------------------------------------------

DO $$
DECLARE
    v_first_names TEXT[] := ARRAY[
        'James','Mary','Robert','Patricia','John','Jennifer','Michael','Linda',
        'William','Elizabeth','David','Barbara','Richard','Susan','Joseph','Jessica',
        'Thomas','Sarah','Charles','Karen','Daniel','Nancy','Matthew','Lisa',
        'Anthony','Betty','Mark','Margaret','Paul','Sandra'
    ];
    v_last_names TEXT[] := ARRAY[
        'Smith','Johnson','Williams','Brown','Jones','Garcia','Miller','Davis',
        'Rodriguez','Martinez','Hernandez','Lopez','Gonzalez','Wilson','Anderson',
        'Thomas','Taylor','Moore','Jackson','Martin','Lee','Perez','Thompson',
        'White','Harris','Sanchez','Clark','Ramirez','Lewis','Robinson'
    ];
    v_insurers TEXT[] := ARRAY[
        'Aetna', 'BlueShield Horizon', 'UnitedHealth', 'Cigna', 'Medicare', 'Medicaid'
    ];
    v_gender_cycle CHAR(1);
    v_mrn          VARCHAR(12);
    v_dob          DATE;
BEGIN
    FOR i IN 1 .. 60 LOOP
        v_mrn := 'MRN' || LPAD(i::TEXT, 6, '0');

        -- Deterministic pseudo-variety, not true randomness: keeps the
        -- dataset reproducible across environments without needing a fixed
        -- random seed table.
        v_gender_cycle := CASE MOD(i, 4)
                              WHEN 0 THEN 'M'
                              WHEN 1 THEN 'F'
                              WHEN 2 THEN 'M'
                              ELSE 'F'
                          END;

        -- Spread birth years from 1940 to 2015 across the 60 patients.
        v_dob := DATE '1940-01-01' + (MOD(i * 137, 27500));

        INSERT INTO patients (
            mrn, first_name, last_name, date_of_birth, gender,
            phone, email, insurance_provider
        ) VALUES (
            v_mrn,
            v_first_names[MOD(i, array_length(v_first_names, 1)) + 1],
            v_last_names[MOD(i * 3, array_length(v_last_names, 1)) + 1],
            v_dob,
            v_gender_cycle,
            '555-' || LPAD(TRUNC(1000 + random() * 8999)::TEXT, 4, '0'),
            LOWER(v_first_names[MOD(i, array_length(v_first_names, 1)) + 1] || '.' ||
                  v_last_names[MOD(i * 3, array_length(v_last_names, 1)) + 1] || i || '@example.test'),
            v_insurers[MOD(i, array_length(v_insurers, 1)) + 1]
        );
    END LOOP;

    RAISE NOTICE 'Inserted 60 synthetic patients (MRN000001..MRN000060).';
END $$;
