from unittest.mock import MagicMock

from healthcare_app.services.data_quality_service import DataQualityService
from tests.fixtures.sample_data import data_quality_findings, empty_rows


def test_run_all_checks_calls_expected_function():
    fake_db = MagicMock()
    fake_db.call_function.return_value = data_quality_findings()

    service = DataQualityService(fake_db)
    result = service.run_all_checks()

    assert result == data_quality_findings()
    fake_db.call_function.assert_called_once_with("pkg_data_quality.run_all_checks")


def test_run_all_checks_summary_classifies_findings():
    fake_db = MagicMock()
    fake_db.call_function.return_value = data_quality_findings()

    service = DataQualityService(fake_db)
    summary = service.run_all_checks_summary()

    assert summary["error_count"] == 1
    assert summary["warning_count"] == 2
    assert summary["blocks_merge"] is True


def test_run_all_checks_summary_with_no_findings_does_not_block():
    fake_db = MagicMock()
    fake_db.call_function.return_value = empty_rows()

    service = DataQualityService(fake_db)
    summary = service.run_all_checks_summary()

    assert summary["blocks_merge"] is False


def test_validate_staging_appointments_passes_stg_id():
    fake_db = MagicMock()
    fake_db.call_function.return_value = []

    service = DataQualityService(fake_db)
    service.validate_staging_appointments(stg_id=42)

    call_args = fake_db.call_function.call_args[0]
    assert call_args[0] == "pkg_data_quality.validate_staging_appointments"
    assert call_args[1] == (42,)


def test_validate_staging_appointments_defaults_to_none():
    fake_db = MagicMock()
    fake_db.call_function.return_value = []

    service = DataQualityService(fake_db)
    service.validate_staging_appointments()

    call_args = fake_db.call_function.call_args[0]
    assert call_args[1] == (None,)


def test_merge_staging_appointment_calls_procedure():
    fake_db = MagicMock()

    service = DataQualityService(fake_db)
    service.merge_staging_appointment(5)

    fake_db.call_procedure.assert_called_once_with(
        "pkg_data_quality.merge_staging_appointment", (5,)
    )
