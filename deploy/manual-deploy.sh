#!/usr/bin/env bash
#
# manual-deploy.sh
#
# Manually deploy the aws-healthcheck Flask app to AWS using:
#   ECR -> ECS Fargate -> ALB
#
# Idempotent: safe to re-run. Every resource is checked before being created.
# Requires: aws CLI v2, docker, jq, git.
#
set -euo pipefail

# Prevent Git Bash / MSYS on Windows from rewriting leading-slash args
# (e.g. /ecs/foo, /health) into C:/Program Files/Git/... paths.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
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
CONTAINER_PORT=5000

ECR_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${PROJECT_NAME}"
GIT_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo "manual-$(date +%s)")"

# Resolve repo root (script lives in deploy/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

section() { echo ""; echo "=============================================================="; echo "  $*"; echo "=============================================================="; }
info()    { echo "  -> $*"; }
fail()    { echo "ERROR: $*" >&2; exit 1; }

section "Config"
info "Region:          ${REGION}"
info "Account:         ${AWS_ACCOUNT_ID}"
info "Project:         ${PROJECT_NAME}"
info "Image:           ${ECR_URI}:${GIT_SHA}"

# ---------------------------------------------------------------------------
# STEP 1 - ECR setup
# ---------------------------------------------------------------------------
section "STEP 1 - ECR repository + image push"

if aws ecr describe-repositories --region "${REGION}" --repository-names "${PROJECT_NAME}" >/dev/null 2>&1; then
  info "ECR repo '${PROJECT_NAME}' already exists"
else
  info "Creating ECR repo '${PROJECT_NAME}'"
  aws ecr create-repository \
    --region "${REGION}" \
    --repository-name "${PROJECT_NAME}" \
    --image-scanning-configuration scanOnPush=true >/dev/null
fi

info "Authenticating docker to ECR"
aws ecr get-login-password --region "${REGION}" \
  | docker login --username AWS --password-stdin "${AWS_ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

info "Building image"
( cd "${REPO_DIR}" && docker build -t "${PROJECT_NAME}:${GIT_SHA}" . )

info "Tagging and pushing :${GIT_SHA} and :latest"
docker tag "${PROJECT_NAME}:${GIT_SHA}" "${ECR_URI}:${GIT_SHA}"
docker tag "${PROJECT_NAME}:${GIT_SHA}" "${ECR_URI}:latest"
docker push "${ECR_URI}:${GIT_SHA}"
docker push "${ECR_URI}:latest"

# ---------------------------------------------------------------------------
# STEP 2 - ECS cluster
# ---------------------------------------------------------------------------
section "STEP 2 - ECS cluster"

CLUSTER_STATUS="$(aws ecs describe-clusters --region "${REGION}" --clusters "${CLUSTER_NAME}" \
  --query 'clusters[0].status' --output text 2>/dev/null || echo "MISSING")"

if [[ "${CLUSTER_STATUS}" == "ACTIVE" ]]; then
  info "Cluster '${CLUSTER_NAME}' already ACTIVE"
else
  info "Creating cluster '${CLUSTER_NAME}'"
  aws ecs create-cluster \
    --region "${REGION}" \
    --cluster-name "${CLUSTER_NAME}" \
    --capacity-providers FARGATE \
    --default-capacity-provider-strategy capacityProvider=FARGATE,weight=1 >/dev/null
fi

# ---------------------------------------------------------------------------
# STEP 3 - IAM execution role
# ---------------------------------------------------------------------------
section "STEP 3 - IAM task execution role"

if aws iam get-role --role-name "${EXEC_ROLE_NAME}" >/dev/null 2>&1; then
  info "Role '${EXEC_ROLE_NAME}' already exists"
else
  info "Creating role '${EXEC_ROLE_NAME}'"
  TRUST_DOC='{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"Service": "ecs-tasks.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }]
  }'
  aws iam create-role \
    --role-name "${EXEC_ROLE_NAME}" \
    --assume-role-policy-document "${TRUST_DOC}" >/dev/null
fi

info "Attaching AmazonECSTaskExecutionRolePolicy"
aws iam attach-role-policy \
  --role-name "${EXEC_ROLE_NAME}" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy >/dev/null || true

EXEC_ROLE_ARN="$(aws iam get-role --role-name "${EXEC_ROLE_NAME}" --query 'Role.Arn' --output text)"
info "Execution role ARN: ${EXEC_ROLE_ARN}"

# ---------------------------------------------------------------------------
# STEP 4 - CloudWatch log group
# ---------------------------------------------------------------------------
section "STEP 4 - CloudWatch log group"

if aws logs describe-log-groups --region "${REGION}" --log-group-name-prefix "${LOG_GROUP}" \
    --query "logGroups[?logGroupName=='${LOG_GROUP}'] | [0]" --output text | grep -q "${LOG_GROUP}"; then
  info "Log group '${LOG_GROUP}' already exists"
