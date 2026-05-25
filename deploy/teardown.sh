#!/usr/bin/env bash
#
# teardown.sh
#
# Reverse manual-deploy.sh in dependency-safe order to avoid orphaned
# resources and unexpected charges. Idempotent - missing resources are skipped.
#
set -euo pipefail

export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

REGION="${REGION:-us-east-1}"
PROJECT_NAME="${PROJECT_NAME:-aws-healthcheck}"
AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

CLUSTER_NAME="${PROJECT_NAME}"
SERVICE_NAME="${PROJECT_NAME}-svc"
TASK_FAMILY="${PROJECT_NAME}-task"
EXEC_ROLE_NAME="${PROJECT_NAME}-ecs-execution"
LOG_GROUP="/ecs/${PROJECT_NAME}"
ALB_NAME="${PROJECT_NAME}-alb"
TG_NAME="${PROJECT_NAME}-tg"
ALB_SG_NAME="${PROJECT_NAME}-alb-sg"
TASK_SG_NAME="${PROJECT_NAME}-task-sg"

section() { echo ""; echo "=============================================================="; echo "  $*"; echo "=============================================================="; }
info()    { echo "  -> $*"; }

# ---------------------------------------------------------------------------
# 1. ECS service (scale to 0, delete)
# ---------------------------------------------------------------------------
section "1/8 - ECS service"
if aws ecs describe-services --region "${REGION}" --cluster "${CLUSTER_NAME}" \
    --services "${SERVICE_NAME}" --query 'services[0].status' --output text 2>/dev/null \
    | grep -q ACTIVE; then
  info "Scaling service to 0"
  aws ecs update-service --region "${REGION}" \
    --cluster "${CLUSTER_NAME}" --service "${SERVICE_NAME}" \
    --desired-count 0 >/dev/null
  info "Deleting service"
  aws ecs delete-service --region "${REGION}" \
    --cluster "${CLUSTER_NAME}" --service "${SERVICE_NAME}" --force >/dev/null
  info "Waiting for service to drain"
  aws ecs wait services-inactive --region "${REGION}" \
    --cluster "${CLUSTER_NAME}" --services "${SERVICE_NAME}" || true
else
  info "Service not present - skipping"
fi

# ---------------------------------------------------------------------------
# 2. ALB listener + ALB + target group (listener first, then LB, then TG)
# ---------------------------------------------------------------------------
section "2/8 - ALB, listener, target group"
ALB_ARN="$(aws elbv2 describe-load-balancers --region "${REGION}" --names "${ALB_NAME}" \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || echo "None")"

if [[ "${ALB_ARN}" != "None" && -n "${ALB_ARN}" ]]; then
  for L in $(aws elbv2 describe-listeners --region "${REGION}" \
      --load-balancer-arn "${ALB_ARN}" --query 'Listeners[].ListenerArn' --output text 2>/dev/null); do
    info "Deleting listener ${L}"
    aws elbv2 delete-listener --region "${REGION}" --listener-arn "${L}" >/dev/null
  done
  info "Deleting ALB"
  aws elbv2 delete-load-balancer --region "${REGION}" --load-balancer-arn "${ALB_ARN}" >/dev/null
  info "Waiting for ALB to be gone (needed before SG delete)"
  aws elbv2 wait load-balancers-deleted --region "${REGION}" --load-balancer-arns "${ALB_ARN}" || true
else
  info "ALB not present"
fi

TG_ARN="$(aws elbv2 describe-target-groups --region "${REGION}" --names "${TG_NAME}" \
  --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || echo "None")"
if [[ "${TG_ARN}" != "None" && -n "${TG_ARN}" ]]; then
  info "Deleting target group"
  aws elbv2 delete-target-group --region "${REGION}" --target-group-arn "${TG_ARN}" >/dev/null
else
  info "Target group not present"
fi

