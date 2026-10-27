"""Thin service layer over pkg_clinical_reporting.

Each method corresponds 1:1 to a public function in
plpgsql/packages/pkg_clinical_reporting.sql. The mapping is intentionally
boring: parameter order matches the SQL function's parameter order so the
SQL and the Python call site can be read side by side without translation.
"""

from __future__ import annotations

from datetime import date

from healthcare_app.db.connection import PostgresDatabase


class ReportingService:
    def __init__(self, db: PostgresDatabase):
        self._db = db

    def monthly_appointment_summary(self, start_date: date, end_date: date) -> list[dict]:
        return self._db.call_function(
            "pkg_clinical_reporting.monthly_appointment_summary",
            (start_date, end_date),
        )

    def department_workload_summary(
        self, start_date: date, end_date: date, department_id: int | None = None
    ) -> list[dict]:
        return self._db.call_function(
            "pkg_clinical_reporting.department_workload_summary",
            (start_date, end_date, department_id),
        )

    def cancellation_analysis(self, start_date: date, end_date: date) -> list[dict]:
        return self._db.call_function(
            "pkg_clinical_reporting.cancellation_analysis",
            (start_date, end_date),
        )

    def provider_workload_summary(
        self, start_date: date, end_date: date, provider_id: int | None = None
    ) -> list[dict]:
        return self._db.call_function(
            "pkg_clinical_reporting.provider_workload_summary",
            (start_date, end_date, provider_id),
        )
