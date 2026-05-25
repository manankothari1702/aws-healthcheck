"""Aggregate metrics endpoint."""

from flask import Blueprint, current_app, jsonify

from app.services.checker import check_targets
from app.routes.targets import get_targets

bp = Blueprint("metrics", __name__)


@bp.get("/metrics/summary")
def metrics_summary():
    timeout = current_app.config["HEALTHCHECK_TIMEOUT"]
    targets = get_targets()
    results = check_targets(targets, timeout)

    total = len(results)
    healthy = sum(1 for r in results if r["healthy"])
    unhealthy = total - healthy

    response_times = [
        r["response_time_ms"] for r in results if r["response_time_ms"] is not None
    ]
    avg_rt = (
        round(sum(response_times) / len(response_times), 2) if response_times else 0.0
    )
    health_ratio = round(healthy / total, 4) if total else 0.0

    return (
        jsonify(
            {
                "total_targets": total,
                "healthy": healthy,
                "unhealthy": unhealthy,
                "health_ratio": health_ratio,
                "avg_response_time_ms": avg_rt,
            }
        ),
        200,
    )
