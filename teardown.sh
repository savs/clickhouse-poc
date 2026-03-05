#!/usr/bin/env bash
# teardown.sh — Delete all AWS resources created by deploy_k8s.sh.
#
# Usage:
#   ./teardown.sh -domain <domain> [-prefix <prefix>] [-profile <aws-profile>]
#
# What gets deleted:
#   - travel-app Kubernetes namespace (releases ELBs and EBS volumes first)
#   - Route 53 DNS records created by External-DNS
#   - EKS cluster (and associated CloudFormation stacks, node groups, IRSA stacks)
#   - IAM policies: ExternalDNS-<cluster> and CertManager-<cluster>
#   - ECR repository and all images
#   - Local kubeconfig context

set -euo pipefail

# ── Flags ─────────────────────────────────────────────────────────────────────
PREFIX=""
DOMAIN=""
AWS_PROFILE="grafana-dev"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -prefix)   PREFIX="$2"; shift 2 ;;
    -domain)   DOMAIN="$2"; shift 2 ;;
    -profile)  AWS_PROFILE="$2"; shift 2 ;;
    *) echo "✗  Unknown flag: $1" >&2; exit 1 ;;
  esac
done

[ -z "$DOMAIN" ] && { echo "✗  Missing required flag: -domain <your-domain.com>" >&2; exit 1; }

# ── Configuration ─────────────────────────────────────────────────────────────
AWS_REGION="${AWS_REGION:-us-west-2}"
CLUSTER_NAME="${PREFIX:+${PREFIX}-}travel-app"
ECR_REPO="${PREFIX:+${PREFIX}-}travel-app"
DNS_DOMAIN="$DOMAIN"
HOSTNAME_PREFIX="${PREFIX:+${PREFIX}-}"
KUBECTL_CONTEXT="$CLUSTER_NAME"

# ── Helpers ───────────────────────────────────────────────────────────────────
log()  { echo "▶  $*"; }
ok()   { echo "✓  $*"; }
warn() { echo "⚠  $*" >&2; }
skip() { echo "–  $*"; }

# ── Confirm ───────────────────────────────────────────────────────────────────
echo ""
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║              TEARDOWN — DESTRUCTIVE ACTION           ║"
echo "  ╚══════════════════════════════════════════════════════╝"
echo ""
echo "  This will permanently delete:"
echo "    EKS cluster     : $CLUSTER_NAME  (${AWS_REGION})"
echo "    ECR repository  : $ECR_REPO      (all images)"
echo "    DNS records     : *.${DNS_DOMAIN}"
echo "    IAM policies    : ExternalDNS-${CLUSTER_NAME}"
echo "                      CertManager-${CLUSTER_NAME}"
echo ""
read -r -p "  Type the cluster name to confirm: " CONFIRM
if [ "$CONFIRM" != "$CLUSTER_NAME" ]; then
  echo "✗  Confirmation mismatch — aborting" >&2
  exit 1
fi
echo ""

# ── AWS credentials ───────────────────────────────────────────────────────────
log "Verifying AWS credentials (profile: $AWS_PROFILE)"
AWS_ACCOUNT=$(aws sts get-caller-identity \
  --profile "$AWS_PROFILE" --query Account --output text)
ok "Account: $AWS_ACCOUNT"

ECR_REGISTRY="${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com"

# ── Hosted zone ───────────────────────────────────────────────────────────────
HOSTED_ZONE_ID=$(aws route53 list-hosted-zones \
  --profile "$AWS_PROFILE" \
  --query "HostedZones[?Name=='${DNS_DOMAIN}.'].Id" \
  --output text 2>/dev/null || true)
HOSTED_ZONE_ID_SHORT="${HOSTED_ZONE_ID#/hostedzone/}"

# ── Step 1: delete Kubernetes namespace first ─────────────────────────────────
# Deleting the namespace before the cluster lets the cloud-controller-manager
# deprovision ELBs and the EBS CSI driver release volumes. Without this,
# CloudFormation spends up to 30 min waiting for stuck VPC dependencies.
CLUSTER_EXISTS=false
if aws eks describe-cluster \
     --name "$CLUSTER_NAME" \
     --region "$AWS_REGION" \
     --profile "$AWS_PROFILE" \
     &>/dev/null 2>&1; then
  CLUSTER_EXISTS=true
