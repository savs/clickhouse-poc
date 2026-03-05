#!/usr/bin/env bash
# deploy_k8s.sh — Build, push, and deploy the travel-app stack to AWS EKS.
#
# Prerequisites:
#   aws cli, eksctl, kubectl, docker (with buildx), envsubst
#   A .env file with GCLOUD_PDC_SIGNING_TOKEN, GCLOUD_PDC_CLUSTER, GCLOUD_HOSTED_GRAFANA_ID

set -euo pipefail

# ── Flags ─────────────────────────────────────────────────────────────────────
CLEAN=false
REBUILD=false
PREFIX=""
VERSION=""
DOMAIN=""
AWS_PROFILE="grafana-dev"   # default; override with -profile
while [[ $# -gt 0 ]]; do
  case "$1" in
    -clean)         CLEAN=true; shift ;;
    -rebuild)       REBUILD=true; shift ;;
    -prefix)        PREFIX="$2"; shift 2 ;;
    -version)       VERSION="$2"; shift 2 ;;
    -domain)        DOMAIN="$2"; shift 2 ;;
    -profile)       AWS_PROFILE="$2"; shift 2 ;;
    *) echo "✗  Unknown flag: $1" >&2; exit 1 ;;
  esac
done

# ── Configuration ────────────────────────────────────────────────────────────
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
require aws eksctl kubectl istioctl docker envsubst

log "Verifying AWS credentials (profile: $AWS_PROFILE)"
AWS_ACCOUNT=$(aws sts get-caller-identity \
  --profile "$AWS_PROFILE" \
  --query Account --output text)
ok "Account: $AWS_ACCOUNT"

export ECR_REGISTRY="${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com"
export ECR_REPO
export IMAGE_TAG
export CLUSTER_NAME
export AWS_REGION
export HOSTNAME_PREFIX="${PREFIX:+${PREFIX}-}"   # e.g. "alice-" or ""
[ -z "$DOMAIN" ] && die "Missing required flag: -domain <your-domain.com>"
export DNS_DOMAIN="$DOMAIN"

# ── DNS: verify hosted zone exists in Route 53 ───────────────────────────────
log "Verifying Route 53 hosted zone: $DNS_DOMAIN"
HOSTED_ZONE_ID=$(aws route53 list-hosted-zones \
  --profile "$AWS_PROFILE" \
  --query   "HostedZones[?Name=='${DNS_DOMAIN}.'].Id" \
  --output  text 2>/dev/null || true)

if [ -z "$HOSTED_ZONE_ID" ] || [ "$HOSTED_ZONE_ID" = "None" ]; then
  echo ""
  echo "✗  Route 53 hosted zone not found for '$DNS_DOMAIN'." >&2
  echo "" >&2
  echo "   To set it up:" >&2
  echo "" >&2
  echo "   1. Register or transfer the domain to Route 53:" >&2
  echo "      https://console.aws.amazon.com/route53/home#DomainListing:" >&2
  echo "" >&2
  echo "   2. If the domain is registered elsewhere, create a public hosted zone:" >&2
  echo "      aws route53 create-hosted-zone \\" >&2
  echo "        --profile $AWS_PROFILE \\" >&2
  echo "        --name $DNS_DOMAIN \\" >&2
  echo "        --caller-reference \$(date +%s)" >&2
  echo "" >&2
  echo "   3. Copy the NS records from the hosted zone and add them as NS records" >&2
  echo "      at your domain registrar so Route 53 becomes the authoritative DNS." >&2
  echo "" >&2
  echo "   4. Re-run this script once the hosted zone is in place." >&2
  echo "" >&2
  exit 1
fi
ok "Hosted zone found: $HOSTED_ZONE_ID"
# cert-manager expects the zone ID without the /hostedzone/ prefix
HOSTED_ZONE_ID_SHORT="${HOSTED_ZONE_ID#/hostedzone/}"
export HOSTED_ZONE_ID_SHORT

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

