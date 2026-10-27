import pytest

from healthcare_app.calculations import (
    cancellation_rate,
    classify_findings_by_severity,
    completion_rate,
    safe_rate,
    summarize_by_department,
    summarize_monthly_rows,
)
from tests.fixtures.sample_data import (
    data_quality_findings,
    department_workload_rows,
    empty_rows,
    monthly_summary_rows,
)


class TestSafeRate:
    def test_normal_division(self):
        assert safe_rate(50, 200) == 25.0

    def test_zero_denominator_returns_zero_not_error(self):
        assert safe_rate(5, 0) == 0.0

    def test_rounds_to_requested_decimals(self):
        assert safe_rate(1, 3, decimals=2) == 33.33


class TestCompletionAndCancellationRate:
    def test_completion_rate(self):
        assert completion_rate(total=100, completed=70) == 70.0

    def test_cancellation_rate(self):
        assert cancellation_rate(total=100, cancelled=20) == 20.0

    def test_completion_rate_with_no_appointments(self):
        assert completion_rate(total=0, completed=0) == 0.0


class TestSummarizeMonthlyRows:
    def test_totals_across_months(self):
        totals = summarize_monthly_rows(monthly_summary_rows())
        assert totals["total_appointments"] == 150
        assert totals["completed"] == 100
        assert totals["cancelled"] == 30
        assert totals["months_covered"] == 2

    def test_completion_and_cancellation_rate_derived_correctly(self):
        totals = summarize_monthly_rows(monthly_summary_rows())
        assert totals["completion_rate_pct"] == pytest.approx(66.7, abs=0.1)
        assert totals["cancellation_rate_pct"] == 20.0

    def test_empty_dataset_does_not_raise(self):
        totals = summarize_monthly_rows(empty_rows())
        assert totals["total_appointments"] == 0
        assert totals["completion_rate_pct"] == 0.0
        assert totals["months_covered"] == 0

    def test_missing_keys_treated_as_zero(self):
        totals = summarize_monthly_rows([{"total_appointments": 10}])
        assert totals["completed"] == 0
        assert totals["cancellation_rate_pct"] == 0.0


class TestSummarizeByDepartment:
    def test_ranks_by_total_appointments_descending(self):
        ranked = summarize_by_department(department_workload_rows())
        assert [r["department_name"] for r in ranked] == [
            "Family Medicine", "Cardiology", "Orthopedics",
        ]
        assert [r["rank"] for r in ranked] == [1, 2, 3]

    def test_empty_input_returns_empty_output(self):
        assert summarize_by_department(empty_rows()) == []

    def test_does_not_mutate_caller_list_identity(self):
        original = department_workload_rows()
        result = summarize_by_department(original)
        assert result is not original


class TestClassifyFindingsBySeverity:
    def test_splits_errors_and_warnings(self):
        result = classify_findings_by_severity(data_quality_findings())
        assert result["error_count"] == 1
        assert result["warning_count"] == 2
        assert result["blocks_merge"] is True

    def test_no_errors_means_does_not_block_merge(self):
        warnings_only = [f for f in data_quality_findings() if f["severity"] == "WARNING"]
        result = classify_findings_by_severity(warnings_only)
        assert result["blocks_merge"] is False

    def test_empty_findings(self):
        result = classify_findings_by_severity(empty_rows())
        assert result == {
            "errors": [], "warnings": [], "error_count": 0, "warning_count": 0, "blocks_merge": False,
        }

    def test_unrecognized_severity_raises(self):
        with pytest.raises(ValueError, match="Unrecognized"):
            classify_findings_by_severity([{"severity": "INFO"}])
