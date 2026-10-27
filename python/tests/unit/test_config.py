from healthcare_app.config import load_postgres_config
from healthcare_app.exceptions import ConfigurationError

import pytest


def test_loads_required_fields():
    cfg = load_postgres_config({"POSTGRES_HOST": "h", "POSTGRES_DB": "d", "POSTGRES_USER": "u"})
    assert cfg.host == "h"
    assert cfg.dbname == "d"
    assert cfg.user == "u"
    assert cfg.password == ""
    assert cfg.port == 5432


def test_missing_required_var_raises():
    with pytest.raises(ConfigurationError, match="POSTGRES_DB"):
        load_postgres_config({"POSTGRES_HOST": "h", "POSTGRES_USER": "u"})


def test_invalid_port_raises():
    with pytest.raises(ConfigurationError, match="POSTGRES_PORT"):
        load_postgres_config(
            {"POSTGRES_HOST": "h", "POSTGRES_DB": "d", "POSTGRES_USER": "u", "POSTGRES_PORT": "not-a-number"}
        )


def test_repr_redacts_password():
    cfg = load_postgres_config(
        {"POSTGRES_HOST": "h", "POSTGRES_DB": "d", "POSTGRES_USER": "u", "POSTGRES_PASSWORD": "secret123"}
    )
    assert "secret123" not in repr(cfg)
    assert "<redacted>" in repr(cfg)
