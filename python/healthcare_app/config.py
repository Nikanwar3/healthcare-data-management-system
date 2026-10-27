"""Configuration loaded from environment variables.

Never hardcode credentials here. See .env.example at the project root for the
full list of supported variables and placeholder values.
"""

from __future__ import annotations

import os
from dataclasses import dataclass

from healthcare_app.exceptions import ConfigurationError

_REQUIRED_VARS = ("POSTGRES_HOST", "POSTGRES_DB", "POSTGRES_USER")


@dataclass(frozen=True)
class PostgresConfig:
    """Connection settings for PostgreSQL.

    `password` is intentionally excluded from the printed representation via
    the `__repr__` override below -- the default dataclass repr would
    otherwise print it.
    """

    host: str
    dbname: str
    user: str
    password: str = ""
    port: int = 5432
    pool_min: int = 1
    pool_max: int = 5

    def __repr__(self) -> str:  # pragma: no cover - trivial
        return (
            f"PostgresConfig(host={self.host!r}, port={self.port}, "
            f"dbname={self.dbname!r}, user={self.user!r}, password=<redacted>)"
        )


def load_postgres_config(env: dict | None = None) -> PostgresConfig:
    """Build a PostgresConfig from environment variables.

    Args:
        env: mapping to read from; defaults to `os.environ`. Accepting an
            explicit mapping makes this function trivially unit-testable
            without mutating the real process environment.

    Raises:
        ConfigurationError: if any required variable is missing or blank,
            or if a numeric override variable is not a valid integer.

    Note: POSTGRES_PASSWORD is deliberately not in `_REQUIRED_VARS` -- local
    development Postgres instances are commonly configured with trust/peer
    authentication (no password), which this project's own local setup uses.
    A real deployment with password authentication would set it; this
    function accepts an empty string and lets the server reject the
    connection with its own authentication error if that's wrong.
    """
    source = env if env is not None else os.environ

    missing = [name for name in _REQUIRED_VARS if not source.get(name)]
    if missing:
        raise ConfigurationError(
            "Missing required environment variable(s): "
            f"{', '.join(missing)}. See .env.example for the full list."
        )

    def _read_int(name: str, default: int) -> int:
        raw = source.get(name)
        if raw is None or raw == "":
            return default
        try:
            return int(raw)
        except ValueError as exc:
            raise ConfigurationError(f"{name} must be an integer, got {raw!r}.") from exc

    return PostgresConfig(
        host=source["POSTGRES_HOST"],
        dbname=source["POSTGRES_DB"],
        user=source["POSTGRES_USER"],
        password=source.get("POSTGRES_PASSWORD", ""),
        port=_read_int("POSTGRES_PORT", 5432),
        pool_min=_read_int("POSTGRES_POOL_MIN", 1),
        pool_max=_read_int("POSTGRES_POOL_MAX", 5),
    )
