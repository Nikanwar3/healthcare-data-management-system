"""Thin service layer over pkg_data_quality.

Every pkg_data_quality check is a RETURNS SETOF function, so each read
method here runs a `SELECT * FROM pkg_data_quality.<fn>(...)` via
PostgresDatabase.call_function. merge_staging_appointment is a PROCEDURE
(it performs DML), so it goes through call_procedure instead.
"""

from __future__ import annotations

from healthcare_app.calculations import classify_findings_by_severity
from healthcare_app.db.connection import PostgresDatabase


class DataQualityService:
    def __init__(self, db: PostgresDatabase):
        self._db = db

    def run_all_checks(self) -> list[dict]:
        return self._db.call_function("pkg_data_quality.run_all_checks")

    def run_all_checks_summary(self) -> dict:
        """run_all_checks(), pre-classified into errors/warnings with a
        `blocks_merge` flag -- the shape a CI gate or dashboard wants.
        """
        return classify_findings_by_severity(self.run_all_checks())

    def validate_staging_appointments(self, stg_id: int | None = None) -> list[dict]:
        return self._db.call_function(
            "pkg_data_quality.validate_staging_appointments", (stg_id,)
        )

    def merge_staging_appointment(self, stg_id: int) -> None:
        """Validate and merge one staging row into appointments.

        Raises DataQualityGateError (SQLSTATE HC003) if the row fails
        validation, or InvalidIdentifierError (SQLSTATE HC002) if stg_id
        does not exist -- see pkg_data_quality.merge_staging_appointment.
        """
        self._db.call_procedure("pkg_data_quality.merge_staging_appointment", (stg_id,))

    def detect_duplicate_patient_identifiers(self) -> list[dict]:
        return self._db.call_function("pkg_data_quality.detect_duplicate_patient_identifiers")

    def detect_duplicate_diagnoses(self) -> list[dict]:
        return self._db.call_function("pkg_data_quality.detect_duplicate_diagnoses")

    def detect_duplicate_lab_results(self) -> list[dict]:
        return self._db.call_function("pkg_data_quality.detect_duplicate_lab_results")

    def detect_incomplete_lab_orders(self) -> list[dict]:
        return self._db.call_function("pkg_data_quality.detect_incomplete_lab_orders")