# Detect uncommitted/unstaged local changes. Only matters when IMAGE_TAG is
# derived from the git HEAD hash — if the user passed -version, they're
# explicitly pinning a tag and may intentionally be reusing it.
GIT_DIRTY=false
GIT_CHANGED_FILES=""
if [ -z "$VERSION" ] && ! git diff --quiet HEAD 2>/dev/null; then
  GIT_DIRTY=true
  GIT_CHANGED_FILES=$(git diff --name-only HEAD 2>/dev/null)
fi
STALE_WARNING_SHOWN=false

for img in "${IMAGES[@]}"; do
  full_uri="${ECR_REGISTRY}/${ECR_REPO}:${img}-${IMAGE_TAG}"
  if [ "$REBUILD" = false ] && aws ecr describe-images \
       --profile        "$AWS_PROFILE" \
       --region         "$AWS_REGION" \
       --repository-name "$ECR_REPO" \
       --image-ids      "imageTag=${img}-${IMAGE_TAG}" \
       &>/dev/null 2>&1; then
    ok "  Already in ECR, skipping build: ${full_uri}"
    # Warn once if local changes exist that won't be in the deployed image.
    # The tag matches the current git HEAD, but the working tree has drifted,
    # so the image in ECR was built from an earlier state of the code.
    if [ "$GIT_DIRTY" = true ] && [ "$STALE_WARNING_SHOWN" = false ]; then
      STALE_WARNING_SHOWN=true
      echo "" >&2
      echo "⚠   STALE IMAGE WARNING" >&2
      echo "    ECR already has images tagged '${IMAGE_TAG}' (current git HEAD)," >&2
      echo "    but your working tree has uncommitted changes. The images that" >&2
      echo "    will be deployed do NOT include these local modifications:" >&2
      echo "" >&2
      echo "$GIT_CHANGED_FILES" | while IFS= read -r f; do echo "      • $f" >&2; done
      echo "" >&2
      echo "    To deploy your local changes, commit them first:" >&2
      echo "      git add -A && git commit -m 'your message'" >&2
      echo "      ./deploy_k8s.sh [same flags]" >&2
      echo "" >&2
      echo "    Or force a rebuild under a new tag:" >&2
      echo "      ./deploy_k8s.sh -version <new-tag> [same flags]" >&2
      echo "" >&2
      printf "    Continuing in 5 s… (Ctrl-C to abort)" >&2
      for _i in 1 2 3 4 5; do sleep 1; printf " ." >&2; done
      echo "" >&2
      echo "" >&2
    fi
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

  # Delete cert-manager IAM policy
  CERT_MANAGER_POLICY_ARN=$(aws iam list-policies \
    --profile "$AWS_PROFILE" \
    --query   "Policies[?PolicyName=='CertManager-${CLUSTER_NAME}'].Arn" \
    --output  text 2>/dev/null || true)
  if [ -n "$CERT_MANAGER_POLICY_ARN" ] && [ "$CERT_MANAGER_POLICY_ARN" != "None" ]; then
    log "Deleting cert-manager IAM policy"
    aws iam delete-policy \
      --profile    "$AWS_PROFILE" \
      --policy-arn "$CERT_MANAGER_POLICY_ARN"
    ok "cert-manager IAM policy deleted"
  fi

  # Delete External-DNS IAM policy (not managed by eksctl, must be removed manually)
  EXTERNAL_DNS_POLICY_ARN=$(aws iam list-policies \
    --profile "$AWS_PROFILE" \
    --query   "Policies[?PolicyName=='ExternalDNS-${CLUSTER_NAME}'].Arn" \
    --output  text 2>/dev/null || true)
  if [ -n "$EXTERNAL_DNS_POLICY_ARN" ] && [ "$EXTERNAL_DNS_POLICY_ARN" != "None" ]; then
    log "Deleting External-DNS IAM policy"
    aws iam delete-policy \
      --profile    "$AWS_PROFILE" \
      --policy-arn "$EXTERNAL_DNS_POLICY_ARN"
    ok "External-DNS IAM policy deleted"
  fi

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

  # ── EKS Access Entry: grant the caller cluster-admin via the Access Entries API ─
  # eksctl adds the creator to aws-auth, but SSO roles (with their /aws-reserved/
  # path) are sometimes rejected. Using the Access Entries API is more reliable
  # and works regardless of the aws-auth ConfigMap state.
  log "Granting cluster-admin access to caller IAM role via EKS Access Entries…"
  CALLER_ARN=$(aws sts get-caller-identity \
    --profile "$AWS_PROFILE" --query Arn --output text)
  # Convert assumed-role STS ARN → IAM role ARN (strips session suffix, fixes path)
  ROLE_NAME=$(echo "$CALLER_ARN" | sed 's|.*assumed-role/||;s|/.*||')
  ROLE_ARN=$(aws iam get-role \
    --profile "$AWS_PROFILE" \
    --role-name "$ROLE_NAME" \
    --query 'Role.Arn' --output text 2>/dev/null || true)
  if [ -n "$ROLE_ARN" ] && [ "$ROLE_ARN" != "None" ]; then
    aws eks create-access-entry \
      --profile      "$AWS_PROFILE" \
      --region       "$AWS_REGION" \
      --cluster-name "$CLUSTER_NAME" \
      --principal-arn "$ROLE_ARN" \
      --type STANDARD 2>/dev/null || true   # ignore if entry already exists
    aws eks associate-access-policy \
      --profile      "$AWS_PROFILE" \
      --region       "$AWS_REGION" \
      --cluster-name "$CLUSTER_NAME" \
      --principal-arn "$ROLE_ARN" \
      --policy-arn   arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
      --access-scope type=cluster
    ok "Cluster-admin access granted to $ROLE_ARN"
  else
    log "Caller is not an assumed role (IAM user?) — skipping Access Entry"
  fi

