"""Session-scoped fixtures for the PostgreSQL integration test suite.

Unlike the Oracle version of this project (which could only ever document
these tests, since no Oracle instance was available), these tests actually
run: the `pg_test_db` fixture below builds a completely disposable database
from this project's own sql/ and plpgsql/ files, runs the tests against it,
and drops it afterward. Nothing here touches the `healthcare_dms` database
used for interactive development.
"""

from __future__ import annotations

import os
from pathlib import Path

import psycopg2
import psycopg2.extensions
import pytest

from healthcare_app.config import PostgresConfig
from healthcare_app.db.connection import PostgresDatabase

_PROJECT_ROOT = Path(__file__).resolve().parents[3]

_SETUP_FILES = [
    "sql/01_schema/01_create_tables.sql",
    "sql/01_schema/02_create_indexes.sql",
    "sql/01_schema/03_create_staging.sql",
    "plpgsql/packages/00_types.sql",
    "plpgsql/packages/pkg_clinical_reporting.sql",
    "plpgsql/packages/pkg_data_quality.sql",
    "plpgsql/views/01_create_views.sql",
    "sql/02_data/01_seed_departments_providers.sql",
    "sql/02_data/02_seed_patients.sql",
    "sql/02_data/03_seed_appointments_encounters.sql",
    "sql/02_data/04_seed_diagnoses_labs.sql",
    "sql/02_data/05_seed_dirty_data_demo.sql",
]


def _connection_kwargs() -> dict:
    return {
        "host": os.environ.get("POSTGRES_HOST", "localhost"),
        "port": int(os.environ.get("POSTGRES_PORT", "5432")),
        "user": os.environ.get("POSTGRES_USER", ""),
        "password": os.environ.get("POSTGRES_PASSWORD", ""),
    }


def _postgres_reachable() -> bool:
    if not os.environ.get("POSTGRES_HOST") or not os.environ.get("POSTGRES_USER"):
        return False
    try:
        conn = psycopg2.connect(dbname="postgres", **_connection_kwargs())
        conn.close()
        return True
    except psycopg2.Error:
        return False


skip_reason = (
    "Set POSTGRES_HOST and POSTGRES_USER to a reachable PostgreSQL server to run these "
    "(a disposable test database is created and dropped automatically). See "
    "tests/integration/README.md."
)


@pytest.fixture(scope="session")
def pg_test_db():
    if not _postgres_reachable():
        pytest.skip(skip_reason)

    test_db_name = os.environ.get("POSTGRES_TEST_DB", "healthcare_dms_test")
    admin_conn = psycopg2.connect(dbname="postgres", **_connection_kwargs())
    admin_conn.set_isolation_level(psycopg2.extensions.ISOLATION_LEVEL_AUTOCOMMIT)
    with admin_conn.cursor() as cur:
        cur.execute(
            "SELECT pg_terminate_backend(pid) FROM pg_stat_activity "
            "WHERE datname = %s AND pid <> pg_backend_pid()",
            (test_db_name,),
        )
        cur.execute(f'DROP DATABASE IF EXISTS "{test_db_name}"')
        cur.execute(f'CREATE DATABASE "{test_db_name}"')
    admin_conn.close()

    setup_conn = psycopg2.connect(dbname=test_db_name, **_connection_kwargs())
    setup_conn.autocommit = True
    with setup_conn.cursor() as cur:
        for relative_path in _SETUP_FILES:
            sql_text = (_PROJECT_ROOT / relative_path).read_text()
            cur.execute(sql_text)
    setup_conn.close()

    config = PostgresConfig(
        host=_connection_kwargs()["host"],
        port=_connection_kwargs()["port"],
        dbname=test_db_name,
        user=_connection_kwargs()["user"],
        password=_connection_kwargs()["password"],
    )
    database = PostgresDatabase(config)
    yield database
    database.close()

    admin_conn = psycopg2.connect(dbname="postgres", **_connection_kwargs())
    admin_conn.set_isolation_level(psycopg2.extensions.ISOLATION_LEVEL_AUTOCOMMIT)
    with admin_conn.cursor() as cur:
        cur.execute(
            "SELECT pg_terminate_backend(pid) FROM pg_stat_activity "
            "WHERE datname = %s AND pid <> pg_backend_pid()",
            (test_db_name,),
        )
        cur.execute(f'DROP DATABASE IF EXISTS "{test_db_name}"')
    admin_conn.close()
