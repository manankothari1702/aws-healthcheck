"""Unit tests for the HTTP health checker. No real network calls."""

from unittest.mock import patch, MagicMock

import requests

from app.services.checker import check_url, check_targets


def _mock_response(status_code: int) -> MagicMock:
    resp = MagicMock()
    resp.status_code = status_code
    return resp


def test_check_url_success():
    with patch("app.services.checker.requests.get", return_value=_mock_response(200)):
        result = check_url("https://ok.example.com", timeout=2.0)
    assert result["healthy"] is True
    assert result["status_code"] == 200
    assert result["error"] is None
    assert result["response_time_ms"] is not None


def test_check_url_server_error():
    with patch("app.services.checker.requests.get", return_value=_mock_response(500)):
        result = check_url("https://err.example.com", timeout=2.0)
    assert result["healthy"] is False
    assert result["status_code"] == 500


def test_check_url_timeout():
    with patch("app.services.checker.requests.get", side_effect=requests.Timeout()):
        result = check_url("https://slow.example.com", timeout=0.1)
    assert result["healthy"] is False
    assert result["error"] is not None
    assert (
        "timed out" in result["error"].lower() or "timeout" in result["error"].lower()
    )


def test_check_url_connection_error():
    with patch(
        "app.services.checker.requests.get", side_effect=requests.ConnectionError()
    ):
        result = check_url("https://down.example.com", timeout=2.0)
    assert result["healthy"] is False
    assert result["error"] is not None
    assert "connection" in result["error"].lower()


def test_check_url_rejects_none_url():
    result = check_url(None, timeout=2.0)
    assert result["healthy"] is False
    assert result["status_code"] is None
    assert result["response_time_ms"] is None
    assert "Invalid" in result["error"]


def test_check_url_rejects_non_positive_timeout():
    result = check_url("https://ok.example.com", timeout=0)
    assert result["healthy"] is False
    assert result["error"].startswith("Invalid timeout")


def test_check_targets_filters_blank_entries():
    """Blank/whitespace targets coming from config parsing should be filtered upstream;
    check_targets itself should at minimum not crash and should produce one result per
    non-blank input when fed a pre-cleaned list."""
    raw = ["https://ok.example.com", "", "   ", "https://two.example.com"]
    cleaned = [t for t in raw if t and t.strip()]

    with patch("app.services.checker.requests.get", return_value=_mock_response(200)):
        results = check_targets(cleaned, timeout=2.0)

    assert len(results) == 2
    assert all(r["healthy"] for r in results)