fi

# ── kubectl: update kubeconfig ───────────────────────────────────────────────
log "Updating kubeconfig (context: $KUBECTL_CONTEXT)"
aws eks update-kubeconfig \
  --name    "$CLUSTER_NAME" \
  --region  "$AWS_REGION" \
  --profile "$AWS_PROFILE" \
  --alias   "$KUBECTL_CONTEXT"
ok "kubectl context set to: $KUBECTL_CONTEXT"

# Verify kubectl can reach the cluster before proceeding.
# EKS exec credential plugins can take a few seconds to exchange tokens on
# first use — retry until auth succeeds rather than failing immediately.
log "Verifying kubectl connectivity…"
for i in $(seq 1 12); do
  if kubectl --context "$KUBECTL_CONTEXT" auth can-i '*' '*' --all-namespaces &>/dev/null; then
    ok "kubectl connectivity verified"
    break
  fi
  [ "$i" -eq 12 ] && die "kubectl cannot authenticate to cluster after 60 s — run: aws sso login --profile $AWS_PROFILE"
  sleep 5
done

# ── External-DNS: IAM policy + IRSA service account (idempotent) ─────────────
# Runs every deploy so adding External-DNS to an existing cluster works too.
log "Ensuring External-DNS IAM policy exists…"
EXTERNAL_DNS_POLICY_ARN=$(aws iam list-policies \
  --profile "$AWS_PROFILE" \
  --query   "Policies[?PolicyName=='ExternalDNS-${CLUSTER_NAME}'].Arn" \
  --output  text 2>/dev/null || true)
if [ -z "$EXTERNAL_DNS_POLICY_ARN" ] || [ "$EXTERNAL_DNS_POLICY_ARN" = "None" ]; then
  EXTERNAL_DNS_POLICY_ARN=$(aws iam create-policy \
    --profile      "$AWS_PROFILE" \
    --policy-name  "ExternalDNS-${CLUSTER_NAME}" \
    --policy-document '{
      "Version": "2012-10-17",
      "Statement": [
        {
          "Effect": "Allow",
          "Action": ["route53:ChangeResourceRecordSets"],
          "Resource": ["arn:aws:route53:::hostedzone/*"]
        },
        {
          "Effect": "Allow",
          "Action": ["route53:ListHostedZones","route53:ListResourceRecordSets","route53:ListTagsForResource"],
          "Resource": ["*"]
        }
      ]
    }' \
    --query 'Policy.Arn' --output text)
