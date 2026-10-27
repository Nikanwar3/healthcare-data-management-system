"""Pure, dependency-free calculation helpers.

pkg_clinical_reporting already computes rates inside the database (see
plpgsql/packages/pkg_clinical_reporting.sql). These functions exist for two
reasons: (1) so client-side code that reshapes a report for export can
recompute a derived figure without a second round trip to the database, and
(2) so that calculation logic has a Python-testable home that does not
require a database instance at all -- see python/tests/unit/test_calculations.py.

Every function here is a pure function: no I/O, no hidden state, safe to
call with synthetic fixtures.
"""

from __future__ import annotations


def safe_rate(numerator: float, denominator: float, decimals: int = 1) -> float:
    """Percentage of numerator/denominator, or 0.0 if denominator is 0.

    Mirrors the NULLIF(..., 0) guard used in the SQL/PL-SQL versions of this
    calculation, but returns 0.0 instead of NULL/None, since the Python
    layer never needs a "no data" sentinel for a rate used in export rows.
    """
    if denominator == 0:
        return 0.0
    return round(100 * numerator / denominator, decimals)


def completion_rate(total: float, completed: float) -> float:
    return safe_rate(completed, total)


def cancellation_rate(total: float, cancelled: float) -> float:
    return safe_rate(cancelled, total)


def summarize_monthly_rows(rows: list[dict]) -> dict:
    """Roll a list of monthly-summary rows (as produced by
    pkg_clinical_reporting.monthly_appointment_summary) up into one grand
    total row plus an overall completion rate.

    Expects each row to have: total_appointments, completed, cancelled,
    no_show, still_scheduled. Missing keys are treated as 0.
    """
    totals: dict[str, int | float] = {
        "total_appointments": 0, "completed": 0, "cancelled": 0, "no_show": 0, "still_scheduled": 0,
    }
    for row in rows:
        for key in totals:
            totals[key] += row.get(key, 0) or 0

    totals["completion_rate_pct"] = completion_rate(totals["total_appointments"], totals["completed"])
    totals["cancellation_rate_pct"] = cancellation_rate(totals["total_appointments"], totals["cancelled"])
    totals["months_covered"] = len(rows)
    return totals


def summarize_by_department(rows: list[dict]) -> list[dict]:
    """Sort department workload rows by total_appointments descending and
    attach a rank (1-based) -- used when the DB-side ORDER BY needs to be
    re-applied after rows have been merged with another source (e.g. a CSV
    of head-count targets) in application code.
    """
    sorted_rows = sorted(rows, key=lambda r: r.get("total_appointments", 0), reverse=True)
    for index, row in enumerate(sorted_rows, start=1):
        row["rank"] = index
    return sorted_rows


def classify_findings_by_severity(findings: list[dict]) -> dict:
    """Split data-quality findings into errors vs. warnings and count each.

    Raises ValueError on an unrecognized severity value, rather than
    silently dropping it -- an unexpected severity string is itself a bug
    worth surfacing loudly.
    """
    result: dict[str, list[dict]] = {"ERROR": [], "WARNING": []}
    for finding in findings:
        severity = finding.get("severity")
        if severity not in result:
            raise ValueError(f"Unrecognized data-quality severity: {severity!r}")
        result[severity].append(finding)

    return {
        "errors": result["ERROR"],
        "warnings": result["WARNING"],
        "error_count": len(result["ERROR"]),
        "warning_count": len(result["WARNING"]),
        "blocks_merge": len(result["ERROR"]) > 0,
    }