# ---------------------------------------------------------------------------
# 3. Security groups (task SG depends on ALB SG via ingress rule)
# ---------------------------------------------------------------------------
section "3/8 - Security groups"
VPC_ID="$(aws ec2 describe-vpcs --region "${REGION}" --filters Name=is-default,Values=true \
  --query 'Vpcs[0].VpcId' --output text)"

for SG_NAME in "${TASK_SG_NAME}" "${ALB_SG_NAME}"; do
  SG_ID="$(aws ec2 describe-security-groups --region "${REGION}" \
    --filters "Name=group-name,Values=${SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")"
  if [[ "${SG_ID}" != "None" && -n "${SG_ID}" ]]; then
    info "Deleting SG ${SG_NAME} (${SG_ID})"
    # Retry: ENIs from the deleted ALB/tasks may still be detaching
    for i in {1..10}; do
      if aws ec2 delete-security-group --region "${REGION}" --group-id "${SG_ID}" 2>/dev/null; then
        break
      fi
      echo "  ... SG still in use, retrying (${i}/10)"
      sleep 6
    done
  else
    info "SG ${SG_NAME} not present"
  fi
done

# ---------------------------------------------------------------------------
# 4. Task definitions (deregister all revisions)
# ---------------------------------------------------------------------------
section "4/8 - Task definition revisions"
for ARN in $(aws ecs list-task-definitions --region "${REGION}" \
    --family-prefix "${TASK_FAMILY}" --status ACTIVE --query 'taskDefinitionArns[]' --output text); do
  info "Deregistering ${ARN}"
  aws ecs deregister-task-definition --region "${REGION}" --task-definition "${ARN}" >/dev/null
done

# ---------------------------------------------------------------------------
# 5. ECS cluster
# ---------------------------------------------------------------------------
section "5/8 - ECS cluster"
if aws ecs describe-clusters --region "${REGION}" --clusters "${CLUSTER_NAME}" \
    --query 'clusters[0].status' --output text 2>/dev/null | grep -q ACTIVE; then
  info "Deleting cluster"
  aws ecs delete-cluster --region "${REGION}" --cluster "${CLUSTER_NAME}" >/dev/null
else
  info "Cluster not present"
fi

# ---------------------------------------------------------------------------
# 6. IAM role
# ---------------------------------------------------------------------------
section "6/8 - IAM execution role"
if aws iam get-role --role-name "${EXEC_ROLE_NAME}" >/dev/null 2>&1; then
  info "Detaching managed policies"
  for P in $(aws iam list-attached-role-policies --role-name "${EXEC_ROLE_NAME}" \
      --query 'AttachedPolicies[].PolicyArn' --output text); do
    aws iam detach-role-policy --role-name "${EXEC_ROLE_NAME}" --policy-arn "${P}" >/dev/null
  done
  info "Deleting role"
  aws iam delete-role --role-name "${EXEC_ROLE_NAME}" >/dev/null
else
  info "Role not present"
fi

# ---------------------------------------------------------------------------
# 7. CloudWatch log group
# ---------------------------------------------------------------------------
section "7/8 - CloudWatch log group"
if aws logs describe-log-groups --region "${REGION}" --log-group-name-prefix "${LOG_GROUP}" \
    --query "logGroups[?logGroupName=='${LOG_GROUP}'] | [0]" --output text 2>/dev/null | grep -q "${LOG_GROUP}"; then
  info "Deleting log group"
  aws logs delete-log-group --region "${REGION}" --log-group-name "${LOG_GROUP}" >/dev/null
else
  info "Log group not present"
fi

# ---------------------------------------------------------------------------
# 8. ECR repo (force-delete with images)
# ---------------------------------------------------------------------------
section "8/8 - ECR repository"
if aws ecr describe-repositories --region "${REGION}" --repository-names "${PROJECT_NAME}" >/dev/null 2>&1; then
  info "Deleting ECR repo (and all images)"
  aws ecr delete-repository --region "${REGION}" \
    --repository-name "${PROJECT_NAME}" --force >/dev/null
else
  info "ECR repo not present"
fi

section "TEARDOWN COMPLETE"
