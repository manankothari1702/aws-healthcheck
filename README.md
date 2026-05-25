# aws-healthcheck

![CI](https://github.com/manankothari1702/aws-healthcheck/actions/workflows/ci.yml/badge.svg)
![Deploy](https://github.com/manankothari1702/aws-healthcheck/actions/workflows/deploy.yml/badge.svg)

Polls a configurable list of HTTP targets and exposes their liveness, latency, and aggregate health via JSON endpoints. Runs as a single Flask container on ECS Fargate behind an ALB.

## What this project demonstrates

- **Docker** — non-root user, digest-pinned base image, urllib healthcheck (no curl dependency)
- **AWS ECS Fargate** — containerised deployment, no EC2 management
- **AWS ALB** — stable DNS, automatic health-check routing, rolling deploys
- **GitHub Actions CI/CD** — lint → test (94% coverage gate) → Docker build → ECR push → ECS rolling deploy
- **OIDC authentication** — zero static AWS keys; trust policy scoped to single repo + main branch
- **AWS CloudWatch** — container log streaming via awslogs driver
- **pytest** — 19 tests, 94% coverage, failure paths + edge cases covered

## Architecture

```
                 +-------------------+
   Internet ---> |  ALB (HTTP :80)   |
                 +---------+---------+
                           |
                           v
                 +---------+---------+
                 | ECS Fargate task  |
                 |  gunicorn :5000   |
                 |  app.main:create_app
                 +---------+---------+
                           |
              outbound GET | (requests lib, 5s timeout)
                           v
                 +---------+---------+
                 | DEFAULT_TARGETS   |
                 |  (configured URLs)|
                 +-------------------+

   CloudWatch Logs  <----  awslogs driver  (/ecs/aws-healthcheck)
```

## Local dev

```
cd aws-healthcheck
python -m venv .venv && . .venv/Scripts/activate      # PowerShell: .venv\Scripts\Activate.ps1
pip install -r requirements-dev.txt
cp .env.example .env
python -m app.main                                    # serves on :8080
```

Or via docker:

```
cd aws-healthcheck
docker compose up --build                             # serves on :5000
```

Tests, lint, format:

```
pytest tests/ --cov=app
flake8 app/ tests/ --max-line-length=100
black --check app/ tests/
```

## API

| Method | Path              | Response                                                                 |
|--------|-------------------|--------------------------------------------------------------------------|
| GET    | /health           | `{"status":"ok","service":"aws-healthcheck"}` — liveness, always 200    |
| GET    | /health/targets   | `{"status":"ok|degraded","checked":N,"results":[...]}` — 200 or 207     |
| GET    | /metrics/summary  | `{"total_targets","healthy","unhealthy","health_ratio","avg_response_time_ms"}` |
| GET    | /targets          | `{"targets":[...],"count":N}`                                            |
| POST   | /targets          | body `{"url":"https://..."}` → 201 added / 200 already / 400 invalid     |

Per-target result shape:
```json
{"url":"https://x","healthy":true,"status_code":200,"response_time_ms":42.0,"error":null}
```

## Environment variables

| Name                | Default            | Description                                              |
|---------------------|--------------------|----------------------------------------------------------|
| APP_NAME            | aws-healthcheck    | Returned in `/health` response                           |
| FLASK_ENV           | production         | Flask environment                                        |
| FLASK_HOST          | 0.0.0.0            | Bind host (dev runner only; gunicorn uses its own bind)  |
| FLASK_PORT          | 8080               | Bind port (5000 inside the container)                    |
| FLASK_DEBUG         | false              | Enable Flask debug mode                                  |
| HEALTHCHECK_TIMEOUT | 5                  | Per-target GET timeout, seconds                          |
| DEFAULT_TARGETS     | (empty)            | Comma-separated URLs seeded into the registry at startup |

## Deploy

`deploy/manual-deploy.sh` provisions everything idempotently: ECR repo, image build/push, ECS cluster, execution role, log group, task definition, ALB + target group + security groups, ECS service. Re-running it rolls a new task revision.

Prereqs: aws CLI v2 with credentials in the target account, docker, jq, git, a default VPC in `$REGION`.

```
cd aws-healthcheck
REGION=us-east-1 ./deploy/manual-deploy.sh
```

Teardown: `./deploy/teardown.sh`.

## CI/CD

`.github/workflows/ci.yml` runs flake8, black --check, and pytest with coverage on every PR and push to `main`. On a successful CI run against `main`, `.github/workflows/deploy.yml` builds the image, pushes it to ECR tagged with the commit SHA, renders a new ECS task definition from the live one, and rolls the service via `aws-actions/amazon-ecs-deploy-task-definition`. AWS access is via OIDC — the role ARN is in the `AWS_DEPLOY_ROLE_ARN` secret. See [docs/github-actions-setup.md](docs/github-actions-setup.md).

## Cost

Rough monthly steady-state in us-east-1, single task, default ALB:

- ALB: ~$16 (LCU usage is negligible at this volume; the hourly charge dominates)
- Fargate 0.25 vCPU / 0.5 GB, 1 task 24/7: ~$8
- ECR storage + data egress + CloudWatch Logs (7-day retention): ~$1

≈ **$25/month**. ALB is the line item to kill first if you need it cheaper — swap for an NLB or expose the task directly behind API Gateway.