fi
ok "External-DNS IAM policy: $EXTERNAL_DNS_POLICY_ARN"

log "Ensuring External-DNS IRSA service account exists…"
eksctl create iamserviceaccount \
  --name            external-dns \
  --namespace       kube-system \
  --cluster         "$CLUSTER_NAME" \
  --region          "$AWS_REGION" \
  --profile         "$AWS_PROFILE" \
  --attach-policy-arn "$EXTERNAL_DNS_POLICY_ARN" \
  --approve \
  --override-existing-serviceaccounts
ok "External-DNS service account ready"

# ── cert-manager: IAM policy + IRSA (no kubectl needed here) ─────────────────
log "Ensuring cert-manager IAM policy exists…"
CERT_MANAGER_POLICY_ARN=$(aws iam list-policies \
  --profile "$AWS_PROFILE" \
  --query   "Policies[?PolicyName=='CertManager-${CLUSTER_NAME}'].Arn" \
  --output  text 2>/dev/null || true)
if [ -z "$CERT_MANAGER_POLICY_ARN" ] || [ "$CERT_MANAGER_POLICY_ARN" = "None" ]; then
  CERT_MANAGER_POLICY_ARN=$(aws iam create-policy \
    --profile     "$AWS_PROFILE" \
    --policy-name "CertManager-${CLUSTER_NAME}" \
    --policy-document '{
      "Version": "2012-10-17",
      "Statement": [
        {
          "Effect": "Allow",
          "Action": "route53:GetChange",
          "Resource": "arn:aws:route53:::change/*"
        },
        {
          "Effect": "Allow",
          "Action": [
            "route53:ChangeResourceRecordSets",
            "route53:ListResourceRecordSets"
          ],
          "Resource": "arn:aws:route53:::hostedzone/*"
        },
        {
          "Effect": "Allow",
          "Action": "route53:ListHostedZonesByName",
          "Resource": "*"
        }
      ]
    }' \
    --query 'Policy.Arn' --output text)
fi
ok "cert-manager IAM policy: $CERT_MANAGER_POLICY_ARN"

log "Ensuring cert-manager IRSA service account…"
eksctl create iamserviceaccount \
  --name            cert-manager \
  --namespace       cert-manager \
  --cluster         "$CLUSTER_NAME" \
  --region          "$AWS_REGION" \
  --profile         "$AWS_PROFILE" \
  --attach-policy-arn "$CERT_MANAGER_POLICY_ARN" \
  --approve \
  --override-existing-serviceaccounts
ok "cert-manager IAM + IRSA prepared"

# ── Istio: install service mesh (idempotent) ──────────────────────────────────
log "Installing Istio service mesh…"
istioctl install -f istio-operator.yaml --context "$KUBECTL_CONTEXT" -y
ok "Istio installed"

# ── K8s: namespace ───────────────────────────────────────────────────────────
log "Applying namespace"
kubectl --context "$KUBECTL_CONTEXT" apply -f k8s/00-namespace.yaml

# Label for automatic sidecar injection before any pods are created
kubectl --context "$KUBECTL_CONTEXT" label namespace "$NAMESPACE" \
  istio-injection=enabled --overwrite
ok "Namespace labeled for Istio sidecar injection"

# ── cert-manager: install CRDs + wait + restart controller with IRSA ─────────
# Done here (after namespace) so kubectl auth is already confirmed working.
log "Installing cert-manager (Let's Encrypt TLS)"
kubectl --context "$KUBECTL_CONTEXT" apply --validate=false \
  -f https://github.com/cert-manager/cert-manager/releases/download/v1.16.2/cert-manager.yaml