else
  # Cluster not found — list any travel-app clusters and give a helpful hint
  AVAILABLE=$(aws eks list-clusters \
    --profile "$AWS_PROFILE" \
    --region  "$AWS_REGION" \
    --query   "clusters[?contains(@, 'travel-app')]" \
    --output  text 2>/dev/null || true)
  if [ -n "$AVAILABLE" ]; then
    echo "" >&2
    echo "✗  Cluster '$CLUSTER_NAME' not found." >&2
    echo "" >&2
    echo "   Available travel-app clusters in $AWS_REGION:" >&2
    for c in $AVAILABLE; do
      PREFIX_HINT="${c%-travel-app}"
      if [ "$PREFIX_HINT" = "travel-app" ]; then
        echo "     $c  →  ./teardown.sh -domain $DOMAIN" >&2
      else
        echo "     $c  →  ./teardown.sh -domain $DOMAIN -prefix $PREFIX_HINT" >&2
      fi
    done
    echo "" >&2
    exit 1
  fi
fi

if [ "$CLUSTER_EXISTS" = true ]; then
  log "Updating kubeconfig (context: $KUBECTL_CONTEXT)"
  aws eks update-kubeconfig \
    --name    "$CLUSTER_NAME" \
    --region  "$AWS_REGION" \
    --profile "$AWS_PROFILE" \
    --alias   "$KUBECTL_CONTEXT" 2>/dev/null || true

  if kubectl --context "$KUBECTL_CONTEXT" auth can-i '*' '*' \
       --all-namespaces &>/dev/null 2>&1; then

    # Delete the app namespace first — releases ELBs and EBS volumes so the
    # cloud-controller-manager can clean them up before the cluster is removed.
    if kubectl --context "$KUBECTL_CONTEXT" \
         get namespace travel-app &>/dev/null 2>&1; then
      log "Deleting travel-app namespace (releases ELBs and EBS volumes)"
      kubectl --context "$KUBECTL_CONTEXT" delete namespace travel-app \
        --wait=true --timeout=10m \
        || warn "Namespace deletion timed out — ELBs may still be terminating"
      ok "Namespace travel-app deleted"
    else
      skip "Namespace travel-app not found"
    fi

    # Stop External-DNS so it doesn't try to reconcile during teardown
    if kubectl --context "$KUBECTL_CONTEXT" \
         get deployment external-dns -n kube-system &>/dev/null 2>&1; then
      log "Stopping External-DNS"
      kubectl --context "$KUBECTL_CONTEXT" \
        delete deployment external-dns -n kube-system --wait=false
      ok "External-DNS stopped"
    fi

    # Delete cert-manager and istio-system namespaces — no LoadBalancer services
    # so no ELB dependency, but doing it now lets pods terminate gracefully and
    # makes eksctl cluster deletion faster.
    for ns in cert-manager istio-system; do
      if kubectl --context "$KUBECTL_CONTEXT" \
           get namespace "$ns" &>/dev/null 2>&1; then
        log "Deleting namespace: $ns"
        kubectl --context "$KUBECTL_CONTEXT" delete namespace "$ns" --wait=false
        ok "Namespace $ns deletion initiated"
      else
        skip "Namespace $ns not found"
      fi
    done

  else
    warn "kubectl cannot authenticate — skipping namespace deletion"
    warn "ELBs/EBS volumes may need manual cleanup before cluster deletion completes"
  fi
else
  skip "Cluster $CLUSTER_NAME not found — skipping namespace deletion"
fi

# ── Step 2: delete Route 53 records created by External-DNS ───────────────────
if [ -z "$HOSTED_ZONE_ID_SHORT" ] || [ "$HOSTED_ZONE_ID_SHORT" = "None" ]; then
  warn "Route 53 hosted zone not found for $DNS_DOMAIN — skipping DNS cleanup"
