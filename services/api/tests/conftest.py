import os

import pytest
from fastapi.testclient import TestClient


@pytest.fixture
def client(monkeypatch):
    """Client for tests that never touch the database.

    create_engine() does not open a connection, so importing the app without a
    live Postgres is safe; only the startup schema creation needs stubbing.
    """
    import main

    monkeypatch.setattr(main, "_init_schema", lambda: None)
    with TestClient(main.app) as test_client:
        yield test_client


@pytest.fixture(scope="session")
def database_available() -> bool:
    import db

    try:
        db.ping()
    except Exception:  # any driver or network error means "no database here"
        return False
    return True


@pytest.fixture
def db_client(database_available):
    """Client backed by a real Postgres. Skips when one is not configured.

    CI always provides one via a postgres service container; a laptop without
    Docker simply skips these rather than failing the suite.
    """
    if not database_available:
        pytest.skip(
            "no reachable PostgreSQL "
            f"(DB_HOST={os.getenv('DB_HOST', 'localhost')}); "
            "start one with `make db-up`"
        )
    import main

    with TestClient(main.app) as test_client:
        yield test_client
