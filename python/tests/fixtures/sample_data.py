"""Synthetic, hand-authored fixture rows shaped like real PKG_CLINICAL_REPORTING /
PKG_DATA_QUALITY result sets, so unit tests can exercise application logic
without any Oracle instance. Values are chosen to make the expected
calculation results easy to verify by hand.
"""

from datetime import date


def monthly_summary_rows() -> list[dict]:
    return [
        {
            "month_start": date(2025, 1, 1),
            "total_appointments": 100,
            "completed": 70,
            "cancelled": 20,
            "no_show": 5,
            "still_scheduled": 5,
        },
        {
            "month_start": date(2025, 2, 1),
            "total_appointments": 50,
            "completed": 30,
            "cancelled": 10,
            "no_show": 5,
            "still_scheduled": 5,
        },
    ]


def department_workload_rows() -> list[dict]:
    return [
        {"department_id": 1, "department_name": "Cardiology", "total_appointments": 40, "distinct_patients_seen": 25, "completed_appointments": 30, "completion_rate_pct": 75.0},
        {"department_id": 2, "department_name": "Family Medicine", "total_appointments": 90, "distinct_patients_seen": 60, "completed_appointments": 60, "completion_rate_pct": 66.7},
        {"department_id": 3, "department_name": "Orthopedics", "total_appointments": 10, "distinct_patients_seen": 8, "completed_appointments": 7, "completion_rate_pct": 70.0},
    ]


def empty_rows() -> list[dict]:
    return []


def data_quality_findings() -> list[dict]:
    return [
        {
            "rule_name": "INCOMPLETE_LAB_ORDER",
            "severity": "ERROR",
            "entity_type": "LAB_ORDER",
            "entity_id": "501",
            "finding_description": "Order marked COMPLETED but has no result rows.",
            "recommended_action": "Enter the missing results or revert the status.",
        },
        {
            "rule_name": "DUPLICATE_DIAGNOSIS",
            "severity": "WARNING",
            "entity_type": "ENCOUNTER",
            "entity_id": "77",
            "finding_description": "Encounter has 2 PRIMARY diagnosis rows for ICD-10 I10.",
            "recommended_action": "Review the encounter and remove the duplicate entry.",
        },
        {
            "rule_name": "MISSING_CANCELLATION_REASON",
            "severity": "WARNING",
            "entity_type": "APPOINTMENT",
            "entity_id": "1203",
            "finding_description": "Cancelled appointment has no cancelled_reason recorded.",
            "recommended_action": "Follow up with scheduling staff.",
        },
    ]
