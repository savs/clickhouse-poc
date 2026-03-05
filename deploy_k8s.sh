#!/usr/bin/env bash
# deploy_k8s.sh — Build, push, and deploy the travel-app stack to AWS EKS.
#
# Prerequisites:
#   aws cli, eksctl, kubectl, docker (with buildx), envsubst
#   A .env file with GCLOUD_PDC_SIGNING_TOKEN, GCLOUD_PDC_CLUSTER, GCLOUD_HOSTED_GRAFANA_ID

set -euo pipefail

# ── Flags ─────────────────────────────────────────────────────────────────────
CLEAN=false
PREFIX=""
VERSION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -clean)         CLEAN=true; shift ;;
    -prefix)        PREFIX="$2"; shift 2 ;;
    -version)       VERSION="$2"; shift 2 ;;
    *) echo "✗  Unknown flag: $1" >&2; exit 1 ;;
  esac
done

# ── Configuration ────────────────────────────────────────────────────────────
AWS_PROFILE="grafana-dev"
AWS_REGION="${AWS_REGION:-us-west-2}"
# Prefix the cluster/repo name so AWS resources can be traced back to the owner.
# Usage: ./deploy_k8s.sh -prefix alice
CLUSTER_NAME="${PREFIX:+${PREFIX}-}travel-app"
ECR_REPO="${PREFIX:+${PREFIX}-}travel-app"
NAMESPACE="travel-app"
KUBECTL_CONTEXT="$CLUSTER_NAME"
NODE_TYPE="t3.medium"
NODE_COUNT=2
IMAGE_TAG="${VERSION:-$(git rev-parse --short HEAD)}"

# Custom images that need to be built and pushed to ECR
IMAGES=(grafana hotel-service flight-service booking-service frontend)

# ── Helpers ──────────────────────────────────────────────────────────────────
log()  { echo "▶  $*"; }
ok()   { echo "✓  $*"; }
die()  { echo "✗  $*" >&2; exit 1; }

require() {
  for cmd in "$@"; do
    command -v "$cmd" &>/dev/null || die "Required tool not found: $cmd"
  done
}

# ── Preflight ────────────────────────────────────────────────────────────────
require aws eksctl kubectl docker envsubst

log "Verifying AWS credentials (profile: $AWS_PROFILE)"
AWS_ACCOUNT=$(aws sts get-caller-identity \
  --profile "$AWS_PROFILE" \
  --query Account --output text)
ok "Account: $AWS_ACCOUNT"

export ECR_REGISTRY="${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com"
export ECR_REPO
export IMAGE_TAG

# ── ECR: create single repo if it doesn't exist ──────────────────────────────
log "Ensuring ECR repository exists: $ECR_REPO"
if aws ecr describe-repositories \
     --profile "$AWS_PROFILE" \
     --region  "$AWS_REGION" \
     --repository-names "$ECR_REPO" \
     &>/dev/null; then
  ok "  ECR repo exists: $ECR_REPO"
else
  log "  Creating ECR repo: $ECR_REPO"
  aws ecr create-repository \
    --profile         "$AWS_PROFILE" \
    --region          "$AWS_REGION" \
    --repository-name "$ECR_REPO" \
    --image-scanning-configuration scanOnPush=true \
    --tags "Key=owner,Value=${PREFIX:-shared}" "Key=project,Value=travel-app" \
    --output text --query 'repository.repositoryUri'
  ok "  Created: $ECR_REPO"
fi

# ── Docker: login to ECR ─────────────────────────────────────────────────────
log "Logging in to ECR"
aws ecr get-login-password \
  --profile "$AWS_PROFILE" \
  --region  "$AWS_REGION" \
| docker login \
    --username AWS \
    --password-stdin \
    "${ECR_REGISTRY}"
ok "ECR login successful"

# ── Docker: ensure buildx builder for cross-compilation ─────────────────────
log "Configuring docker buildx (linux/amd64 target for EKS)"
if ! docker buildx inspect travel-app-builder &>/dev/null; then
  docker buildx create --name travel-app-builder --use
fi
docker buildx use travel-app-builder

