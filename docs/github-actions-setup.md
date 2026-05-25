# GitHub Actions + AWS OIDC Setup

This guide wires up GitHub Actions to deploy the `aws-healthcheck` service to
AWS ECS using short-lived credentials minted from GitHub's OIDC provider. No
static IAM user keys are stored in GitHub.

Replace placeholders before running:

- `<AWS_ACCOUNT_ID>` — your 12-digit AWS account ID
- `<GITHUB_ORG>` — your GitHub org or user (e.g. `acme-corp`)
- `<GITHUB_REPO>` — the repository name (e.g. `cloudops-monitor`)
- `<AWS_REGION>` — defaults to `us-east-1` (matches `deploy.yml`)

---

## 1. Create the GitHub OIDC provider in AWS

This is a one-time per-account setup. Skip if `token.actions.githubusercontent.com`
already exists in IAM Identity Providers.

```bash
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
```

Verify:

```bash
aws iam list-open-id-connect-providers
```

> AWS now validates GitHub's OIDC certificate against the real CA chain, so
> the thumbprint is a formality — any non-empty value works. Provide it anyway
> for compatibility.

---

## 2. Create the IAM deploy role

### 2a. Write the trust policy

Save as `trust-policy.json`. The `sub` condition pins the role to **this repo
and the `main` branch only** — pushes from other branches or other repos
cannot assume it.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::<AWS_ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
          "token.actions.githubusercontent.com:sub": "repo:<GITHUB_ORG>/<GITHUB_REPO>:ref:refs/heads/main"
        }
      }
    }
  ]
}
```

### 2b. Create the role

```bash
aws iam create-role \
  --role-name github-actions-aws-healthcheck-deploy \
  --assume-role-policy-document file://trust-policy.json \
  --description "GitHub Actions deploy role for aws-healthcheck"
```

### 2c. Capture the ARN

```bash
aws iam get-role \
  --role-name github-actions-aws-healthcheck-deploy \
  --query 'Role.Arn' --output text
```

You will paste this ARN into GitHub in step 4.

---

## 3. Attach permissions

The deploy needs to push images to ECR and update the ECS service.

```bash
aws iam attach-role-policy \
  --role-name github-actions-aws-healthcheck-deploy \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser

aws iam attach-role-policy \
  --role-name github-actions-aws-healthcheck-deploy \
  --policy-arn arn:aws:iam::aws:policy/AmazonECS_FullAccess
```

The role also needs `iam:PassRole` for the ECS task execution role
(`aws-healthcheck-ecs-execution`) so `RegisterTaskDefinition` can attach it.
`AmazonECS_FullAccess` already grants `iam:PassRole` scoped to ECS task roles,
so no extra inline policy is required for the standard setup.

> **Production note:** these AWS-managed policies are broad. For a hardened
> setup, replace them with a custom least-privilege policy scoped to the
> single ECR repository (`aws-healthcheck`) and the single ECS cluster
> (`aws-healthcheck`).

---

## 4. Add the role ARN as a GitHub Actions secret

1. Go to **GitHub → repo → Settings → Secrets and variables → Actions**.
2. Click **New repository secret**.
3. Name: `AWS_DEPLOY_ROLE_ARN`
4. Value: the ARN from step 2c
   (e.g. `arn:aws:iam::123456789012:role/github-actions-aws-healthcheck-deploy`).
5. Save.

The workflow reads it as `${{ secrets.AWS_DEPLOY_ROLE_ARN }}`. No other AWS
secrets are needed — no access key, no secret key.

---

## 5. Verify the first end-to-end deployment

Prerequisite: the infrastructure (ECR repo, ECS cluster, service, ALB, task
definition family) must already exist. Run `deploy/manual-deploy.sh` once from
a workstation to bootstrap it. After that, GitHub Actions takes over.

1. **Trigger CI** — open a PR to `main` and confirm the `CI` workflow runs
   lint, formatting, and tests with ≥80 % coverage.
2. **Merge to main** — push or merge the PR. CI re-runs on the merge commit.
3. **Watch Deploy** — when CI succeeds, the `Deploy` workflow starts
   automatically via `workflow_run`. In the Actions tab open the run and check:
   - `Configure AWS credentials via OIDC` shows a session ARN with
     `assumed-role/github-actions-aws-healthcheck-deploy/...`.
   - `Build, tag, and push image to ECR` pushes both `:<sha>` and `:latest`.
   - `Deploy task definition to ECS` ends with
     `Service is stable. Current desired count: 1, running: 1.`
   - Final step prints `Deployed image - <ECR URI>:<sha>`.
4. **Smoke test the live service**:

   ```bash
   ALB_DNS=$(aws elbv2 describe-load-balancers \
     --names aws-healthcheck-alb \
     --query 'LoadBalancers[0].DNSName' --output text)
   curl -fsS "http://${ALB_DNS}/health"
   ```

   Expected: `{"status":"ok",...}`.

5. **Confirm the new image is live**:

   ```bash
   aws ecs describe-services \
     --cluster aws-healthcheck \
     --services aws-healthcheck-svc \
     --query 'services[0].taskDefinition'
   ```

   The revision number should have incremented and the task definition should
   reference the new `<sha>` tag.

If any step fails, the rollback procedure is in
[Question 5 of the interview answers](#rollback) — re-point the service at the
previous task definition revision and let ECS drain the bad tasks.
