"""Application configuration loaded from environment variables."""

import os
from dotenv import load_dotenv

load_dotenv()


def _parse_targets(raw: str) -> list[str]:
    if not raw:
        return []
    return [t.strip() for t in raw.split(",") if t.strip()]


class Config:
    APP_NAME = os.getenv("APP_NAME", "aws-healthcheck")
    FLASK_ENV = os.getenv("FLASK_ENV", "production")
    DEBUG = os.getenv("FLASK_DEBUG", "false").lower() == "true"
    HOST = os.getenv("FLASK_HOST", "0.0.0.0")
    PORT = int(os.getenv("FLASK_PORT", "8080"))

    HEALTHCHECK_TIMEOUT = float(os.getenv("HEALTHCHECK_TIMEOUT", "5"))
    DEFAULT_TARGETS = _parse_targets(os.getenv("DEFAULT_TARGETS", ""))