# ── Docker: build, tag, push each custom image ───────────────────────────────
# Images are tagged as <service>-<version>. If the tag already exists in ECR,
# the build is skipped. Use -version to pin a tag; defaults to git commit hash.
log "Building and pushing images (version: ${IMAGE_TAG})"
for img in "${IMAGES[@]}"; do
  full_uri="${ECR_REGISTRY}/${ECR_REPO}:${img}-${IMAGE_TAG}"
  if aws ecr describe-images \
       --profile        "$AWS_PROFILE" \
       --region         "$AWS_REGION" \
       --repository-name "$ECR_REPO" \
       --image-ids      "imageTag=${img}-${IMAGE_TAG}" \
       &>/dev/null 2>&1; then
    ok "  Already in ECR, skipping build: ${full_uri}"
    continue
  fi
  log "  Building ${img} → ${full_uri}"
  docker buildx build \
    --platform linux/amd64 \
    --push \
    --tag  "${full_uri}" \
    "./${img}"
  ok "  Pushed: ${full_uri}"
done

# ── EKS: optionally delete existing cluster (-clean) then create if needed ────
log "Checking EKS cluster: $CLUSTER_NAME"
CLUSTER_EXISTS=false
if eksctl get cluster \
     --name    "$CLUSTER_NAME" \
     --region  "$AWS_REGION" \
     --profile "$AWS_PROFILE" \
     &>/dev/null; then
  CLUSTER_EXISTS=true
fi

if [ "$CLUSTER_EXISTS" = true ] && [ "$CLEAN" = true ]; then
  log "Deleting cluster: $CLUSTER_NAME (-clean flag set)"

  # Delete the namespace first so the cloud-controller-manager removes ELBs
  # and the EBS CSI driver releases volumes before CloudFormation touches the
  # VPC. Without this, CF waits up to 30 min for stuck subnet/VPC deletion.
  if kubectl --context "$KUBECTL_CONTEXT" get namespace "$NAMESPACE" &>/dev/null 2>&1; then
    log "Deleting namespace $NAMESPACE (releases ELBs and EBS volumes first)"
    kubectl --context "$KUBECTL_CONTEXT" delete namespace "$NAMESPACE" \
      --wait=true --timeout=5m || true
    ok "Namespace deleted"
  fi

  eksctl delete cluster \
    --name    "$CLUSTER_NAME" \
    --region  "$AWS_REGION" \
    --profile "$AWS_PROFILE" \
    --wait \
    --disable-nodegroup-eviction
  ok "Cluster deleted"
  CLUSTER_EXISTS=false

  # Delete the ECR repository and all images inside it
  if aws ecr describe-repositories \
       --profile "$AWS_PROFILE" \
       --region  "$AWS_REGION" \
       --repository-names "$ECR_REPO" \
       &>/dev/null 2>&1; then
    log "Deleting ECR repository: $ECR_REPO"
    aws ecr delete-repository \
      --profile        "$AWS_PROFILE" \
      --region         "$AWS_REGION" \
      --repository-name "$ECR_REPO" \
      --force
    ok "ECR repository deleted: $ECR_REPO"
  fi
fi

if [ "$CLUSTER_EXISTS" = true ]; then
  ok "Cluster already exists"
