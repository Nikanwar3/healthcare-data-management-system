"""Command-line entry point.

    python -m healthcare_app.cli monthly-summary --start 2025-01-01 --end 2025-04-01
    python -m healthcare_app.cli data-quality run-all --format json --output findings.json

Every subcommand that needs the database loads configuration and connects
lazily, inside the command handler -- not at import time -- so `--help`
always works even with no .env configured, and a missing/invalid
configuration produces one clear error message instead of a stack trace.
"""

from __future__ import annotations

import argparse
import sys
from datetime import date, datetime

from healthcare_app.calculations import summarize_monthly_rows
from healthcare_app.config import load_postgres_config
from healthcare_app.db.connection import PostgresDatabase
from healthcare_app.exceptions import HealthcareAppError
from healthcare_app.exporters.csv_exporter import export_rows_to_csv, rows_to_csv_string
from healthcare_app.exporters.json_exporter import (
    export_rows_to_json,
    rows_to_json_string,
)
from healthcare_app.logging_config import configure_logging, get_logger
from healthcare_app.services.data_quality_service import DataQualityService
from healthcare_app.services.reporting_service import ReportingService

logger = get_logger("cli")


def _parse_date(value: str) -> date:
    try:
        return datetime.strptime(value, "%Y-%m-%d").date()
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"'{value}' is not a valid date (expected YYYY-MM-DD)") from exc


def _emit(rows: list[dict], fmt: str, output: str | None) -> None:
    if fmt == "json":
        text = rows_to_json_string(rows)
        if output:
            export_rows_to_json(rows, output)
        else:
            print(text)
    else:
        text = rows_to_csv_string(rows)
        if output:
            export_rows_to_csv(rows, output)
        else:
            print(text)

    if output:
        print(f"Wrote {len(rows)} row(s) to {output}", file=sys.stderr)


def _connect() -> PostgresDatabase:
    config = load_postgres_config()
    db = PostgresDatabase(config)
    if not db.check_connectivity():
        raise HealthcareAppError(
            f"Could not reach PostgreSQL at {config.host}:{config.port}/{config.dbname}. "
            "Check POSTGRES_HOST/POSTGRES_PORT/POSTGRES_DB/POSTGRES_USER/POSTGRES_PASSWORD "
            "and that the database is running and reachable."
        )
    return db


def cmd_monthly_summary(args: argparse.Namespace) -> int:
    db = _connect()
    service = ReportingService(db)
    rows = service.monthly_appointment_summary(args.start, args.end)
    _emit(rows, args.format, args.output)
    if not args.output:
        totals = summarize_monthly_rows(rows)
        print(
            f"\nTotals: {totals['total_appointments']} appointments across "
            f"{totals['months_covered']} month(s), "
            f"{totals['completion_rate_pct']}% completed, "
            f"{totals['cancellation_rate_pct']}% cancelled.",
            file=sys.stderr,
        )
    return 0


def cmd_department_workload(args: argparse.Namespace) -> int:
    db = _connect()
    service = ReportingService(db)
    rows = service.department_workload_summary(args.start, args.end, args.department_id)
    _emit(rows, args.format, args.output)
    return 0


def cmd_provider_workload(args: argparse.Namespace) -> int:
    db = _connect()
    service = ReportingService(db)
    rows = service.provider_workload_summary(args.start, args.end, args.provider_id)
    _emit(rows, args.format, args.output)
    return 0


def cmd_cancellation_analysis(args: argparse.Namespace) -> int:
    db = _connect()
    service = ReportingService(db)
    rows = service.cancellation_analysis(args.start, args.end)
    _emit(rows, args.format, args.output)
    return 0


def cmd_data_quality_run_all(args: argparse.Namespace) -> int:
    db = _connect()
    service = DataQualityService(db)
    rows = service.run_all_checks()
    _emit(rows, args.format, args.output)
    errors = sum(1 for r in rows if r.get("severity") == "ERROR")
    warnings = sum(1 for r in rows if r.get("severity") == "WARNING")
    print(f"\n{errors} ERROR finding(s), {warnings} WARNING finding(s).", file=sys.stderr)
    return 1 if errors else 0