else
  info "Creating log group '${LOG_GROUP}'"
  aws logs create-log-group --region "${REGION}" --log-group-name "${LOG_GROUP}" >/dev/null
fi

info "Setting 7-day retention"
aws logs put-retention-policy --region "${REGION}" \
  --log-group-name "${LOG_GROUP}" --retention-in-days 7 >/dev/null

# ---------------------------------------------------------------------------
# STEP 5 - Task definition
# ---------------------------------------------------------------------------
section "STEP 5 - ECS task definition"

TASK_DEF_JSON="$(cat <<EOF
{
  "family": "${TASK_FAMILY}",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "256",
  "memory": "512",
  "executionRoleArn": "${EXEC_ROLE_ARN}",
  "containerDefinitions": [{
    "name": "${PROJECT_NAME}",
    "image": "${ECR_URI}:${GIT_SHA}",
    "essential": true,
    "portMappings": [{"containerPort": ${CONTAINER_PORT}, "protocol": "tcp"}],
    "environment": [
      {"name": "FLASK_ENV", "value": "production"},
      {"name": "FLASK_PORT", "value": "${CONTAINER_PORT}"},
      {"name": "AWS_REGION", "value": "${REGION}"},
      {"name": "DEFAULT_TARGETS", "value": "${DEFAULT_TARGETS:-https://www.google.com,https://aws.amazon.com}"}
    ],
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-group": "${LOG_GROUP}",
        "awslogs-region": "${REGION}",
        "awslogs-stream-prefix": "ecs"
      }
    }
  }]
}
EOF
)"

info "Registering task definition family '${TASK_FAMILY}'"
TASK_DEF_ARN="$(aws ecs register-task-definition \
  --region "${REGION}" \
  --cli-input-json "${TASK_DEF_JSON}" \
  --query 'taskDefinition.taskDefinitionArn' --output text)"
info "Task def: ${TASK_DEF_ARN}"

# ---------------------------------------------------------------------------
# STEP 6 - ALB + target group
# ---------------------------------------------------------------------------
section "STEP 6 - ALB, target group, security groups"

VPC_ID="$(aws ec2 describe-vpcs --region "${REGION}" --filters Name=is-default,Values=true \
  --query 'Vpcs[0].VpcId' --output text)"
[[ "${VPC_ID}" == "None" || -z "${VPC_ID}" ]] && fail "No default VPC found in ${REGION}"
info "Using default VPC: ${VPC_ID}"

SUBNET_IDS="$(aws ec2 describe-subnets --region "${REGION}" \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=default-for-az,Values=true" \
  --query 'Subnets[].SubnetId' --output text)"
SUBNET_CSV="$(echo "${SUBNET_IDS}" | tr '\t' ',')"
info "Subnets: ${SUBNET_CSV}"