else
  log "Cleaning up Route 53 records for *.$DNS_DOMAIN"

  if ! command -v jq &>/dev/null; then
    warn "jq not found — skipping Route 53 cleanup; delete these records manually:"
    for svc in frontend grafana alloy; do
      warn "  ${HOSTNAME_PREFIX}${svc}.${DNS_DOMAIN}"
    done
  else
    for svc in frontend grafana alloy; do
      HOSTNAME="${HOSTNAME_PREFIX}${svc}.${DNS_DOMAIN}"

      # External-DNS creates the service record plus TXT ownership records.
      # The TXT record may be at the same name or prefixed with "txt-".
      RECORDS=$(aws route53 list-resource-record-sets \
        --profile        "$AWS_PROFILE" \
        --hosted-zone-id "$HOSTED_ZONE_ID_SHORT" \
        --query \
          "ResourceRecordSets[?Name=='${HOSTNAME}.' || Name=='txt-${HOSTNAME}.']" \
        --output json 2>/dev/null || echo "[]")

      COUNT=$(echo "$RECORDS" | jq 'length')
      if [ "$COUNT" -eq 0 ]; then
        skip "  No DNS records for $HOSTNAME"
        continue
      fi

      CHANGE_BATCH=$(echo "$RECORDS" | jq \
        '{Comment:"Teardown",Changes:[.[]|{Action:"DELETE",ResourceRecordSet:.}]}')

      aws route53 change-resource-record-sets \
        --profile        "$AWS_PROFILE" \
        --hosted-zone-id "$HOSTED_ZONE_ID_SHORT" \
        --change-batch   "$CHANGE_BATCH" \
        --output text --query 'ChangeInfo.Id' > /dev/null
      ok "  Deleted $COUNT record(s) for $HOSTNAME"
    done
  fi
fi

# ── Step 3: delete EKS cluster ────────────────────────────────────────────────
if [ "$CLUSTER_EXISTS" = true ]; then
  log "Deleting EKS cluster: $CLUSTER_NAME (this takes ~10 minutes)"
  eksctl delete cluster \
    --name    "$CLUSTER_NAME" \
    --region  "$AWS_REGION" \
    --profile "$AWS_PROFILE" \
    --wait \
    --disable-nodegroup-eviction
  ok "Cluster deleted"
else
  skip "Cluster $CLUSTER_NAME not found"
fi

# ── Step 4: delete IAM policies ───────────────────────────────────────────────
for policy_name in "ExternalDNS-${CLUSTER_NAME}" "CertManager-${CLUSTER_NAME}"; do
  POLICY_ARN=$(aws iam list-policies \
    --profile "$AWS_PROFILE" \
    --query   "Policies[?PolicyName=='${policy_name}'].Arn" \
    --output  text 2>/dev/null || true)
  if [ -n "$POLICY_ARN" ] && [ "$POLICY_ARN" != "None" ]; then
    log "Deleting IAM policy: $policy_name"
    aws iam delete-policy \
      --profile    "$AWS_PROFILE" \
      --policy-arn "$POLICY_ARN"
    ok "Deleted: $policy_name"
  else
    skip "IAM policy not found: $policy_name"
  fi
done

# ── Step 5: delete ECR repository ─────────────────────────────────────────────
if aws ecr describe-repositories \
     --profile          "$AWS_PROFILE" \
     --region           "$AWS_REGION" \
     --repository-names "$ECR_REPO" \
     &>/dev/null 2>&1; then
  log "Deleting ECR repository: $ECR_REPO (all images)"
  aws ecr delete-repository \
    --profile         "$AWS_PROFILE" \
    --region          "$AWS_REGION" \
    --repository-name "$ECR_REPO" \
    --force
  ok "Deleted ECR repository: $ECR_REPO"
else
  skip "ECR repository not found: $ECR_REPO"
fi

# ── Step 6: remove local kubeconfig context ───────────────────────────────────
log "Removing local kubeconfig context: $KUBECTL_CONTEXT"
kubectl config delete-context "$KUBECTL_CONTEXT" 2>/dev/null \
  && ok "Removed kubectl context: $KUBECTL_CONTEXT" \
  || skip "kubectl context not found: $KUBECTL_CONTEXT"

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════"
echo "  Teardown complete: $CLUSTER_NAME"
echo "════════════════════════════════════════════════════════"
