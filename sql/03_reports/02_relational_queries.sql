--------------------------------------------------------------------------------
-- 02_relational_queries.sql
--
-- JOIN patterns, subqueries, correlated subqueries, CTEs, and set operations.
--------------------------------------------------------------------------------

-- Q1. "Show each appointment with the patient's and provider's full name."
--     (INNER JOIN x2 -- every appointment is guaranteed a patient and
--     provider by FK constraints, so INNER is correct here, not LEFT.)
SELECT a.appointment_id,
       p.first_name || ' ' || p.last_name  AS patient_name,
       pr.first_name || ' ' || pr.last_name AS provider_name,
       a.scheduled_date, a.status
FROM   appointments a
JOIN   patients  p  ON p.patient_id  = a.patient_id
JOIN   providers pr ON pr.provider_id = a.provider_id
ORDER BY a.scheduled_date DESC
FETCH FIRST 25 ROWS ONLY;
-- Expected output: up to 25 rows, most recent appointments first.


-- Q2. "List every provider together with their encounter count, including
--      providers who have never seen a patient." (LEFT JOIN + aggregate)
SELECT pr.provider_id, pr.first_name || ' ' || pr.last_name AS provider_name,
       COUNT(ce.encounter_id) AS encounter_count
FROM   providers pr
LEFT JOIN clinical_encounters ce ON ce.provider_id = pr.provider_id
GROUP BY pr.provider_id, pr.first_name, pr.last_name
ORDER BY encounter_count DESC, provider_name;
-- Expected output: one row per provider (13 in the seed data), including
-- zero-encounter providers -- an INNER JOIN would silently drop them, which
-- is exactly the kind of bug documented as Scenario 1 in
-- docs/root-cause-analysis.md.


-- Q3. "Full clinical picture for a single patient: appointments, encounters,
--      diagnoses, and any lab orders, in one row set." (multi-table join)
SELECT a.appointment_id, a.scheduled_date, a.status,
       ce.encounter_id, ce.encounter_type,
       d.icd10_code, d.diagnosis_description, d.diagnosis_type,
       lo.lab_order_id, lo.test_name, lo.status AS lab_status
FROM   appointments a
JOIN   patients p              ON p.patient_id = a.patient_id
LEFT JOIN clinical_encounters ce ON ce.appointment_id = a.appointment_id
LEFT JOIN diagnoses d            ON d.encounter_id = ce.encounter_id
LEFT JOIN lab_orders lo          ON lo.encounter_id = ce.encounter_id
WHERE  p.mrn = 'MRN000001'
ORDER BY a.scheduled_date, d.diagnosis_type, lo.lab_order_id;
-- Expected output: one row per (appointment x diagnosis x lab_order)
-- combination for this patient -- intentionally a fan-out join. See
-- Scenario 2 in docs/root-cause-analysis.md for why this duplicates
-- appointment-level detail when a patient has multiple diagnoses AND
-- multiple lab orders on the same encounter, and how to avoid miscounting
-- because of it.


-- Q4. "Which patients have had more than 3 completed appointments?"
--     (subquery in WHERE, scalar aggregate)
SELECT patient_id, first_name, last_name
FROM   patients p
WHERE  p.patient_id IN (
    SELECT a.patient_id
    FROM   appointments a
    WHERE  a.status = 'COMPLETED'
    GROUP BY a.patient_id
    HAVING COUNT(*) > 3
)
ORDER BY last_name, first_name;


-- Q5. "For each appointment, how does it compare to that patient's average
--      number of completed appointments?" (correlated subquery)
SELECT a.appointment_id, a.patient_id, a.scheduled_date,
       (SELECT COUNT(*)
        FROM   appointments a2
        WHERE  a2.patient_id = a.patient_id
        AND    a2.status = 'COMPLETED') AS patient_completed_appt_count
FROM   appointments a
WHERE  a.status = 'COMPLETED'
ORDER BY patient_completed_appt_count DESC, a.scheduled_date
FETCH FIRST 20 ROWS ONLY;


-- Q6. "Providers who have never had a CANCELLED appointment." (correlated
--      NOT EXISTS -- generally preferable to NOT IN when the inner column
--      can contain NULLs, which NOT IN handles incorrectly)
SELECT pr.provider_id, pr.first_name, pr.last_name
FROM   providers pr
WHERE  NOT EXISTS (
    SELECT 1 FROM appointments a
    WHERE  a.provider_id = pr.provider_id
    AND    a.status = 'CANCELLED'
)
ORDER BY pr.last_name;


-- Q7. "Department-level summary: total appointments, completed, cancelled,
--      and the completion rate." (CTE for readability)
WITH dept_totals AS (
    SELECT d.department_id, d.department_name,
           COUNT(*)                                            AS total_appts,
           SUM(CASE WHEN a.status = 'COMPLETED' THEN 1 ELSE 0 END) AS completed_appts,
           SUM(CASE WHEN a.status = 'CANCELLED' THEN 1 ELSE 0 END) AS cancelled_appts
    FROM   departments d
    JOIN   appointments a ON a.department_id = d.department_id
    GROUP BY d.department_id, d.department_name
)
SELECT department_name, total_appts, completed_appts, cancelled_appts,
       ROUND(100.0 * completed_appts / NULLIF(total_appts, 0), 1) AS completion_rate_pct
FROM   dept_totals
ORDER BY total_appts DESC;
-- Note: NULLIF(total_appts, 0) guards the division -- a department with zero
-- appointments yields NULL (not a division_by_zero error). The 100.0 literal
-- (not 100) is required in PostgreSQL: COUNT()/SUM() return bigint, and
-- bigint / bigint is truncating integer division -- 100.0 forces numeric
-- division so the percentage keeps its fractional part.


-- Q8. "One combined roster of everyone who touched Patient MRN000001's
--      care: every distinct provider from appointments UNION every
--      distinct provider from lab orders." (set operation)
SELECT DISTINCT pr.provider_id, pr.first_name, pr.last_name, 'APPOINTMENT' AS touchpoint
FROM   providers pr
JOIN   appointments a ON a.provider_id = pr.provider_id
JOIN   patients p ON p.patient_id = a.patient_id
WHERE  p.mrn = 'MRN000001'
UNION
SELECT DISTINCT pr.provider_id, pr.first_name, pr.last_name, 'LAB_ORDER' AS touchpoint
FROM   providers pr
JOIN   lab_orders lo ON lo.provider_id = pr.provider_id
JOIN   patients p ON p.patient_id = lo.patient_id
WHERE  p.mrn = 'MRN000001'
ORDER BY last_name, first_name;
-- UNION (not UNION ALL) because we want one combined, de-duplicated roster.
