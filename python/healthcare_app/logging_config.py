"""Centralized logging setup.

Logs diagnostic information (host/port/dbname, report name, row counts,
timings, error text) but never credentials -- callers must not pass
PostgresConfig.password or raw connection strings containing a password
into any log call.
"""

from __future__ import annotations

import logging
import os
import sys


def configure_logging(level: str | None = None) -> None:
    """Configure the root `healthcare_app` logger once.

    Safe to call multiple times (idempotent) -- later calls update the level
    but do not duplicate handlers.
    """
    resolved_level = (level or os.environ.get("LOG_LEVEL") or "INFO").upper()

    logger = logging.getLogger("healthcare_app")
    logger.setLevel(resolved_level)

    if not logger.handlers:
        handler = logging.StreamHandler(stream=sys.stderr)
        handler.setFormatter(
            logging.Formatter("%(asctime)s %(levelname)-8s %(name)s: %(message)s")
        )
        logger.addHandler(handler)

    logger.propagate = False


def get_logger(name: str) -> logging.Logger:
    return logging.getLogger(f"healthcare_app.{name}")
