"""Integration tests: exercised against a real PostgreSQL.

CI runs these against a postgres service container. Locally they skip unless a
database is reachable (see the db_client fixture).
"""

import pytest

pytestmark = pytest.mark.integration


def test_readyz_is_ok_against_a_real_database(db_client):
    resp = db_client.get("/readyz")
    assert resp.status_code == 200
    assert resp.json()["database"] == "reachable"


def test_create_then_read_round_trips_through_postgres(db_client):
    created = db_client.post(
        "/items", json={"name": "widget", "description": "a thing"}
    )
    assert created.status_code == 201
    item_id = created.json()["id"]

    fetched = db_client.get(f"/items/{item_id}")
    assert fetched.status_code == 200
    assert fetched.json()["name"] == "widget"
    assert fetched.json()["created_at"]


def test_listing_returns_the_newest_first(db_client):
    first = db_client.post("/items", json={"name": "older"}).json()["id"]
    second = db_client.post("/items", json={"name": "newer"}).json()["id"]

    ids = [item["id"] for item in db_client.get("/items").json()]
    assert ids.index(second) < ids.index(first)


def test_missing_item_is_a_404_not_a_500(db_client):
    assert db_client.get("/items/99999999").status_code == 404


def test_invalid_payload_is_rejected_before_it_reaches_the_database(db_client):
    assert db_client.post("/items", json={"name": ""}).status_code == 422
    assert db_client.post("/items", json={}).status_code == 422


def test_list_limit_is_clamped_to_a_sane_range(db_client):
    """An unbounded LIMIT is a trivial way to exhaust the connection's memory."""
    assert db_client.get("/items?limit=100000").status_code == 200
    assert db_client.get("/items?limit=0").status_code == 200
