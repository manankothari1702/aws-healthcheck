"""Application factory and entrypoint."""

from flask import Flask, jsonify

from app.config import Config
from app.routes import health, metrics, targets


def create_app(config=None) -> Flask:
    app = Flask(__name__)
    app.config.from_object(config or Config)

    # Seed in-memory target list from config.
    targets.seed_targets(app.config.get("DEFAULT_TARGETS", []))

    # Register blueprints.
    app.register_blueprint(health.bp)
    app.register_blueprint(metrics.bp)
    app.register_blueprint(targets.bp)

    @app.errorhandler(404)
    def not_found(_err):
        return jsonify({"error": "Not found"}), 404

    return app


if __name__ == "__main__":
    application = create_app()
    application.run(
        host=application.config["HOST"],
        port=application.config["PORT"],
        debug=application.config["DEBUG"],
    )