log "Waiting for cert-manager webhook to be ready…"
kubectl --context "$KUBECTL_CONTEXT" wait \
  --for=condition=Available deployment/cert-manager-webhook \
  --namespace cert-manager --timeout=5m
ok "cert-manager ready"
log "Restarting cert-manager controller to load IRSA credentials…"
kubectl --context "$KUBECTL_CONTEXT" rollout restart deployment/cert-manager \
  --namespace cert-manager
kubectl --context "$KUBECTL_CONTEXT" rollout status deployment/cert-manager \
  --namespace cert-manager --timeout=3m
ok "cert-manager IRSA ready"

# ── K8s: PDC secret from .env ────────────────────────────────────────────────
log "Creating PDC secret from .env"
if [ ! -f .env ]; then
  die ".env file not found — create it with GCLOUD_PDC_SIGNING_TOKEN, GCLOUD_PDC_CLUSTER, GCLOUD_HOSTED_GRAFANA_ID"
fi

# Parse .env (ignore comments and blank lines)
pdc_token=$(grep -E '^GCLOUD_PDC_SIGNING_TOKEN=' .env | cut -d= -f2- | tr -d '"'"'" || true)
pdc_cluster=$(grep -E '^GCLOUD_PDC_CLUSTER=' .env | cut -d= -f2- | tr -d '"'"'" || true)
grafana_id=$(grep -E '^GCLOUD_HOSTED_GRAFANA_ID=' .env | cut -d= -f2- | tr -d '"'"'" || true)
CERT_EMAIL=$(grep -E '^CERT_EMAIL=' .env | cut -d= -f2- | tr -d '"'"'" || true)
[ -z "$CERT_EMAIL" ] && die ".env is missing CERT_EMAIL (required for Let's Encrypt)"
export CERT_EMAIL

kubectl --context "$KUBECTL_CONTEXT" create secret generic pdc-credentials \
  --namespace "$NAMESPACE" \
  --from-literal="GCLOUD_PDC_SIGNING_TOKEN=${pdc_token}" \
  --from-literal="GCLOUD_PDC_CLUSTER=${pdc_cluster}" \
  --from-literal="GCLOUD_HOSTED_GRAFANA_ID=${grafana_id}" \
  --dry-run=client -o yaml \
| kubectl --context "$KUBECTL_CONTEXT" apply -f -
ok "PDC secret applied"

# ── K8s: frontend basic-auth credentials from .env ────────────────────────────
log "Creating frontend-credentials secret from .env"
frontend_user=$(grep -E '^FRONTEND_USER=' .env | cut -d= -f2- | tr -d '"'"'" || true)
frontend_password=$(grep -E '^FRONTEND_PASSWORD=' .env | cut -d= -f2- | tr -d '"'"'" || true)
[ -z "$frontend_user" ]     && die ".env is missing FRONTEND_USER"
[ -z "$frontend_password" ] && die ".env is missing FRONTEND_PASSWORD"

kubectl --context "$KUBECTL_CONTEXT" create secret generic frontend-credentials \
  --namespace "$NAMESPACE" \
  --from-literal="username=${frontend_user}" \
  --from-literal="password=${frontend_password}" \
  --dry-run=client -o yaml \
| kubectl --context "$KUBECTL_CONTEXT" apply -f -
ok "Frontend credentials secret applied"

# ── K8s: pre-generate nginx htpasswd ─────────────────────────────────────────
# openssl is not installed in nginx:alpine, so generating the hash inside the
# container at startup silently fails and produces an empty password entry.
# Pre-compute the APR1 hash here (where openssl is available) and store it as
# a secret mounted directly at /etc/nginx/.htpasswd in all nginx containers.
log "Creating nginx-htpasswd secret"
HTPASSWD_ENTRY="${frontend_user}:$(openssl passwd -apr1 "${frontend_password}")"
kubectl --context "$KUBECTL_CONTEXT" create secret generic nginx-htpasswd \
  --namespace "$NAMESPACE" \
  --from-literal=".htpasswd=${HTPASSWD_ENTRY}" \
  --dry-run=client -o yaml \