else
  # Reuse an existing VPC to avoid hitting the AWS VPC/IGW account limits.
  # Prefer the default VPC; fall back to any available VPC in the region.
  log "Looking for an existing VPC to use (avoids AWS VPC limit errors)"
  VPC_ID=$(aws ec2 describe-vpcs \
    --profile "$AWS_PROFILE" \
    --region  "$AWS_REGION" \
    --filters "Name=isDefault,Values=true" \
    --query   "Vpcs[0].VpcId" --output text 2>/dev/null || true)

  if [ -z "$VPC_ID" ] || [ "$VPC_ID" = "None" ]; then
    VPC_ID=$(aws ec2 describe-vpcs \
      --profile "$AWS_PROFILE" \
      --region  "$AWS_REGION" \
      --query   "Vpcs[0].VpcId" --output text 2>/dev/null || true)
  fi

  [ -z "$VPC_ID" ] || [ "$VPC_ID" = "None" ] && \
    die "No VPC found in $AWS_REGION. Create a VPC or free up the VPC quota."

  ok "Using VPC: $VPC_ID"

  # Collect subnet IDs across at least two AZs (EKS requirement).
  # Prefer public subnets (MapPublicIpOnLaunch=true); fall back to all subnets.
  SUBNET_IDS=$(aws ec2 describe-subnets \
    --profile "$AWS_PROFILE" \
    --region  "$AWS_REGION" \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
              "Name=mapPublicIpOnLaunch,Values=true" \
    --query   "Subnets[*].SubnetId" --output text 2>/dev/null | tr '\t' ',' || true)

  if [ -z "$SUBNET_IDS" ]; then
    SUBNET_IDS=$(aws ec2 describe-subnets \
      --profile "$AWS_PROFILE" \
      --region  "$AWS_REGION" \
      --filters "Name=vpc-id,Values=${VPC_ID}" \
      --query   "Subnets[*].SubnetId" --output text 2>/dev/null | tr '\t' ',' || true)
  fi

  [ -z "$SUBNET_IDS" ] && die "No subnets found in VPC $VPC_ID."
  ok "Using subnets: $SUBNET_IDS"

  # If any CF stack with this name exists, delete it before creating.
  # Checking for specific stuck states is insufficient — eksctl delete can leave
  # stacks in DELETE_FAILED or other unlisted states. Unconditionally clearing
  # any pre-existing stack is safer.
  CF_STACK="eksctl-${CLUSTER_NAME}-cluster"
  CF_STATUS=$(aws cloudformation describe-stacks \
    --profile "$AWS_PROFILE" \
    --region  "$AWS_REGION" \
    --stack-name "$CF_STACK" \
    --query "Stacks[0].StackStatus" --output text 2>/dev/null || echo "DOES_NOT_EXIST")

  if [ "$CF_STATUS" != "DOES_NOT_EXIST" ]; then
    log "CF stack '$CF_STACK' exists (state: $CF_STATUS) — removing before re-creating"
    aws cloudformation update-termination-protection \
      --profile                "$AWS_PROFILE" \
      --region                 "$AWS_REGION" \
      --stack-name             "$CF_STACK" \
      --no-enable-termination-protection 2>/dev/null || true
    aws cloudformation delete-stack \
      --profile    "$AWS_PROFILE" \
      --region     "$AWS_REGION" \
      --stack-name "$CF_STACK"
    log "Waiting for stack deletion to complete…"
    aws cloudformation wait stack-delete-complete \
      --profile    "$AWS_PROFILE" \
      --region     "$AWS_REGION" \
      --stack-name "$CF_STACK"
    ok "Stack deleted"
  fi

  log "Creating EKS cluster (this takes ~15 minutes)…"
  eksctl create cluster \
    --name                "$CLUSTER_NAME" \
    --region              "$AWS_REGION" \
    --profile             "$AWS_PROFILE" \
    --node-type           "$NODE_TYPE" \
    --nodes               "$NODE_COUNT" \
    --nodes-min           1 \
    --nodes-max           4 \
    --version             "1.33" \
    --managed \
    --vpc-public-subnets  "$SUBNET_IDS" \
    --tags                "owner=${PREFIX:-shared},project=travel-app"
  ok "Cluster created"

  # ── OIDC provider: required for IRSA (IAM Roles for Service Accounts) ───────
  log "Associating IAM OIDC provider (required for IRSA)…"
  eksctl utils associate-iam-oidc-provider \
    --cluster  "$CLUSTER_NAME" \
    --region   "$AWS_REGION" \
    --profile  "$AWS_PROFILE" \
    --approve
  ok "OIDC provider associated"

  # ── EBS CSI driver: install with IRSA so the controller has EC2 permissions ─
  # Without --attach-policy-arn the controller runs as the node role, which
  # lacks EC2 permissions and crashloops on DescribeAvailabilityZones.
  log "Installing EBS CSI driver addon with IRSA…"
  eksctl create addon \
    --name            aws-ebs-csi-driver \
    --cluster         "$CLUSTER_NAME" \
    --region          "$AWS_REGION" \
    --profile         "$AWS_PROFILE" \
    --attach-policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy \
    --wait
  ok "EBS CSI driver ready"
fi

# ── kubectl: update kubeconfig ───────────────────────────────────────────────
log "Updating kubeconfig (context: $KUBECTL_CONTEXT)"
aws eks update-kubeconfig \
  --name    "$CLUSTER_NAME" \
  --region  "$AWS_REGION" \
  --profile "$AWS_PROFILE" \
  --alias   "$KUBECTL_CONTEXT"
