--------------------------------------------------------------------------------
-- 01_create_views.sql
--
-- Small convenience views that encapsulate joins used repeatedly across
-- reports, so both ad hoc SQL and the Python layer can query a stable,
-- documented shape instead of re-deriving the join every time.
--------------------------------------------------------------------------------

CREATE OR REPLACE VIEW v_active_providers AS
SELECT provider_id, first_name, last_name, specialty, department_id, npi_number, email, hire_date
FROM   providers
WHERE  is_active = 'Y';

COMMENT ON VIEW v_active_providers IS 'Providers currently accepting appointments (is_active = Y).';


CREATE OR REPLACE VIEW v_completed_appointment_detail AS
SELECT a.appointment_id, a.scheduled_date, a.appointment_type,
       p.patient_id, p.mrn, p.first_name || ' ' || p.last_name AS patient_name,
       pr.provider_id, pr.first_name || ' ' || pr.last_name    AS provider_name, pr.specialty,
       d.department_id, d.department_name,
       ce.encounter_id, ce.encounter_type, ce.encounter_status
FROM   appointments a
JOIN   patients p         ON p.patient_id = a.patient_id
JOIN   providers pr       ON pr.provider_id = a.provider_id
JOIN   departments d      ON d.department_id = a.department_id
JOIN   clinical_encounters ce ON ce.appointment_id = a.appointment_id
WHERE  a.status = 'COMPLETED';

COMMENT ON VIEW v_completed_appointment_detail IS 'One row per completed appointment with its encounter, patient, provider, and department resolved -- the base view most clinical reports join from.';
