"""Unit tests: no database, no network."""

import json
import logging

import pytest

from logconf import JsonFormatter
from settings import Settings


class TestDatabaseUrl:
    def test_builds_a_postgres_dsn(self):
        s = Settings(
            db_user="appuser",
            db_password="simple",
            db_host="db",
            db_port=5432,
            db_name="appdb",
            db_sslmode="require",
        )
        assert s.database_url == (
            "postgresql+psycopg://appuser:simple@db:5432/appdb?sslmode=require"
        )

    def test_tls_is_requested_by_default(self, monkeypatch):
        """RDS is configured with rds.force_ssl = 1. Defaulting to libpq's
        "prefer" would silently allow plaintext wherever a server permits it.

        The environment is cleared first: a test that asserts on a default while
        reading ambient configuration is not testing the default. CI exports
        DB_SSLMODE=disable for its throwaway PostgreSQL, and without this the
        test passes locally and fails there.
        """
        monkeypatch.delenv("DB_SSLMODE", raising=False)
        assert Settings().db_sslmode == "require"
        assert "sslmode=require" in Settings().database_url

    @pytest.mark.parametrize(
        "password,encoded",
        [
            ("p@ss/word", "p%40ss%2Fword"),
            ("a:b#c", "a%3Ab%23c"),
            ("100%sure", "100%25sure"),
        ],
    )
    def test_special_characters_are_percent_encoded(self, password, encoded):
        """RDS-generated passwords contain these characters. Without quoting the
        DSN silently parses into the wrong host and the app fails to connect."""
        s = Settings(db_password=password)
        assert encoded in s.database_url
        assert s.database_url.count("@") == 1

    def test_password_is_not_repr_leaked(self):
        """Pydantic repr ends up in tracebacks and logs; the password must not."""
        assert "hunter2" not in repr(Settings(db_password="hunter2"))


class TestJsonFormatter:
    def _emit(self, record) -> dict:
        return json.loads(JsonFormatter("svc", "test").format(record))

    def test_emits_the_fields_the_cloudwatch_metric_filter_matches_on(self):
        record = logging.LogRecord("app", logging.ERROR, __file__, 1, "boom", (), None)
        out = self._emit(record)
        assert out["level"] == "ERROR"
        assert out["message"] == "boom"
        assert out["service"] == "svc"
        assert out["env"] == "test"
        assert "timestamp" in out

    def test_extra_fields_ride_along(self):
        record = logging.LogRecord("app", logging.INFO, __file__, 1, "hi", (), None)
        record.item_id = 42
        assert self._emit(record)["item_id"] == 42

    def test_output_is_a_single_json_line(self):
        """CloudWatch splits on newlines; a multi-line record breaks the filter."""
        record = logging.LogRecord("app", logging.INFO, __file__, 1, "a\nb", (), None)
        line = JsonFormatter("svc", "test").format(record)
        assert "\n" not in line
        assert json.loads(line)["message"] == "a\nb"


class TestOpsEndpoints:
    def test_health_does_not_require_a_database(self, client):
        resp = client.get("/health")
        assert resp.status_code == 200
        assert resp.json()["status"] == "ok"

    def test_health_reports_the_deployed_version(self, client):
        """The CD smoke test asserts this equals the git SHA it just shipped."""
        assert "version" in client.get("/health").json()

    def test_metrics_endpoint_exposes_prometheus_exposition(self, client):
        client.get("/health")
        body = client.get("/metrics").text
        assert "http_request_duration_seconds" in body
        assert "http_requests_total" in body

    def test_readyz_reports_503_when_the_database_is_unreachable(
        self, client, monkeypatch
    ):
        from sqlalchemy.exc import OperationalError

        import db

        def boom():
            raise OperationalError("SELECT 1", {}, Exception("refused"))

        monkeypatch.setattr(db, "ping", boom)
        resp = client.get("/readyz")
        assert resp.status_code == 503
        assert resp.json()["database"] == "unreachable"
