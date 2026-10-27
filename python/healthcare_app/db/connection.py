"""PostgreSQL connectivity using psycopg2.

This module is the only place in the application that imports psycopg2 and
the only place that knows how to call a `pkg_*` schema function/procedure.
Every other module talks to the `PostgresDatabase` class defined here, not to
the driver directly.
"""

from __future__ import annotations

import contextlib
from collections.abc import Iterator, Sequence
from typing import Any

import psycopg2
import psycopg2.extras
import psycopg2.pool

from healthcare_app.config import PostgresConfig
from healthcare_app.exceptions import (
    DatabaseConnectionError,
    DataQualityGateError,
    InvalidDateRangeError,
    InvalidIdentifierError,
    ReportExecutionError,
)
from healthcare_app.logging_config import get_logger

logger = get_logger("db.connection")

# Custom SQLSTATE codes raised by pkg_clinical_reporting / pkg_data_quality
# via RAISE EXCEPTION ... USING ERRCODE -- see plpgsql/packages/
# pkg_clinical_reporting.sql and pkg_data_quality.sql for the authoritative
# definitions.
_SQLSTATE_INVALID_DATE_RANGE = "HC001"
_SQLSTATE_INVALID_IDENTIFIER = "HC002"
_SQLSTATE_DATA_QUALITY_GATE = "HC003"


def _translate_postgres_error(exc: psycopg2.Error) -> Exception:
    """Map a raw psycopg2.Error onto a domain exception.

    psycopg2 exposes the server-provided SQLSTATE as `exc.pgcode` and the
    primary error message as `exc.diag.message_primary` (falling back to
    str(exc) if diagnostics are unavailable, e.g. for client-side errors that
    never reached the server). We deliberately do not include the connection
    string or any bind values in the translated message -- only the
    DB-provided error text.
    """
    code = getattr(exc, "pgcode", None)
    diag = getattr(exc, "diag", None)
    message = getattr(diag, "message_primary", None) or str(exc).strip()

    if code == _SQLSTATE_INVALID_DATE_RANGE:
        return InvalidDateRangeError(message)
    if code == _SQLSTATE_INVALID_IDENTIFIER:
        return InvalidIdentifierError(message)
    if code == _SQLSTATE_DATA_QUALITY_GATE:
        return DataQualityGateError(message)
    return ReportExecutionError(message)


def _placeholders(params: Sequence[Any]) -> str:
    return ", ".join(["%s"] * len(params))


class PostgresDatabase:
    """Thin wrapper around a psycopg2 connection pool.

    Connections are used in autocommit mode: every call in this project is
    either a read-only reporting function or a single self-contained
    PROCEDURE call (merge_staging_appointment) that must succeed or fail as
    one unit -- there is no multi-statement client-side transaction to
    coordinate, so autocommit keeps the pool-checkout/release pattern simple
    and avoids leaving a connection "idle in transaction" if a caller forgets
    to commit.
    """

    def __init__(self, config: PostgresConfig):
        self._config = config
        self._pool: psycopg2.pool.SimpleConnectionPool | None = None

    def _get_pool(self) -> psycopg2.pool.SimpleConnectionPool:
        if self._pool is None:
            try:
                self._pool = psycopg2.pool.SimpleConnectionPool(
                    self._config.pool_min,
                    self._config.pool_max,
                    host=self._config.host,
                    port=self._config.port,
                    dbname=self._config.dbname,
                    user=self._config.user,
                    password=self._config.password,
                )
                logger.info(
                    "Created PostgreSQL connection pool for host=%s port=%s dbname=%s",
                    self._config.host, self._config.port, self._config.dbname,
                )
            except psycopg2.Error as exc:
                logger.error("Failed to create PostgreSQL connection pool: %s", exc)
                raise DatabaseConnectionError(
                    f"Could not connect to PostgreSQL at "
                    f"{self._config.host}:{self._config.port}/{self._config.dbname}: {exc}"
                ) from exc
        return self._pool

    @contextlib.contextmanager
    def connection(self) -> Iterator[psycopg2.extensions.connection]:
        """Yield a pooled, autocommit connection, always returning it to the pool."""
        pool = self._get_pool()
        conn = pool.getconn()
        conn.autocommit = True
        try:
            yield conn
        finally:
            pool.putconn(conn)

    def close(self) -> None:
        if self._pool is not None:
            self._pool.closeall()
            self._pool = None

    # -- Generic call helpers ------------------------------------------------

    def call_function(self, function_name: str, params: Sequence[Any] = ()) -> list[dict[str, Any]]:
        """Run `SELECT * FROM schema.function(...)` for a RETURNS TABLE /
        RETURNS SETOF function and return its rows as a list of dicts.

        `function_name` must be a fixed, fully-qualified name written in
        application code (e.g. "pkg_clinical_reporting.monthly_appointment_
        summary") -- never built from user input, since it is interpolated
        into the SQL string directly (only `params` go through the driver's
        parameter binding).
        """
        sql = f"SELECT * FROM {function_name}({_placeholders(params)})"
        with self.connection() as conn:
            with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cursor:
                try:
                    cursor.execute(sql, tuple(params))
                    return [dict(row) for row in cursor.fetchall()]
                except psycopg2.Error as exc:
                    logger.warning("Function call failed (%s): %s", function_name, exc)
                    raise _translate_postgres_error(exc) from exc

    def call_procedure(self, procedure_name: str, params: Sequence[Any] = ()) -> None:
        """Run `CALL schema.procedure(...)` for a stored PROCEDURE that
        performs DML (e.g. pkg_data_quality.merge_staging_appointment).

        Same fixed-name-vs-bound-params rule as call_function() applies here.
        """
        sql = f"CALL {procedure_name}({_placeholders(params)})"
        with self.connection() as conn:
            with conn.cursor() as cursor:
                try:
                    cursor.execute(sql, tuple(params))
                except psycopg2.Error as exc:
                    logger.warning("Procedure call failed (%s): %s", procedure_name, exc)
                    raise _translate_postgres_error(exc) from exc

    def execute_query(self, sql: str, params: Sequence[Any] = ()) -> list[dict[str, Any]]:
        """Run a parameterized SELECT and return rows as a list of dicts."""
        with self.connection() as conn:
            with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cursor:
                try:
                    cursor.execute(sql, tuple(params))
                    return [dict(row) for row in cursor.fetchall()]
                except psycopg2.Error as exc:
                    logger.warning("Query failed: %s", exc)
                    raise _translate_postgres_error(exc) from exc

    def check_connectivity(self) -> bool:
        """Lightweight `SELECT 1` health check."""
        try:
            with self.connection() as conn:
                with conn.cursor() as cursor:
                    cursor.execute("SELECT 1")
                    return cursor.fetchone() == (1,)
        except (psycopg2.Error, DatabaseConnectionError) as exc:
            logger.error("Connectivity check failed: %s", exc)
            return False