def cmd_data_quality_validate_staging(args: argparse.Namespace) -> int:
    db = _connect()
    service = DataQualityService(db)
    rows = service.validate_staging_appointments(args.stg_id)
    _emit(rows, args.format, args.output)
    return 1 if rows else 0


def cmd_data_quality_merge_staging(args: argparse.Namespace) -> int:
    db = _connect()
    service = DataQualityService(db)
    service.merge_staging_appointment(args.stg_id)
    print(f"Merged stg_id {args.stg_id} into appointments.", file=sys.stderr)
    return 0


def cmd_check_connection(args: argparse.Namespace) -> int:
    try:
        config = load_postgres_config()
    except HealthcareAppError as exc:
        print(f"Configuration error: {exc}", file=sys.stderr)
        return 2

    db = PostgresDatabase(config)
    if db.check_connectivity():
        print(f"OK: connected to PostgreSQL at {config.host}:{config.port}/{config.dbname}")
        return 0
    print(
        f"FAILED: could not reach PostgreSQL at {config.host}:{config.port}/{config.dbname}. "
        "Check that the database is running and POSTGRES_* env vars are correct.",
        file=sys.stderr,
    )
    return 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="healthcare_app",
        description="Healthcare Data Management and Clinical Reporting System CLI",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    def add_common_report_args(p: argparse.ArgumentParser) -> None:
        p.add_argument("--start", type=_parse_date, required=True, help="Start date, YYYY-MM-DD (inclusive)")
        p.add_argument("--end", type=_parse_date, required=True, help="End date, YYYY-MM-DD (exclusive)")
        p.add_argument("--format", choices=["csv", "json"], default="csv")
        p.add_argument("--output", help="File path to write to; prints to stdout if omitted")

    p_monthly = sub.add_parser("monthly-summary", help="Monthly appointment summary")
    add_common_report_args(p_monthly)
    p_monthly.set_defaults(func=cmd_monthly_summary)

    p_dept = sub.add_parser("department-workload", help="Department-wise workload summary")
    add_common_report_args(p_dept)
    p_dept.add_argument("--department-id", type=int, default=None)
    p_dept.set_defaults(func=cmd_department_workload)

    p_prov = sub.add_parser("provider-workload", help="Provider workload summary")
    add_common_report_args(p_prov)
    p_prov.add_argument("--provider-id", type=int, default=None)
    p_prov.set_defaults(func=cmd_provider_workload)

    p_cancel = sub.add_parser("cancellation-analysis", help="Appointment cancellation analysis")
    add_common_report_args(p_cancel)
    p_cancel.set_defaults(func=cmd_cancellation_analysis)

    p_dq = sub.add_parser("data-quality", help="Data-quality checks")
    dq_sub = p_dq.add_subparsers(dest="dq_command", required=True)

    p_dq_all = dq_sub.add_parser("run-all", help="Run every in-table data-quality check")
    p_dq_all.add_argument("--format", choices=["csv", "json"], default="csv")
    p_dq_all.add_argument("--output")
    p_dq_all.set_defaults(func=cmd_data_quality_run_all)

    p_dq_stg = dq_sub.add_parser("validate-staging", help="Validate the raw appointment staging feed")
    p_dq_stg.add_argument("--stg-id", type=int, default=None, dest="stg_id")
    p_dq_stg.add_argument("--format", choices=["csv", "json"], default="csv")
    p_dq_stg.add_argument("--output")
    p_dq_stg.set_defaults(func=cmd_data_quality_validate_staging)

    p_dq_merge = dq_sub.add_parser("merge-staging", help="Validate and merge one staging row into appointments")
    p_dq_merge.add_argument("--stg-id", type=int, required=True, dest="stg_id")
    p_dq_merge.set_defaults(func=cmd_data_quality_merge_staging)

    p_check = sub.add_parser("check-connection", help="Verify PostgreSQL connectivity and exit")
    p_check.set_defaults(func=cmd_check_connection)

    return parser


def main(argv: list[str] | None = None) -> int:
    configure_logging()
    parser = build_parser()
    args = parser.parse_args(argv)

    try:
        return args.func(args)
    except HealthcareAppError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
