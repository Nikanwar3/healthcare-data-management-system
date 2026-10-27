"""JSON export for report result sets (list[dict] -> JSON)."""

from __future__ import annotations

import datetime
import decimal
import json
from pathlib import Path

from healthcare_app.exceptions import ExportError


def _json_default(value):
    """Handle the value types Oracle result sets commonly contain that
    `json.dumps` cannot serialize natively: dates/timestamps and Decimal.
    """
    if isinstance(value, (datetime.date, datetime.datetime)):
        return value.isoformat()
    if isinstance(value, decimal.Decimal):
        return float(value)
    raise TypeError(f"Object of type {type(value).__name__} is not JSON serializable")


def rows_to_json_string(rows: list[dict], indent: int | None = 2) -> str:
    return json.dumps(rows, default=_json_default, indent=indent)


def export_rows_to_json(rows: list[dict], output_path: str | Path, indent: int | None = 2) -> Path:
    path = Path(output_path)
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(rows_to_json_string(rows, indent=indent), encoding="utf-8")
    except OSError as exc:
        raise ExportError(f"Failed to write JSON to {path}: {exc}") from exc
    return path
