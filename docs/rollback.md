# ECS Rollback Runbook

Cluster: `aws-healthcheck` · Service: `aws-healthcheck` · Region: `ap-south-1`

Set once per shell:

```bash
export AWS_REGION=ap-south-1
export CLUSTER=aws-healthcheck
export SERVICE=aws-healthcheck
```

## 1. Detect a bad deployment

ECS service events (last 10):

```bash
aws ecs describe-services --cluster $CLUSTER --services $SERVICE \
  --query 'services[0].events[0:10].[createdAt,message]' --output table
```

Look for: `unable to place a task`, `task failed ELB health checks`, repeated `stopped` / `started` cycles, `(service ...) has reached a steady state` NOT appearing.

Deployment status (PRIMARY should be `COMPLETED`, not stuck `IN_PROGRESS`):

```bash
aws ecs describe-services --cluster $CLUSTER --services $SERVICE \
  --query 'services[0].deployments[].[status,taskDefinition,runningCount,desiredCount,failedTasks,rolloutState]' \
  --output table
```

CloudWatch logs (replace log group with yours):

```bash
aws logs tail /ecs/aws-healthcheck --since 15m --follow
```

ALB target health:

```bash
TG_ARN=$(aws elbv2 describe-target-groups --query "TargetGroups[?contains(TargetGroupName,'aws-healthcheck')].TargetGroupArn" --output text)
aws elbv2 describe-target-health --target-group-arn $TG_ARN \
  --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State,TargetHealth.Reason,TargetHealth.Description]' --output table
```

Unhealthy reasons to act on: `Target.FailedHealthChecks`, `Target.Timeout`, `Target.ResponseCodeMismatch`.

## 2. Find the previous good revision

List recent ACTIVE revisions (newest first):

```bash
aws ecs list-task-definitions --family-prefix aws-healthcheck \
  --status ACTIVE --sort DESC --max-items 10
```

Current (bad) revision in use:

```bash
aws ecs describe-services --cluster $CLUSTER --services $SERVICE \
  --query 'services[0].taskDefinition' --output text
```

Previous = current revision number minus 1 (or pick the last one known-good from the list above). Confirm its image:

```bash
aws ecs describe-task-definition --task-definition aws-healthcheck:<REV> \
  --query 'taskDefinition.containerDefinitions[].image' --output text
```

## 3. Roll back

```bash
PREV=aws-healthcheck:<REV>   # e.g. aws-healthcheck:42

aws ecs update-service \
  --cluster $CLUSTER \
  --service $SERVICE \
  --task-definition $PREV \
  --force-new-deployment
```

If the deployment is stuck and you need it gone now, also stop in-flight tasks from the bad revision:

```bash
aws ecs list-tasks --cluster $CLUSTER --service-name $SERVICE \
  --query 'taskArns' --output text | tr '\t' '\n' | \
  xargs -I{} aws ecs stop-task --cluster $CLUSTER --task {} --reason "rollback"
```

## 4. Verify rollback

Wait for steady state:

```bash
aws ecs wait services-stable --cluster $CLUSTER --services $SERVICE
```

Confirm running task def matches the rollback target and counts are healthy:

```bash
aws ecs describe-services --cluster $CLUSTER --services $SERVICE \
  --query 'services[0].[taskDefinition,runningCount,desiredCount,deployments[0].rolloutState]' \
  --output table
```

Target group all `healthy`:

```bash
aws elbv2 describe-target-health --target-group-arn $TG_ARN \
  --query 'TargetHealthDescriptions[].TargetHealth.State' --output text
```

Hit the app:

```bash
ALB=$(aws elbv2 describe-load-balancers --query "LoadBalancers[?contains(LoadBalancerName,'aws-healthcheck')].DNSName" --output text)
curl -fsS -o /dev/null -w "%{http_code}\n" http://$ALB/health
```

Expect `200`. Tail logs another minute and confirm no error spike.

## 5. Prevent the broken image from being redeployed

The next push to `main` will rebuild and redeploy the same broken commit. Revert it:

```bash
git fetch origin
git checkout main
git pull --ff-only
git revert --no-edit <bad-commit-sha>
git push origin main
```

If the revert itself is risky (e.g. DB migration in the bad commit), instead:

- Push an empty hold commit on `main` that pins the image tag to the known-good one in the workflow / task def, OR
- Disable the deploy workflow temporarily:

```bash
gh workflow disable "CI" || \
  gh api -X PUT repos/:owner/:repo/actions/workflows/ci.yml/disable
```

Re-enable after the fix lands:

```bash
gh workflow enable "CI"
```

## Post-incident

- Note bad revision number, bad commit SHA, detection time, rollback time.
- File an issue with logs + service events.
- Do not delete the bad task definition revision — leave it for the postmortem.
