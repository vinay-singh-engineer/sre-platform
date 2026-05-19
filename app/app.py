from __future__ import annotations

import os
import time
import uuid
import random
import logging
import json
from datetime import datetime, timezone

from flask import Flask, request, jsonify, g
from prometheus_client import (
    Counter, Histogram, Gauge, generate_latest, CONTENT_TYPE_LATEST
)
from pythonjsonlogger import jsonlogger

# ---------------------------------------------------------------------------
# App setup
# ---------------------------------------------------------------------------
app = Flask(__name__)
app.config["DB_PATH"] = os.environ.get("DB_PATH", "/tmp/items.db")
app.config["CHAOS_ERROR_RATE"] = float(os.environ.get("CHAOS_ERROR_RATE", "0.0"))
app.config["CHAOS_LATENCY_MS"] = int(os.environ.get("CHAOS_LATENCY_MS", "0"))

# ---------------------------------------------------------------------------
# Structured JSON logging
# ---------------------------------------------------------------------------
handler = logging.StreamHandler()
formatter = jsonlogger.JsonFormatter(
    fmt="%(asctime)s %(name)s %(levelname)s %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
)
handler.setFormatter(formatter)
logger = logging.getLogger("sre_platform")
logger.addHandler(handler)
logger.setLevel(logging.INFO)

# ---------------------------------------------------------------------------
# Prometheus metrics  (RED: Rate, Errors, Duration)
# ---------------------------------------------------------------------------
REQUEST_COUNT = Counter(
    "http_requests_total",
    "Total HTTP requests",
    ["method", "endpoint", "status_code"],
)
REQUEST_LATENCY = Histogram(
    "http_request_duration_seconds",
    "HTTP request latency",
    ["method", "endpoint"],
    buckets=[0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5],
)
IN_PROGRESS = Gauge(
    "http_requests_in_progress",
    "Requests currently being processed",
    ["method", "endpoint"],
)
APP_INFO = Gauge(
    "app_info",
    "Application metadata",
    ["version", "environment"],
)
ITEM_COUNT = Gauge("items_total", "Total items stored")
DB_STATUS = Gauge("db_up", "Database reachability (1=up, 0=down)")

APP_VERSION = os.environ.get("APP_VERSION", "1.0.0")
ENVIRONMENT = os.environ.get("ENVIRONMENT", "production")
APP_INFO.labels(version=APP_VERSION, environment=ENVIRONMENT).set(1)

# ---------------------------------------------------------------------------
# Tiny in-memory "database" (swap for SQLite/RDS in prod)
# ---------------------------------------------------------------------------
_items: dict[str, dict] = {}
_db_healthy = True  # toggled by /chaos/db-down


def _db_write(item: dict) -> None:
    _items[item["id"]] = item
    ITEM_COUNT.set(len(_items))
    DB_STATUS.set(1 if _db_healthy else 0)


def _db_read_all() -> list:
    if not _db_healthy:
        raise RuntimeError("Database unavailable")
    return list(_items.values())


def _db_read_one(item_id: str) -> dict | None:
    if not _db_healthy:
        raise RuntimeError("Database unavailable")
    return _items.get(item_id)


def _db_delete(item_id: str) -> bool:
    if not _db_healthy:
        raise RuntimeError("Database unavailable")
    if item_id in _items:
        del _items[item_id]
        ITEM_COUNT.set(len(_items))
        return True
    return False


# ---------------------------------------------------------------------------
# Request lifecycle hooks
# ---------------------------------------------------------------------------
@app.before_request
def before_request():
    g.start_time = time.time()
    g.request_id = request.headers.get("X-Request-ID", str(uuid.uuid4()))
    IN_PROGRESS.labels(method=request.method, endpoint=request.path).inc()

    # Chaos: inject latency
    latency_ms = app.config["CHAOS_LATENCY_MS"]
    if latency_ms > 0:
        time.sleep(latency_ms / 1000)


@app.after_request
def after_request(response):
    duration = time.time() - g.start_time
    REQUEST_COUNT.labels(
        method=request.method,
        endpoint=request.path,
        status_code=response.status_code,
    ).inc()
    REQUEST_LATENCY.labels(
        method=request.method,
        endpoint=request.path,
    ).observe(duration)
    IN_PROGRESS.labels(method=request.method, endpoint=request.path).dec()

    response.headers["X-Request-ID"] = g.request_id
    response.headers["X-Response-Time"] = f"{duration:.4f}s"

    logger.info(
        "request completed",
        extra={
            "request_id": g.request_id,
            "method": request.method,
            "path": request.path,
            "status": response.status_code,
            "duration_ms": round(duration * 1000, 2),
            "remote_addr": request.remote_addr,
        },
    )
    return response


# ---------------------------------------------------------------------------
# Health endpoints  (Kubernetes / ECS probe compatible)
# ---------------------------------------------------------------------------
@app.route("/health/live")
def liveness():
    """Liveness: is the process alive? Never depends on external resources."""
    return jsonify({"status": "alive", "timestamp": _now()}), 200


