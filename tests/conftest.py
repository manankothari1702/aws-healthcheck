"""Shared pytest fixtures for the aws-healthcheck test suite."""

import pytest

from app.main import create_app
from app.config import Config


class TestConfig(Config):
    TESTING = True
    DEBUG = False
    DEFAULT_TARGETS = ["https://httpbin.org/status/200"]
    HEALTHCHECK_TIMEOUT = 2.0


@pytest.fixture
def app():
    application = create_app(config=TestConfig)
    yield application


@pytest.fixture
def client(app):
    return app.test_client()
