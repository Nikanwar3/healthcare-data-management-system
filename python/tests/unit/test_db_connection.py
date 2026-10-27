"""Unit tests for healthcare_app.db.connection.

These tests mock psycopg2's connection/cursor/pool objects entirely -- no
PostgreSQL instance is contacted. They verify: (1) SQLSTATE translation from
raw custom error codes to this application's domain exceptions, (2) that the
PostgresDatabase call helpers build the SQL/params the way pkg_clinical_
reporting / pkg_data_quality expect, and (3) that pooled connections are
always returned to the pool, even on error.
"""

from unittest.mock import MagicMock, patch

import psycopg2
import pytest

from healthcare_app.config import PostgresConfig
from healthcare_app.db.connection import PostgresDatabase, _translate_postgres_error
from healthcare_app.exceptions import (
    DatabaseConnectionError,
    DataQualityGateError,
    InvalidDateRangeError,
    InvalidIdentifierError,
    ReportExecutionError,
)


class _FakeDBError(psycopg2.Error):
    """Stand-in for a real psycopg2.Error with a server-assigned SQLSTATE.

    Real psycopg2.Error instances expose `.pgcode` as a read-only C-level
    attribute populated from an actual server response -- it cannot be set
    via plain assignment, even on a subclass instance. Shadowing it as a
    property on this subclass works around that so error translation can be
    unit-tested without a live database, while `isinstance(exc, psycopg2.
    Error)` -- what connection.py's `except` clause checks -- still holds.
    """

    def __init__(self, pgcode: str, message: str):
        super().__init__(message)
        self._pgcode = pgcode
        self._diag = MagicMock(message_primary=message)

    @property
    def pgcode(self):
        return self._pgcode

    @property
    def diag(self):
        return self._diag


def _fake_db_error(pgcode: str, message: str) -> psycopg2.Error:
    return _FakeDBError(pgcode, message)


class TestTranslatePostgresError:
    def test_maps_hc001_to_invalid_date_range(self):
        result = _translate_postgres_error(_fake_db_error("HC001", "bad range"))
        assert isinstance(result, InvalidDateRangeError)
        assert "bad range" in str(result)

    def test_maps_hc002_to_invalid_identifier(self):
        result = _translate_postgres_error(_fake_db_error("HC002", "no such id"))
        assert isinstance(result, InvalidIdentifierError)

    def test_maps_hc003_to_data_quality_gate_error(self):
        result = _translate_postgres_error(_fake_db_error("HC003", "failed checks"))
        assert isinstance(result, DataQualityGateError)

    def test_unknown_code_maps_to_report_execution_error(self):
        result = _translate_postgres_error(_fake_db_error("42P01", "relation does not exist"))
        assert isinstance(result, ReportExecutionError)


@pytest.fixture
def config():
    return PostgresConfig(host="localhost", dbname="healthcare_dms", user="u")


class TestPostgresDatabaseCallHelpers:
    def test_call_function_builds_correct_sql_and_returns_rows(self, config):
        db = PostgresDatabase(config)

        fake_cursor = MagicMock()
        fake_cursor.fetchall.return_value = [{"total": 5}]
        fake_cursor.__enter__.return_value = fake_cursor
        fake_cursor.__exit__.return_value = False

        fake_conn = MagicMock()
        fake_conn.cursor.return_value = fake_cursor

        fake_pool = MagicMock()
        fake_pool.getconn.return_value = fake_conn

        with patch.object(PostgresDatabase, "_get_pool", return_value=fake_pool):
            rows = db.call_function(
                "pkg_clinical_reporting.monthly_appointment_summary",
                ("2025-01-01", "2025-02-01"),
            )

        assert rows == [{"total": 5}]
        executed_sql, executed_params = fake_cursor.execute.call_args[0]
        assert executed_sql == "SELECT * FROM pkg_clinical_reporting.monthly_appointment_summary(%s, %s)"
        assert executed_params == ("2025-01-01", "2025-02-01")
        fake_pool.putconn.assert_called_once_with(fake_conn)

    def test_call_function_translates_database_error(self, config):
        db = PostgresDatabase(config)

        fake_cursor = MagicMock()
        fake_cursor.execute.side_effect = _fake_db_error("HC001", "start after end")
        fake_cursor.__enter__.return_value = fake_cursor
        fake_cursor.__exit__.return_value = False

        fake_conn = MagicMock()
        fake_conn.cursor.return_value = fake_cursor

        fake_pool = MagicMock()
        fake_pool.getconn.return_value = fake_conn

        with patch.object(PostgresDatabase, "_get_pool", return_value=fake_pool), \
             pytest.raises(InvalidDateRangeError):
            db.call_function("pkg_clinical_reporting.monthly_appointment_summary", ())

        # Connection must still be released back to the pool even on error.
        fake_pool.putconn.assert_called_once_with(fake_conn)

    def test_call_procedure_builds_call_statement(self, config):
        db = PostgresDatabase(config)

        fake_cursor = MagicMock()
        fake_cursor.__enter__.return_value = fake_cursor
        fake_cursor.__exit__.return_value = False

        fake_conn = MagicMock()
        fake_conn.cursor.return_value = fake_cursor

        fake_pool = MagicMock()
        fake_pool.getconn.return_value = fake_conn

        with patch.object(PostgresDatabase, "_get_pool", return_value=fake_pool):
            db.call_procedure("pkg_data_quality.merge_staging_appointment", (5,))

        executed_sql, executed_params = fake_cursor.execute.call_args[0]
        assert executed_sql == "CALL pkg_data_quality.merge_staging_appointment(%s)"
        assert executed_params == (5,)

    def test_get_pool_failure_raises_database_connection_error(self, config):
        db = PostgresDatabase(config)
        with patch("psycopg2.pool.SimpleConnectionPool", side_effect=psycopg2.Error("no listener")), \
             pytest.raises(DatabaseConnectionError):
            db._get_pool()

    def test_check_connectivity_returns_false_when_pool_creation_fails(self, config):
        db = PostgresDatabase(config)
        with patch("psycopg2.pool.SimpleConnectionPool", side_effect=psycopg2.Error("no listener")):
            assert db.check_connectivity() is False
