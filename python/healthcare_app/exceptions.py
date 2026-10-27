"""Domain-level exceptions.

PostgreSQL errors (psycopg2.Error) are translated into these at the service
boundary so callers (CLI, tests) can catch a stable, documented exception
type instead of parsing SQLSTATE codes or depending on a specific driver's
exception hierarchy.
"""

from __future__ import annotations


class HealthcareAppError(Exception):
    """Base class for every exception this application raises intentionally."""


class ConfigurationError(HealthcareAppError):
    """Required configuration (env vars) is missing or invalid."""


class DatabaseConnectionError(HealthcareAppError):
    """Could not establish or use a connection to PostgreSQL."""


class InvalidDateRangeError(HealthcareAppError):
    """Mirrors pkg_clinical_reporting.validate_date_range (SQLSTATE HC001)."""


class InvalidIdentifierError(HealthcareAppError):
    """Mirrors pkg_clinical_reporting/pkg_data_quality identifier checks (SQLSTATE HC002)."""


class DataQualityGateError(HealthcareAppError):
    """Mirrors pkg_data_quality.merge_staging_appointment's validation gate (SQLSTATE HC003)."""


class ReportExecutionError(HealthcareAppError):
    """A report or data-quality check failed for a reason other than the above."""


class ExportError(HealthcareAppError):
    """Writing a report result to CSV/JSON failed."""
