"""Target registry — in-memory CRUD for monitored targets."""

import logging

from flask import Blueprint, jsonify, request

logger = logging.getLogger(__name__)

MAX_URL_LENGTH = 2048

bp = Blueprint("targets", __name__)

# Module-level store. Seeded from config at app startup via seed_targets().
_targets: list[str] = []


def get_targets() -> list[str]:
    """Return a copy of the current target list."""
    return list(_targets)


def seed_targets(initial: list[str]) -> None:
    """Replace the in-memory list with the provided initial targets."""
    global _targets
    _targets = list(initial)


def _is_valid_url(url) -> bool:
    if not isinstance(url, str) or not url:
        return False
    if len(url) > MAX_URL_LENGTH:
        return False
    return url.startswith("http://") or url.startswith("https://")


@bp.get("/targets")
def list_targets():
    return jsonify({"targets": get_targets(), "count": len(_targets)}), 200


@bp.post("/targets")
def add_target():
    payload = request.get_json(silent=True) or {}
    url = payload.get("url")

    if not _is_valid_url(url):
        return (
            jsonify(
                {
                    "error": (
                        "Invalid target URL. Must be a non-empty http(s) string "
                        f"no longer than {MAX_URL_LENGTH} characters."
                    ),
                    "code": "INVALID_URL",
                }
            ),
            400,
        )

    if url in _targets:
        return jsonify({"status": "exists", "url": url}), 200

    _targets.append(url)
    logger.info("target added url=%s total_targets=%d", url, len(_targets))
    return jsonify({"status": "created", "url": url}), 201


@bp.delete("/targets")
def remove_target():
    payload = request.get_json(silent=True) or {}
    url = payload.get("url")

    if not _is_valid_url(url):
        return (
            jsonify(
                {
                    "error": (
                        "Invalid target URL. Must be a non-empty http(s) string "
                        f"no longer than {MAX_URL_LENGTH} characters."
                    ),
                    "code": "INVALID_URL",
                }
            ),
            400,
        )

    if url not in _targets:
        return jsonify({"error": "Target not found.", "code": "NOT_FOUND"}), 404

    _targets.remove(url)
    logger.info("target removed url=%s total_targets=%d", url, len(_targets))
    return jsonify({"status": "deleted", "url": url}), 200