# ALB security group
ALB_SG_ID="$(aws ec2 describe-security-groups --region "${REGION}" \
  --filters "Name=group-name,Values=${ALB_SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")"
if [[ "${ALB_SG_ID}" == "None" || -z "${ALB_SG_ID}" ]]; then
  info "Creating ALB SG '${ALB_SG_NAME}'"
  ALB_SG_ID="$(aws ec2 create-security-group --region "${REGION}" \
    --group-name "${ALB_SG_NAME}" \
    --description "ALB SG for ${PROJECT_NAME}" \
    --vpc-id "${VPC_ID}" --query 'GroupId' --output text)"
  aws ec2 authorize-security-group-ingress --region "${REGION}" \
    --group-id "${ALB_SG_ID}" --protocol tcp --port 80 --cidr 0.0.0.0/0 >/dev/null
else
  info "ALB SG already exists: ${ALB_SG_ID}"
fi

# Task security group
TASK_SG_ID="$(aws ec2 describe-security-groups --region "${REGION}" \
  --filters "Name=group-name,Values=${TASK_SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")"
if [[ "${TASK_SG_ID}" == "None" || -z "${TASK_SG_ID}" ]]; then
  info "Creating Task SG '${TASK_SG_NAME}'"
  TASK_SG_ID="$(aws ec2 create-security-group --region "${REGION}" \
    --group-name "${TASK_SG_NAME}" \
    --description "Task SG for ${PROJECT_NAME}" \
    --vpc-id "${VPC_ID}" --query 'GroupId' --output text)"
  aws ec2 authorize-security-group-ingress --region "${REGION}" \
    --group-id "${TASK_SG_ID}" --protocol tcp --port "${CONTAINER_PORT}" \
    --source-group "${ALB_SG_ID}" >/dev/null
else
  info "Task SG already exists: ${TASK_SG_ID}"
fi

# ALB
ALB_ARN="$(aws elbv2 describe-load-balancers --region "${REGION}" --names "${ALB_NAME}" \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || echo "None")"
if [[ "${ALB_ARN}" == "None" || -z "${ALB_ARN}" ]]; then
  info "Creating ALB '${ALB_NAME}'"
  ALB_ARN="$(aws elbv2 create-load-balancer --region "${REGION}" \
    --name "${ALB_NAME}" --type application --scheme internet-facing \
    --security-groups "${ALB_SG_ID}" \
    --subnets ${SUBNET_IDS} \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text)"
else
  info "ALB already exists"
fi

# Target group
TG_ARN="$(aws elbv2 describe-target-groups --region "${REGION}" --names "${TG_NAME}" \
  --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || echo "None")"
if [[ "${TG_ARN}" == "None" || -z "${TG_ARN}" ]]; then
  info "Creating target group '${TG_NAME}'"
  TG_ARN="$(aws elbv2 create-target-group --region "${REGION}" \
    --name "${TG_NAME}" --protocol HTTP --port "${CONTAINER_PORT}" \
    --vpc-id "${VPC_ID}" --target-type ip \
    --health-check-protocol HTTP --health-check-path /health \
    --health-check-interval-seconds 15 --healthy-threshold-count 2 \
    --query 'TargetGroups[0].TargetGroupArn' --output text)"
else
  info "Target group already exists"
fi

# HTTP listener
LISTENER_ARN="$(aws elbv2 describe-listeners --region "${REGION}" \
  --load-balancer-arn "${ALB_ARN}" \
  --query "Listeners[?Port==\`80\`] | [0].ListenerArn" --output text 2>/dev/null || echo "None")"
if [[ "${LISTENER_ARN}" == "None" || -z "${LISTENER_ARN}" ]]; then
  info "Creating HTTP listener on :80"
  aws elbv2 create-listener --region "${REGION}" \
    --load-balancer-arn "${ALB_ARN}" \
    --protocol HTTP --port 80 \
    --default-actions "Type=forward,TargetGroupArn=${TG_ARN}" >/dev/null
else
  info "Listener already exists"
fi

# ---------------------------------------------------------------------------
# STEP 7 - ECS service
# ---------------------------------------------------------------------------
section "STEP 7 - ECS service"

SERVICE_STATUS="$(aws ecs describe-services --region "${REGION}" \
  --cluster "${CLUSTER_NAME}" --services "${SERVICE_NAME}" \
  --query 'services[0].status' --output text 2>/dev/null || echo "MISSING")"

NETWORK_CFG="awsvpcConfiguration={subnets=[${SUBNET_CSV}],securityGroups=[${TASK_SG_ID}],assignPublicIp=ENABLED}"

if [[ "${SERVICE_STATUS}" == "ACTIVE" ]]; then
  info "Service exists - updating with new task definition"
  aws ecs update-service --region "${REGION}" \
    --cluster "${CLUSTER_NAME}" --service "${SERVICE_NAME}" \
    --task-definition "${TASK_DEF_ARN}" \
    --desired-count 1 >/dev/null
else
  info "Creating service '${SERVICE_NAME}'"
  aws ecs create-service --region "${REGION}" \
    --cluster "${CLUSTER_NAME}" \
    --service-name "${SERVICE_NAME}" \
    --task-definition "${TASK_DEF_ARN}" \
    --desired-count 1 \
    --launch-type FARGATE \
    --network-configuration "${NETWORK_CFG}" \
    --load-balancers "targetGroupArn=${TG_ARN},containerName=${PROJECT_NAME},containerPort=${CONTAINER_PORT}" >/dev/null
fi

# ---------------------------------------------------------------------------
# STEP 8 - Wait + verify
# ---------------------------------------------------------------------------
section "STEP 8 - Wait for steady state + verify"

info "Waiting for service to stabilize (this can take a few minutes)"
aws ecs wait services-stable --region "${REGION}" \
  --cluster "${CLUSTER_NAME}" --services "${SERVICE_NAME}"

ALB_DNS="$(aws elbv2 describe-load-balancers --region "${REGION}" \
  --load-balancer-arns "${ALB_ARN}" \
  --query 'LoadBalancers[0].DNSName' --output text)"

info "ALB DNS: ${ALB_DNS}"
info "Probing http://${ALB_DNS}/health"

# Retry briefly while ALB target health flips healthy
for i in {1..20}; do
  if RESP="$(curl -fsS "http://${ALB_DNS}/health" 2>/dev/null)"; then
    echo ""
    echo "Health response: ${RESP}"
    if echo "${RESP}" | grep -q '"status":"ok"'; then
      section "DEPLOY SUCCESSFUL"
      echo "URL: http://${ALB_DNS}/"
      exit 0
    fi
  fi
  echo "  ... waiting for healthy target (attempt ${i}/20)"
  sleep 6
done

fail "Service stabilized but /health did not return status=ok within timeout"
