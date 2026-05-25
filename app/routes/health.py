"""Liveness and target-health endpoints."""

from flask import Blueprint, current_app, jsonify

from app.services.checker import check_targets
from app.routes.targets import get_targets

bp = Blueprint("health", __name__)


@bp.get("/health")
def health():
    """Liveness probe — always 200 if the process is up."""
    return jsonify({"status": "ok", "service": current_app.config["APP_NAME"]}), 200


@bp.get("/health/targets")
def health_targets():
    """Aggregate health across configured targets. 200 all-healthy, 207 degraded."""
    timeout = current_app.config["HEALTHCHECK_TIMEOUT"]
    targets = get_targets()
    results = check_targets(targets, timeout)

    all_healthy = bool(results) and all(r["healthy"] for r in results)
    status_code = 200 if all_healthy else 207

    return (
        jsonify(
            {
                "status": "ok" if all_healthy else "degraded",
                "checked": len(results),
                "results": results,
            }
        ),
        status_code,
    )
