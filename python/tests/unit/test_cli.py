from datetime import date
from unittest.mock import MagicMock, patch

import pytest

from healthcare_app.cli import build_parser, cmd_check_connection, main
from healthcare_app.exceptions import ConfigurationError


class TestArgumentParsing:
    def test_monthly_summary_parses_dates_and_defaults(self):
        parser = build_parser()
        args = parser.parse_args(["monthly-summary", "--start", "2025-01-01", "--end", "2025-02-01"])
        assert args.start == date(2025, 1, 1)
        assert args.end == date(2025, 2, 1)
        assert args.format == "csv"
        assert args.output is None

    def test_invalid_date_format_raises_system_exit(self):
        parser = build_parser()
        with pytest.raises(SystemExit):
            parser.parse_args(["monthly-summary", "--start", "01/01/2025", "--end", "2025-02-01"])

    def test_department_workload_optional_department_id(self):
        parser = build_parser()
        args = parser.parse_args([
            "department-workload", "--start", "2025-01-01", "--end", "2025-02-01",
            "--department-id", "3",
        ])
        assert args.department_id == 3

    def test_data_quality_run_all_subcommand(self):
        parser = build_parser()
        args = parser.parse_args(["data-quality", "run-all", "--format", "json"])
        assert args.format == "json"
        assert args.func is not None

    def test_data_quality_merge_staging_subcommand(self):
        parser = build_parser()
        args = parser.parse_args(["data-quality", "merge-staging", "--stg-id", "7"])
        assert args.stg_id == 7

    def test_missing_required_command_raises_system_exit(self):
        parser = build_parser()
        with pytest.raises(SystemExit):
            parser.parse_args([])

    def test_help_exits_cleanly(self):
        with pytest.raises(SystemExit) as exc_info:
            main(["--help"])
        assert exc_info.value.code == 0


class TestCheckConnectionCommand:
    def test_configuration_error_returns_exit_code_2(self):
        with patch("healthcare_app.cli.load_postgres_config", side_effect=ConfigurationError("missing POSTGRES_DB")):
            exit_code = cmd_check_connection(MagicMock())
        assert exit_code == 2

    def test_unreachable_database_returns_exit_code_1(self):
        fake_config = MagicMock(host="localhost", port=5432, dbname="healthcare_dms")
        with patch("healthcare_app.cli.load_postgres_config", return_value=fake_config), \
             patch("healthcare_app.cli.PostgresDatabase") as fake_db_cls:
            fake_db_cls.return_value.check_connectivity.return_value = False
            exit_code = cmd_check_connection(MagicMock())
        assert exit_code == 1

    def test_reachable_database_returns_exit_code_0(self):
        fake_config = MagicMock(host="localhost", port=5432, dbname="healthcare_dms")
        with patch("healthcare_app.cli.load_postgres_config", return_value=fake_config), \
             patch("healthcare_app.cli.PostgresDatabase") as fake_db_cls:
            fake_db_cls.return_value.check_connectivity.return_value = True
            exit_code = cmd_check_connection(MagicMock())
        assert exit_code == 0
