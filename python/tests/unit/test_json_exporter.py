import decimal
import json
from datetime import date, datetime

from healthcare_app.exporters.json_exporter import (
    export_rows_to_json,
    rows_to_json_string,
)


def test_empty_rows_produce_empty_json_array():
    assert json.loads(rows_to_json_string([])) == []


def test_round_trips_plain_values():
    rows = [{"a": 1, "b": "text", "c": None}]
    assert json.loads(rows_to_json_string(rows)) == rows


def test_serializes_date_and_datetime_as_iso_strings():
    rows = [{"d": date(2025, 3, 1), "ts": datetime(2025, 3, 1, 9, 30)}]
    parsed = json.loads(rows_to_json_string(rows))
    assert parsed[0]["d"] == "2025-03-01"
    assert parsed[0]["ts"] == "2025-03-01T09:30:00"


def test_serializes_decimal_as_float():
    rows = [{"rate": decimal.Decimal("66.7")}]
    parsed = json.loads(rows_to_json_string(rows))
    assert parsed[0]["rate"] == 66.7


def test_export_rows_to_json_writes_file(tmp_path):
    output_path = tmp_path / "out" / "findings.json"
    result_path = export_rows_to_json([{"x": 1}], output_path)
    assert result_path == output_path
    assert json.loads(output_path.read_text()) == [{"x": 1}]
