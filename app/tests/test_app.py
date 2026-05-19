import pytest
import json
from app import app as flask_app


@pytest.fixture()
def client():
    flask_app.config["TESTING"] = True
    flask_app.config["CHAOS_ERROR_RATE"] = 0.0
    flask_app.config["CHAOS_LATENCY_MS"] = 0
    with flask_app.test_client() as c:
        yield c


# ---------------------------------------------------------------------------
# Health endpoints
# ---------------------------------------------------------------------------
def test_liveness(client):
    r = client.get("/health/live")
    assert r.status_code == 200
    assert r.get_json()["status"] == "alive"


def test_readiness_healthy(client):
    client.post("/chaos/db-up")
    r = client.get("/health/ready")
    assert r.status_code == 200
    assert r.get_json()["checks"]["database"] == "ok"


def test_readiness_db_down(client):
    client.post("/chaos/db-down")
    r = client.get("/health/ready")
    assert r.status_code == 503
    assert "database" in r.get_json()["checks"]
    client.post("/chaos/db-up")


# ---------------------------------------------------------------------------
# Items CRUD
# ---------------------------------------------------------------------------
def test_create_item(client):
    r = client.post("/api/items", json={"name": "test item", "description": "desc"})
    assert r.status_code == 201
    body = r.get_json()
    assert body["name"] == "test item"
    assert "id" in body
    return body["id"]


def test_create_item_missing_name(client):
    r = client.post("/api/items", json={})
    assert r.status_code == 400


def test_list_items(client):
    client.post("/api/items", json={"name": "item-a"})
    client.post("/api/items", json={"name": "item-b"})
    r = client.get("/api/items")
    assert r.status_code == 200
    assert r.get_json()["count"] >= 2


def test_get_item(client):
    create = client.post("/api/items", json={"name": "lookup-me"})
    item_id = create.get_json()["id"]
    r = client.get(f"/api/items/{item_id}")
    assert r.status_code == 200
    assert r.get_json()["id"] == item_id


def test_get_item_not_found(client):
    r = client.get("/api/items/nonexistent-id")
    assert r.status_code == 404


def test_delete_item(client):
    create = client.post("/api/items", json={"name": "delete-me"})
    item_id = create.get_json()["id"]
    r = client.delete(f"/api/items/{item_id}")
    assert r.status_code == 204
    r2 = client.get(f"/api/items/{item_id}")
    assert r2.status_code == 404


def test_delete_item_not_found(client):
    r = client.delete("/api/items/nonexistent")
    assert r.status_code == 404


# ---------------------------------------------------------------------------
# Metrics endpoint
# ---------------------------------------------------------------------------
def test_metrics_endpoint(client):
    client.get("/health/live")
    r = client.get("/metrics")
    assert r.status_code == 200
    body = r.data.decode()
    assert "http_requests_total" in body
    assert "http_request_duration_seconds" in body


# ---------------------------------------------------------------------------
# Chaos endpoints
# ---------------------------------------------------------------------------
def test_chaos_error_rate(client):
    r = client.post("/chaos/error-rate/0.0")
    assert r.status_code == 200
    r_invalid = client.post("/chaos/error-rate/1.5")
    assert r_invalid.status_code == 400


def test_chaos_latency(client):
    r = client.post("/chaos/latency/0")
    assert r.status_code == 200


def test_chaos_reset(client):
    client.post("/chaos/error-rate/0.5")
    client.post("/chaos/latency/100")
    r = client.post("/chaos/reset")
    assert r.status_code == 200
    assert flask_app.config["CHAOS_ERROR_RATE"] == 0.0
    assert flask_app.config["CHAOS_LATENCY_MS"] == 0


# ---------------------------------------------------------------------------
# Request ID propagation
# ---------------------------------------------------------------------------
def test_request_id_header_propagated(client):
    r = client.get("/health/live", headers={"X-Request-ID": "test-123"})
    assert r.headers.get("X-Request-ID") == "test-123"


def test_request_id_generated_when_absent(client):
    r = client.get("/health/live")
    assert r.headers.get("X-Request-ID") is not None
