"""CSV export for report result sets (list[dict] -> CSV)."""

from __future__ import annotations

import csv
import io
from pathlib import Path

from healthcare_app.exceptions import ExportError


def rows_to_csv_string(rows: list[dict]) -> str:
    """Render rows as a CSV string. Returns a header-only ("") string shape
    is not special-cased: an empty `rows` list yields an empty string, since
    there are no column names to derive a header from.
    """
    if not rows:
        return ""

    buffer = io.StringIO()
    fieldnames = list(rows[0].keys())
    writer = csv.DictWriter(buffer, fieldnames=fieldnames)
    writer.writeheader()
    for row in rows:
        writer.writerow(row)
    return buffer.getvalue()


def export_rows_to_csv(rows: list[dict], output_path: str | Path) -> Path:
    """Write rows to a CSV file at output_path and return the resolved Path."""
    path = Path(output_path)
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(rows_to_csv_string(rows), encoding="utf-8", newline="")
    except OSError as exc:
        raise ExportError(f"Failed to write CSV to {path}: {exc}") from exc
    return path
