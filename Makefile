.PHONY: run test lint build clean

run:
	docker-compose up --build

test:
	docker-compose -f docker-compose.test.yml run --rm test

lint:
	black --check app/ tests/ && flake8 app/ tests/ --max-line-length=100

build:
	docker build -t aws-healthcheck:local .

clean:
	docker-compose down --remove-orphans
	find . -type d -name __pycache__ -exec rm -rf {} +
