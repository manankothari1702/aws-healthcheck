"""HTTP health check logic. Pure functions — no Flask, no AWS dependencies."""

import time
import requests


def check_url(url, timeout) -> dict:
    """Return structured health metadata for a single HTTP target.

    response_time_ms is None on any error path. Never raises — bad inputs
    (None url, non-positive timeout) become a result with error set.
    """
    result = {
        "url": url,
        "healthy": False,
        "status_code": None,
        "response_time_ms": None,
        "error": None,
    }

    if not isinstance(url, str) or not url:
        result["error"] = "Invalid target URL"
        return result
    if not isinstance(timeout, (int, float)) or timeout <= 0:
        result["error"] = f"Invalid timeout: {timeout!r}"
        return result

    start = time.perf_counter()
    try:
        response = requests.get(url, timeout=timeout)
        elapsed_ms = round((time.perf_counter() - start) * 1000, 2)
        result["status_code"] = response.status_code
        result["response_time_ms"] = elapsed_ms
        # Treat any 2xx as healthy.
        result["healthy"] = 200 <= response.status_code < 300
        if not result["healthy"]:
            result["error"] = f"Non-2xx status: {response.status_code}"
    except requests.Timeout:
        result["error"] = f"Request timed out after {timeout}s"
    except requests.ConnectionError as e:
        result["error"] = f"Connection error: {e.__class__.__name__}"
    except (
        Exception
    ) as e:  # noqa: BLE001 — surface unknowns as errors, never crash the check
        result["error"] = f"Unexpected error: {e.__class__.__name__}: {e}"

    return result


def check_targets(targets: list[str], timeout: float) -> list[dict]:
    """Check a list of URLs sequentially and return their structured results."""
    return [check_url(url, timeout) for url in targets]
