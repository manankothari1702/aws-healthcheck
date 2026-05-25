"""Route-level tests for health, metrics, and targets endpoints."""

from unittest.mock import patch


HEALTHY = {
    "url": "https://example.com",
    "healthy": True,
    "status_code": 200,
    "response_time_ms": 42.0,
    "error": None,
}
UNHEALTHY = {
    "url": "https://broken.example.com",
    "healthy": False,
    "status_code": 500,
    "response_time_ms": 12.5,
    "error": "Non-2xx status: 500",
}


def test_health_liveness(client):
    resp = client.get("/health")
    assert resp.status_code == 200
    body = resp.get_json()
    assert body["status"] == "ok"
    assert "service" in body


def test_health_targets_all_healthy(client):
    with patch("app.routes.health.check_targets", return_value=[HEALTHY, HEALTHY]):
        resp = client.get("/health/targets")
    assert resp.status_code == 200
    assert resp.get_json()["status"] == "ok"


def test_health_targets_degraded(client):
    with patch("app.routes.health.check_targets", return_value=[HEALTHY, UNHEALTHY]):
        resp = client.get("/health/targets")
    assert resp.status_code == 207
    assert resp.get_json()["status"] == "degraded"


def test_metrics_summary_shape(client):
    with patch("app.routes.metrics.check_targets", return_value=[HEALTHY, UNHEALTHY]):
        resp = client.get("/metrics/summary")
    assert resp.status_code == 200
    body = resp.get_json()
    for key in (
        "total_targets",
        "healthy",
        "unhealthy",
        "health_ratio",
        "avg_response_time_ms",
    ):
        assert key in body


def test_list_targets(client):
    resp = client.get("/targets")
    assert resp.status_code == 200
    body = resp.get_json()
    assert "targets" in body
    assert isinstance(body["targets"], list)


def test_post_target_invalid(client):
    resp = client.post("/targets", json={"url": "not-a-url"})
    assert resp.status_code == 400
    assert "error" in resp.get_json()


def test_post_target_non_json_body(client):
    resp = client.post("/targets", data="not json at all", content_type="text/plain")
    assert resp.status_code == 400
    assert "error" in resp.get_json()


def test_post_target_url_none(client):
    resp = client.post("/targets", json={"url": None})
    assert resp.status_code == 400


def test_post_target_url_too_long(client):
    long_url = "https://example.com/" + ("a" * 3000)
    resp = client.post("/targets", json={"url": long_url})
    assert resp.status_code == 400


def test_post_target_valid(client):
    url = "https://new.example.com"
    resp = client.post("/targets", json={"url": url})
    assert resp.status_code == 201
    body = resp.get_json()
    assert body["url"] == url
    assert body["status"] == "created"


def test_unknown_route_returns_json_404(client):
    resp = client.get("/does-not-exist")
    assert resp.status_code == 404
    assert resp.is_json
    body = resp.get_json()
    assert "error" in body
    assert "code" in body


def test_unhandled_exception_returns_json_500(app, client):
    @app.route("/__boom__")
    def boom():
        raise RuntimeError("kaboom")

    app.config["PROPAGATE_EXCEPTIONS"] = False
    resp = client.get("/__boom__")
    assert resp.status_code == 500
    assert resp.is_json
    body = resp.get_json()
    assert body["code"] == "INTERNAL_SERVER_ERROR"
    assert "error" in body
