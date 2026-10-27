from datetime import date

from healthcare_app.exporters.csv_exporter import export_rows_to_csv, rows_to_csv_string


def test_empty_rows_produce_empty_string():
    assert rows_to_csv_string([]) == ""


def test_header_matches_first_row_keys():
    rows = [{"a": 1, "b": 2}, {"a": 3, "b": 4}]
    text = rows_to_csv_string(rows)
    lines = text.strip().splitlines()
    assert lines[0] == "a,b"
    assert lines[1] == "1,2"
    assert lines[2] == "3,4"


def test_handles_none_and_date_values():
    rows = [{"name": "Test", "value": None, "when": date(2025, 1, 15)}]
    text = rows_to_csv_string(rows)
    assert "Test" in text
    assert "2025-01-15" in text


def test_export_rows_to_csv_writes_file(tmp_path):
    rows = [{"col": "value"}]
    output_path = tmp_path / "subdir" / "report.csv"
    result_path = export_rows_to_csv(rows, output_path)
    assert result_path == output_path
    assert output_path.exists()
    assert "col" in output_path.read_text()


def test_export_rows_to_csv_creates_parent_directories(tmp_path):
    output_path = tmp_path / "a" / "b" / "c" / "report.csv"
    export_rows_to_csv([{"x": 1}], output_path)
    assert output_path.exists()
