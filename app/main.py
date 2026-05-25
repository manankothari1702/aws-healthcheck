"""Application factory and entrypoint."""

import logging

from flask import Flask, jsonify
from werkzeug.exceptions import HTTPException

from app.config import Config
from app.routes import health, metrics, targets

logger = logging.getLogger(__name__)


def create_app(config=None) -> Flask:
    app = Flask(__name__)
    app.config.from_object(config or Config)

    # Seed in-memory target list from config.
    targets.seed_targets(app.config.get("DEFAULT_TARGETS", []))

    # Register blueprints.
    app.register_blueprint(health.bp)
    app.register_blueprint(metrics.bp)
    app.register_blueprint(targets.bp)

    @app.errorhandler(HTTPException)
    def handle_http_exception(err):
        return (
            jsonify(
                {"error": err.description, "code": err.name.upper().replace(" ", "_")}
            ),
            err.code,
        )

    @app.errorhandler(Exception)
    def handle_unexpected_exception(err):
        logger.exception("unhandled exception: %s", err)
        return (
            jsonify(
                {"error": "Internal server error", "code": "INTERNAL_SERVER_ERROR"}
            ),
            500,
        )

    return app


if __name__ == "__main__":
    application = create_app()
    application.run(
        host=application.config["HOST"],
        port=application.config["PORT"],
        debug=application.config["DEBUG"],
    )