ok "kubectl context set to: $KUBECTL_CONTEXT"

# ── K8s: namespace ───────────────────────────────────────────────────────────
log "Applying namespace"
kubectl --context "$KUBECTL_CONTEXT" apply -f k8s/00-namespace.yaml

# ── K8s: PDC secret from .env ────────────────────────────────────────────────
log "Creating PDC secret from .env"
if [ ! -f .env ]; then
  die ".env file not found — create it with GCLOUD_PDC_SIGNING_TOKEN, GCLOUD_PDC_CLUSTER, GCLOUD_HOSTED_GRAFANA_ID"
fi

# Parse .env (ignore comments and blank lines)
pdc_token=$(grep -E '^GCLOUD_PDC_SIGNING_TOKEN=' .env | cut -d= -f2- | tr -d '"'"'" || true)
pdc_cluster=$(grep -E '^GCLOUD_PDC_CLUSTER=' .env | cut -d= -f2- | tr -d '"'"'" || true)
grafana_id=$(grep -E '^GCLOUD_HOSTED_GRAFANA_ID=' .env | cut -d= -f2- | tr -d '"'"'" || true)

kubectl --context "$KUBECTL_CONTEXT" create secret generic pdc-credentials \
  --namespace "$NAMESPACE" \
  --from-literal="GCLOUD_PDC_SIGNING_TOKEN=${pdc_token}" \
  --from-literal="GCLOUD_PDC_CLUSTER=${pdc_cluster}" \
  --from-literal="GCLOUD_HOSTED_GRAFANA_ID=${grafana_id}" \
  --dry-run=client -o yaml \
| kubectl --context "$KUBECTL_CONTEXT" apply -f -
ok "PDC secret applied"

# ── K8s: apply remaining manifests with ECR_REGISTRY substituted ─────────────
log "Applying Kubernetes manifests"
for manifest in k8s/*.yaml; do
  # 00-namespace.yaml already applied above; skip to avoid duplicate warning
  [[ "$manifest" == "k8s/00-namespace.yaml" ]] && continue
  envsubst < "$manifest" | kubectl --context "$KUBECTL_CONTEXT" apply -f -
done
ok "All manifests applied"

# ── Wait for rollout ──────────────────────────────────────────────────────────
log "Waiting for deployments to be ready"
deployments=(clickhouse otelcol alloy pdc grafana hotel-service flight-service booking-service frontend)
for dep in "${deployments[@]}"; do
  log "  Waiting: $dep"
  kubectl --context "$KUBECTL_CONTEXT" rollout status deployment/"$dep" \
    --namespace "$NAMESPACE" --timeout=25m
done
ok "All deployments ready"

# ── Print endpoints ───────────────────────────────────────────────────────────
log "Fetching LoadBalancer endpoints (may take a minute to provision)"
echo ""
echo "════════════════════════════════════════"
echo "  Travel App — Public Endpoints"
echo "════════════════════════════════════════"

grafana_hostname=""
for svc in frontend grafana; do
  hostname=""
  for i in $(seq 1 20); do
    hostname=$(kubectl --context "$KUBECTL_CONTEXT" get svc "$svc" \
      --namespace "$NAMESPACE" \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
    [ -n "$hostname" ] && break
    sleep 6
  done
  if [ -n "$hostname" ]; then
    echo "  ${svc}: http://${hostname}${svc:+$([ "$svc" = grafana ] && echo ':3000')}"
    [ "$svc" = "grafana" ] && grafana_hostname="$hostname"
  else
    echo "  ${svc}: (pending — run: kubectl get svc ${svc} -n ${NAMESPACE})"
  fi
done
echo "════════════════════════════════════════"

# ── Inject Grafana URL into frontend ─────────────────────────────────────────
if [ -n "$grafana_hostname" ]; then
  log "Setting GRAFANA_URL on frontend deployment"
  kubectl --context "$KUBECTL_CONTEXT" set env deployment/frontend \
    --namespace "$NAMESPACE" \
    GRAFANA_URL="http://${grafana_hostname}:3000"
  kubectl --context "$KUBECTL_CONTEXT" rollout status deployment/frontend \
    --namespace "$NAMESPACE" --timeout=5m
  ok "Frontend updated with Grafana URL: http://${grafana_hostname}:3000"
fi