@app.route("/health/ready")
def readiness():
    """Readiness: can we serve traffic? Checks downstream dependencies."""
    checks = {}
    overall_ok = True

    # DB check
    try:
        _db_read_all()
        checks["database"] = "ok"
        DB_STATUS.set(1)
    except Exception as exc:
        checks["database"] = f"error: {exc}"
        DB_STATUS.set(0)
        overall_ok = False

    status_code = 200 if overall_ok else 503
    return jsonify(
        {
            "status": "ready" if overall_ok else "not_ready",
            "checks": checks,
            "timestamp": _now(),
        }
    ), status_code


# ---------------------------------------------------------------------------
# Prometheus metrics endpoint
# ---------------------------------------------------------------------------
@app.route("/metrics")
def metrics():
    return generate_latest(), 200, {"Content-Type": CONTENT_TYPE_LATEST}


# ---------------------------------------------------------------------------
# Application API  (simple items CRUD)
# ---------------------------------------------------------------------------
@app.route("/api/items", methods=["GET"])
def list_items():
    _maybe_chaos_error()
    items = _db_read_all()
    return jsonify({"items": items, "count": len(items)}), 200


@app.route("/api/items", methods=["POST"])
def create_item():
    _maybe_chaos_error()
    body = request.get_json(silent=True) or {}
    if not body.get("name"):
        return jsonify({"error": "name is required"}), 400

    item = {
        "id": str(uuid.uuid4()),
        "name": body["name"],
        "description": body.get("description", ""),
        "created_at": _now(),
    }
    _db_write(item)
    logger.info("item created", extra={"item_id": item["id"]})
    return jsonify(item), 201


@app.route("/api/items/<item_id>", methods=["GET"])
def get_item(item_id):
    _maybe_chaos_error()
    item = _db_read_one(item_id)
    if item is None:
        return jsonify({"error": "not found"}), 404
    return jsonify(item), 200


@app.route("/api/items/<item_id>", methods=["DELETE"])
def delete_item(item_id):
    _maybe_chaos_error()
    deleted = _db_delete(item_id)
    if not deleted:
        return jsonify({"error": "not found"}), 404
    logger.info("item deleted", extra={"item_id": item_id})
    return "", 204


# ---------------------------------------------------------------------------
# Chaos engineering endpoints  (never expose in real prod without auth gate)
# ---------------------------------------------------------------------------
@app.route("/chaos/error-rate/<float:rate>", methods=["POST"])
def set_error_rate(rate):
    """Set random error injection rate (0.0–1.0)."""
    if not 0.0 <= rate <= 1.0:
        return jsonify({"error": "rate must be between 0.0 and 1.0"}), 400
    app.config["CHAOS_ERROR_RATE"] = rate
    logger.warning("chaos error rate set", extra={"rate": rate})
    return jsonify({"chaos_error_rate": rate}), 200


@app.route("/chaos/latency/<int:latency_ms>", methods=["POST"])
def set_latency(latency_ms):
    """Inject artificial latency in milliseconds."""
    app.config["CHAOS_LATENCY_MS"] = latency_ms
    logger.warning("chaos latency set", extra={"latency_ms": latency_ms})
    return jsonify({"chaos_latency_ms": latency_ms}), 200


@app.route("/chaos/db-down", methods=["POST"])
def db_down():
    """Simulate database failure to trigger readiness probe failure."""
    global _db_healthy
    _db_healthy = False
    DB_STATUS.set(0)
    logger.error("chaos: database marked as down")
    return jsonify({"db_healthy": False}), 200


@app.route("/chaos/db-up", methods=["POST"])
def db_up():
    """Restore database."""
    global _db_healthy
    _db_healthy = True
    DB_STATUS.set(1)
    logger.info("chaos: database restored")
    return jsonify({"db_healthy": True}), 200


@app.route("/chaos/reset", methods=["POST"])
def chaos_reset():
    """Reset all chaos settings."""
    global _db_healthy
    _db_healthy = True
    app.config["CHAOS_ERROR_RATE"] = 0.0
    app.config["CHAOS_LATENCY_MS"] = 0
    DB_STATUS.set(1)
    logger.info("chaos: all settings reset")
    return jsonify({"status": "reset"}), 200


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _maybe_chaos_error():
    rate = app.config["CHAOS_ERROR_RATE"]
    if rate > 0 and random.random() < rate:
        raise ChaosError("chaos-injected error")


class ChaosError(Exception):
    pass


@app.errorhandler(ChaosError)
def handle_chaos(exc):
    logger.error("chaos error injected", extra={"error": str(exc)})
    return jsonify({"error": "internal server error", "chaos": True}), 500


@app.errorhandler(RuntimeError)
def handle_runtime(exc):
    logger.error("runtime error", extra={"error": str(exc)})
    return jsonify({"error": str(exc)}), 503


@app.errorhandler(404)
def handle_404(exc):
    return jsonify({"error": "not found"}), 404


@app.errorhandler(405)
def handle_405(exc):
    return jsonify({"error": "method not allowed"}), 405


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8000, debug=False)
