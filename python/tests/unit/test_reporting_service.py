from datetime import date
from unittest.mock import MagicMock

from healthcare_app.services.reporting_service import ReportingService


def test_monthly_appointment_summary_calls_db_with_expected_params():
    fake_db = MagicMock()
    fake_db.call_function.return_value = [{"total_appointments": 10}]

    service = ReportingService(fake_db)
    result = service.monthly_appointment_summary(date(2025, 1, 1), date(2025, 2, 1))

    assert result == [{"total_appointments": 10}]
    fake_db.call_function.assert_called_once_with(
        "pkg_clinical_reporting.monthly_appointment_summary",
        (date(2025, 1, 1), date(2025, 2, 1)),
    )


def test_department_workload_summary_passes_optional_department_id():
    fake_db = MagicMock()
    fake_db.call_function.return_value = []

    service = ReportingService(fake_db)
    service.department_workload_summary(date(2025, 1, 1), date(2025, 2, 1), department_id=3)

    args, _ = fake_db.call_function.call_args
    assert args[1] == (date(2025, 1, 1), date(2025, 2, 1), 3)


def test_department_workload_summary_defaults_department_id_to_none():
    fake_db = MagicMock()
    fake_db.call_function.return_value = []

    service = ReportingService(fake_db)
    service.department_workload_summary(date(2025, 1, 1), date(2025, 2, 1))

    args, _ = fake_db.call_function.call_args
    assert args[1][2] is None


def test_cancellation_analysis_calls_expected_function():
    fake_db = MagicMock()
    fake_db.call_function.return_value = [{"cancellation_rate_pct": 15.0}]

    service = ReportingService(fake_db)
    result = service.cancellation_analysis(date(2025, 1, 1), date(2025, 2, 1))

    assert result == [{"cancellation_rate_pct": 15.0}]
    function_name = fake_db.call_function.call_args[0][0]
    assert function_name == "pkg_clinical_reporting.cancellation_analysis"


def test_provider_workload_summary_passes_provider_id():
    fake_db = MagicMock()
    fake_db.call_function.return_value = []

    service = ReportingService(fake_db)
    service.provider_workload_summary(date(2025, 1, 1), date(2025, 2, 1), provider_id=7)

    args, _ = fake_db.call_function.call_args
    assert args[1] == (date(2025, 1, 1), date(2025, 2, 1), 7)
