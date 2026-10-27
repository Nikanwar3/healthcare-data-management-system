--------------------------------------------------------------------------------
-- 01_basic_operations.sql
--
-- Fundamental SQL operations: filtering/sorting, DML, aggregates, CASE, NULLs.
-- Each query states the business question it answers, expected output shape,
-- and any assumptions.
--------------------------------------------------------------------------------

-- Q1. "Show me every scheduled appointment for next week sorted by time."
--     (Here: appointments scheduled in September 2025, newest first, as a
--     stand-in for "the current reporting window" -- see the note on date
--     handling in docs/architecture.md.)
SELECT appointment_id, patient_id, provider_id, scheduled_date, appointment_type, status
FROM   appointments
WHERE  scheduled_date >= TIMESTAMP '2025-09-01'
AND    scheduled_date <  TIMESTAMP '2025-10-01'
ORDER BY scheduled_date DESC;
-- Expected output: 0+ rows, one per appointment in September 2025, most
-- recent first. Assumption: scheduled_date boundaries use half-open ranges
-- ([start, end)) to avoid off-by-one errors at midnight.


-- Q2. "Register a new patient." (parameterized INSERT; literals shown here
--     for a runnable example -- the Python layer always binds these values).
INSERT INTO patients (mrn, first_name, last_name, date_of_birth, gender, phone, email, insurance_provider)
VALUES ('MRN000061', 'Alex', 'Rivera', DATE '1990-06-14', 'O', '555-0399', 'alex.rivera@example.test', 'Aetna');
-- Expected output: INSERT 0 1. Fails with a unique_violation on constraint
-- uq_patients_mrn if MRN000061 already exists -- demonstrates the UNIQUE
-- constraint doing its job.


-- Q3. "A patient's phone number changed -- update it."
UPDATE patients
SET    phone = '555-0470'
WHERE  mrn = 'MRN000061';
-- Expected output: UPDATE 1 (UPDATE 0 if the MRN does not exist -- the Python
-- layer checks cursor.rowcount and treats 0 as "not found", not as success).


-- Q4. "Remove a test patient record created in error."
--     Only safe when the patient has no dependent appointments (FK would
--     otherwise reject the delete -- which is the correct behavior).
DELETE FROM patients
WHERE  mrn = 'MRN000061'
AND    NOT EXISTS (SELECT 1 FROM appointments a WHERE a.patient_id = patients.patient_id);
-- Expected output: DELETE 1, or DELETE 0 if the patient has appointments (in
-- which case a plain DELETE without the guard would raise a
-- foreign_key_violation instead).


-- Q5. "How many appointments do we have, broken out by status?"
SELECT status, COUNT(*) AS appointment_count
FROM   appointments
GROUP BY status
ORDER BY appointment_count DESC;
-- Expected output: one row per distinct status (SCHEDULED/COMPLETED/
-- CANCELLED/NO_SHOW), counts summing to total appointment volume.


-- Q6. "What's the average, min, and max patient age in the system?"
SELECT ROUND(AVG(EXTRACT(YEAR FROM AGE(CURRENT_DATE, date_of_birth)))::NUMERIC, 1) AS avg_age_years,
       MIN(EXTRACT(YEAR FROM AGE(CURRENT_DATE, date_of_birth)))                    AS min_age_years,
       MAX(EXTRACT(YEAR FROM AGE(CURRENT_DATE, date_of_birth)))                    AS max_age_years
FROM   patients;
-- Expected output: a single row. Uses CURRENT_DATE deliberately (age is
-- always "as of now", unlike report date-range boundaries which must be
-- parameterized).


-- Q7. "Label each appointment as Past Due, Today, or Upcoming, and flag
--      stale SCHEDULED rows." (CASE expression)
SELECT appointment_id, scheduled_date, status,
       CASE
           WHEN scheduled_date::DATE < CURRENT_DATE THEN 'PAST'
           WHEN scheduled_date::DATE = CURRENT_DATE THEN 'TODAY'
           ELSE 'UPCOMING'
       END AS relative_timing,
       CASE
           WHEN status = 'SCHEDULED' AND scheduled_date::DATE < CURRENT_DATE
               THEN 'DATA QUALITY: stale SCHEDULED appointment'
           ELSE NULL
       END AS data_quality_flag
FROM   appointments
ORDER BY scheduled_date;
-- Expected output: every appointment row, annotated. data_quality_flag is
-- NULL for the overwhelming majority and non-NULL only for the intentionally
-- seeded "stale SCHEDULED" demo rows (see 02_data/03_seed_appointments_encounters.sql).


-- Q8. "Which patients have no email on file?" (NULL handling)
SELECT patient_id, mrn, first_name, last_name
FROM   patients
WHERE  email IS NULL
ORDER BY patient_id;
-- Expected output: 0 rows in the seed dataset (every synthetic patient gets
-- a generated email) -- included to show correct NULL-safe filtering
-- (`= NULL` would silently match nothing; `IS NULL` is required).


-- Q9. "List providers, showing 'Not yet contacted' instead of a blank email."
--     (COALESCE for NULL handling in presentation)
SELECT provider_id, first_name, last_name,
       COALESCE(email, 'Not yet contacted') AS contact_email
FROM   providers
ORDER BY last_name, first_name;
