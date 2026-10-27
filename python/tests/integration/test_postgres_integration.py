"""Integration tests against a real, disposable PostgreSQL database.

Unlike the Oracle version of this project, these actually run: `pg_test_db`
(see conftest.py) builds a fresh database from this project's own sql/ and
plpgsql/ files before the first test and drops it after the last one. Skipped
automatically (not failed) if POSTGRES_HOST/POSTGRES_USER are not set or the
server is not reachable -- see tests/integration/README.md.
"""

from datetime import date

import pytest

from healthcare_app.exceptions import DataQualityGateError, InvalidDateRangeError, InvalidIdentifierError
from healthcare_app.services.data_quality_service import DataQualityService
from healthcare_app.services.reporting_service import ReportingService

pytestmark = pytest.mark.postgres


def test_monthly_appointment_summary_returns_rows_within_range(pg_test_db):
    service = ReportingService(pg_test_db)
    rows = service.monthly_appointment_summary(date(2025, 1, 1), date(2025, 4, 1))
    assert isinstance(rows, list)
    assert len(rows) == 3
    for row in rows:
        assert date(2025, 1, 1) <= row["month_start"] < date(2025, 4, 1)
        assert row["total_appointments"] == (
            row["completed"] + row["cancelled"] + row["no_show"] + row["still_scheduled"]
        )


def test_monthly_appointment_summary_rejects_inverted_date_range(pg_test_db):
    service = ReportingService(pg_test_db)
    with pytest.raises(InvalidDateRangeError):
        service.monthly_appointment_summary(date(2025, 6, 1), date(2025, 1, 1))


def test_department_workload_summary_rejects_unknown_department(pg_test_db):
    service = ReportingService(pg_test_db)
    with pytest.raises(InvalidIdentifierError):
        service.department_workload_summary(date(2025, 1, 1), date(2025, 10, 1), department_id=999999)


def test_department_workload_summary_scoped_to_one_department(pg_test_db):
    service = ReportingService(pg_test_db)
    rows = service.department_workload_summary(date(2025, 1, 1), date(2025, 10, 1), department_id=1)
    assert len(rows) == 1
    assert rows[0]["department_id"] == 1
    assert rows[0]["department_name"] == "Cardiology"


def test_provider_workload_summary_rejects_unknown_provider(pg_test_db):
    service = ReportingService(pg_test_db)
    with pytest.raises(InvalidIdentifierError):
        service.provider_workload_summary(date(2025, 1, 1), date(2025, 10, 1), provider_id=999999)


def test_cancellation_analysis_rates_are_consistent(pg_test_db):
    service = ReportingService(pg_test_db)
    rows = service.cancellation_analysis(date(2025, 1, 1), date(2025, 10, 1))
    assert len(rows) == 6  # one per seeded department
    for row in rows:
        expected_rate = round(100.0 * row["cancelled_total"] / row["total_appointments"], 1)
        assert float(row["cancellation_rate_pct"]) == pytest.approx(expected_rate, abs=0.05)
        assert row["cancelled_with_reason"] + row["cancelled_missing_reason"] == row["cancelled_total"]


def test_run_all_checks_returns_only_error_or_warning_severities(pg_test_db):
    service = DataQualityService(pg_test_db)
    findings = service.run_all_checks()
    assert len(findings) > 0
    for finding in findings:
        assert finding["severity"] in ("ERROR", "WARNING")
        assert finding["entity_id"]


def test_run_all_checks_finds_the_seeded_incomplete_lab_order(pg_test_db):
    service = DataQualityService(pg_test_db)
    findings = service.run_all_checks()
    rule_names = {f["rule_name"] for f in findings}
    # Guaranteed by sql/02_data/05_seed_dirty_data_demo.sql.
    assert "INCOMPLETE_LAB_ORDER" in rule_names
    assert "DUPLICATE_DIAGNOSIS" in rule_names
    assert "DUPLICATE_LAB_RESULT" in rule_names
    assert "MISSING_REFERENCE_RANGE" in rule_names


def test_validate_staging_appointments_flags_known_seeded_defects(pg_test_db):
    service = DataQualityService(pg_test_db)
    findings = service.validate_staging_appointments()
    rule_names = {f["rule_name"] for f in findings}
    assert "STAGING_UNKNOWN_PATIENT" in rule_names
    assert "STAGING_UNKNOWN_PROVIDER" in rule_names
    assert "STAGING_INVALID_DATE" in rule_names
    assert "STAGING_MISSING_PATIENT_MRN" in rule_names
    assert len(findings) == 4


def test_validate_staging_appointments_clean_row_has_no_findings(pg_test_db):
    service = DataQualityService(pg_test_db)
    assert service.validate_staging_appointments(stg_id=1) == []


def test_validate_staging_appointments_unknown_stg_id_raises(pg_test_db):
    service = DataQualityService(pg_test_db)
    with pytest.raises(InvalidIdentifierError):
        service.validate_staging_appointments(stg_id=999999)


def test_merge_staging_appointment_inserts_and_clears_clean_row(pg_test_db):
    service = DataQualityService(pg_test_db)
    reporting = ReportingService(pg_test_db)

    before = reporting.monthly_appointment_summary(date(2025, 1, 1), date(2025, 10, 1))
    total_before = sum(r["total_appointments"] for r in before)

    service.merge_staging_appointment(1)  # the one clean seeded staging row

    remaining = pg_test_db.execute_query("SELECT COUNT(*) AS n FROM stg_appointments_raw WHERE stg_id = 1")
    assert remaining[0]["n"] == 0

    after = reporting.monthly_appointment_summary(date(2025, 1, 1), date(2025, 10, 1))
    total_after = sum(r["total_appointments"] for r in after)
    assert total_after == total_before + 1


def test_merge_staging_appointment_rejects_row_that_fails_validation(pg_test_db):
    service = DataQualityService(pg_test_db)
    before_count = pg_test_db.execute_query("SELECT COUNT(*) AS n FROM appointments")[0]["n"]

    with pytest.raises(DataQualityGateError):
        service.merge_staging_appointment(2)  # unknown patient MRN, see seed data

    after_count = pg_test_db.execute_query("SELECT COUNT(*) AS n FROM appointments")[0]["n"]
    assert after_count == before_count  # no partial write

    still_staged = pg_test_db.execute_query(
        "SELECT COUNT(*) AS n FROM stg_appointments_raw WHERE stg_id = 2"
    )
    assert still_staged[0]["n"] == 1  # not removed either


def test_merge_staging_appointment_unknown_stg_id_raises(pg_test_db):
    service = DataQualityService(pg_test_db)
    with pytest.raises(InvalidIdentifierError):
        service.merge_staging_appointment(999999)
