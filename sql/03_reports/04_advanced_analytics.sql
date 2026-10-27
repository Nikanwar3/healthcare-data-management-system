--------------------------------------------------------------------------------
-- 04_advanced_analytics.sql
--
-- Window-function based analytics: ROW_NUMBER, RANK/DENSE_RANK, LAG/LEAD,
-- running totals, and month-over-month / department-level comparisons.
-- PostgreSQL's window-function syntax is identical to Oracle's here -- no
-- translation was needed for this file beyond TRUNC(date,'MM') ->
-- DATE_TRUNC('month', date).
--------------------------------------------------------------------------------

-- Q1. "For each patient, number their appointments in chronological order
--      and pull out only the most recent one per patient." (ROW_NUMBER)
SELECT *
FROM (
    SELECT a.patient_id, a.appointment_id, a.scheduled_date, a.status,
           ROW_NUMBER() OVER (PARTITION BY a.patient_id ORDER BY a.scheduled_date DESC) AS rn
    FROM   appointments a
) ranked
WHERE  rn = 1
ORDER BY patient_id;
-- Expected output: exactly one row per patient who has at least one
-- appointment -- the "most recent appointment" view.


-- Q2. "Rank providers by total appointment volume, with ties sharing a
--      rank." (RANK vs. DENSE_RANK side by side)
SELECT pr.provider_id, pr.first_name || ' ' || pr.last_name AS provider_name,
       COUNT(a.appointment_id) AS total_appointments,
       RANK()       OVER (ORDER BY COUNT(a.appointment_id) DESC) AS volume_rank,
       DENSE_RANK() OVER (ORDER BY COUNT(a.appointment_id) DESC) AS volume_dense_rank
FROM   providers pr
LEFT JOIN appointments a ON a.provider_id = pr.provider_id
GROUP BY pr.provider_id, pr.first_name, pr.last_name
ORDER BY volume_rank;
-- RANK() leaves gaps after ties (1,1,3); DENSE_RANK() does not (1,1,2) --
-- shown together so the difference is visible in the result set.


-- Q3. "Month-over-month change in completed-appointment volume, department
--      by department." (LAG)
WITH monthly_completed AS (
    SELECT department_id, DATE_TRUNC('month', scheduled_date) AS month_start,
           COUNT(*) AS completed_count
    FROM   appointments
    WHERE  status = 'COMPLETED'
    GROUP BY department_id, DATE_TRUNC('month', scheduled_date)
)
SELECT d.department_name, mc.month_start, mc.completed_count,
       LAG(mc.completed_count) OVER (
           PARTITION BY mc.department_id ORDER BY mc.month_start
       ) AS prior_month_count,
       mc.completed_count - LAG(mc.completed_count) OVER (
           PARTITION BY mc.department_id ORDER BY mc.month_start
       ) AS change_vs_prior_month
FROM   monthly_completed mc
JOIN   departments d ON d.department_id = mc.department_id
ORDER BY d.department_name, mc.month_start;
-- prior_month_count and change_vs_prior_month are NULL for each
-- department's first observed month -- there is nothing to compare against,
-- by definition, not a data error.


-- Q4. "What's the very next scheduled appointment after each completed
--      appointment, for the same patient?" (LEAD)
SELECT patient_id, appointment_id, scheduled_date, status,
       LEAD(scheduled_date) OVER (PARTITION BY patient_id ORDER BY scheduled_date) AS next_appointment_date,
       LEAD(status)         OVER (PARTITION BY patient_id ORDER BY scheduled_date) AS next_appointment_status
FROM   appointments
ORDER BY patient_id, scheduled_date;


-- Q5. "Running total of completed appointments per department over time"
--     (classic running-total window frame).
WITH monthly_completed AS (
    SELECT department_id, DATE_TRUNC('month', scheduled_date) AS month_start,
           COUNT(*) AS completed_count
    FROM   appointments
    WHERE  status = 'COMPLETED'
    GROUP BY department_id, DATE_TRUNC('month', scheduled_date)
)
SELECT d.department_name, mc.month_start, mc.completed_count,
       SUM(mc.completed_count) OVER (
           PARTITION BY mc.department_id ORDER BY mc.month_start
           ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
       ) AS running_total_completed
FROM   monthly_completed mc
JOIN   departments d ON d.department_id = mc.department_id
ORDER BY d.department_name, mc.month_start;


-- Q6. "Each provider's appointment volume vs. their department's average
--      for the same month" (department-level comparison window).
WITH provider_monthly AS (
    SELECT provider_id, department_id, DATE_TRUNC('month', scheduled_date) AS month_start,
           COUNT(*) AS appt_count
    FROM   appointments
    GROUP BY provider_id, department_id, DATE_TRUNC('month', scheduled_date)
)
SELECT pr.first_name || ' ' || pr.last_name AS provider_name,
       d.department_name, pm.month_start, pm.appt_count,
       ROUND(AVG(pm.appt_count) OVER (
           PARTITION BY pm.department_id, pm.month_start
       ), 1) AS department_avg_for_month,
       pm.appt_count - ROUND(AVG(pm.appt_count) OVER (
           PARTITION BY pm.department_id, pm.month_start
       ), 1) AS variance_from_dept_avg
FROM   provider_monthly pm
JOIN   providers pr ON pr.provider_id = pm.provider_id
JOIN   departments d ON d.department_id = pm.department_id
ORDER BY d.department_name, pm.month_start, provider_name;