| kubectl --context "$KUBECTL_CONTEXT" apply -f -
ok "nginx-htpasswd secret applied"

# ── K8s: apply remaining manifests ───────────────────────────────────────────
# Use explicit variable list so nginx-config ConfigMaps aren't broken by
# envsubst substituting nginx variables like $host or $remote_addr.
log "Applying Kubernetes manifests"
ENVSUBST_VARS='${ECR_REGISTRY} ${ECR_REPO} ${IMAGE_TAG} ${HOSTNAME_PREFIX} ${DNS_DOMAIN} ${AWS_REGION} ${CLUSTER_NAME} ${CERT_EMAIL} ${HOSTED_ZONE_ID_SHORT}'
for manifest in k8s/*.yaml; do
  # 00-namespace.yaml already applied above; skip to avoid duplicate warning
  [[ "$manifest" == "k8s/00-namespace.yaml" ]] && continue
  envsubst "$ENVSUBST_VARS" < "$manifest" | kubectl --context "$KUBECTL_CONTEXT" apply -f -
done
ok "All manifests applied"

# ── Istio: restart pods that don't yet have the sidecar injected ──────────────
# On first deploy the namespace was labeled before pods were created, so sidecars
# are already present. On re-deploy to an existing cluster that didn't have Istio,
# a rolling restart is needed to inject the sidecar into existing pods.
if kubectl --context "$KUBECTL_CONTEXT" get pods -n "$NAMESPACE" \
     -o jsonpath='{.items[*].spec.containers[*].name}' 2>/dev/null \
   | tr ' ' '\n' | grep -q 'istio-proxy'; then
  ok "Istio sidecars already present"
else
  log "Restarting deployments to inject Istio sidecars…"
  kubectl --context "$KUBECTL_CONTEXT" rollout restart deployment \
    --namespace "$NAMESPACE"
fi

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

# Collect LB hostnames (poll until provisioned, up to ~2 min each)
get_hostname() {
  local svc="$1"
  local hostname=""
  for i in $(seq 1 20); do
    hostname=$(kubectl --context "$KUBECTL_CONTEXT" get svc "$svc" \
      --namespace "$NAMESPACE" \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
    [ -n "$hostname" ] && echo "$hostname" && return
    sleep 6
  done
}

# ── Inject Grafana URL into frontend using persistent DNS hostname ────────────
# Use the DNS name immediately — External-DNS will have it live within seconds.
GRAFANA_DNS="https://${HOSTNAME_PREFIX}grafana.${DNS_DOMAIN}"
log "Setting GRAFANA_URL on frontend deployment: $GRAFANA_DNS"
kubectl --context "$KUBECTL_CONTEXT" set env deployment/frontend \
  --namespace "$NAMESPACE" \
  GRAFANA_URL="$GRAFANA_DNS"
kubectl --context "$KUBECTL_CONTEXT" rollout status deployment/frontend \
  --namespace "$NAMESPACE" --timeout=5m

# ── Final summary ─────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════"
echo "  Travel App — deployed to $CLUSTER_NAME"
echo "════════════════════════════════════════════════════════"
echo "  Frontend  →  https://${HOSTNAME_PREFIX}frontend.${DNS_DOMAIN}"
echo "  Grafana   →  https://${HOSTNAME_PREFIX}grafana.${DNS_DOMAIN}"
echo "  Alloy UI  →  https://${HOSTNAME_PREFIX}alloy.${DNS_DOMAIN}"
echo ""
echo "  DNS records are managed by External-DNS and may take"
echo "  up to 60 seconds to propagate on first deploy."
echo ""
echo "  TLS certificates are issued by Let's Encrypt via cert-manager."
echo "  On first deploy certificate issuance may take 2–5 minutes."
echo "════════════════════════════════════════════════════════"
