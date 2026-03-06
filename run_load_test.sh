#!/usr/bin/env bash
# run_load_test.sh — Run the travel-app k6 load test.
#
# Usage:
#   ./run_load_test.sh -url <frontend-url> [-cloud] [-vus <n>] [-duration <t>]
#
# Flags:
#   -url <url>        Base URL of the frontend, e.g. https://alice.frontend.demo.com
#   -cloud            Run on K6 Cloud instead of locally (uses K6_TOKEN from .env)
#   -vus <n>          Override peak VUs (default: from stages in load-test.js)
#   -duration <t>     Override total duration, e.g. 5m (default: from stages)
#   -script <path>    Path to k6 script (default: load-test.js in same dir)
#
# Credentials are read from .env in the same directory.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
K6_SCRIPT="${SCRIPT_DIR}/load-test.js"

BASE_URL=""
CLOUD=false
EXTRA_ARGS=()

# ── Parse flags ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    -url)      BASE_URL="$2"; shift 2 ;;
    -cloud)    CLOUD=true; shift ;;
    -vus)      EXTRA_ARGS+=(--vus "$2"); shift 2 ;;
    -duration) EXTRA_ARGS+=(--duration "$2"); shift 2 ;;
    -script)   K6_SCRIPT="$2"; shift 2 ;;
    *) echo "✗  Unknown flag: $1" >&2; exit 1 ;;
  esac
done

# ── Validate ──────────────────────────────────────────────────────────────────
if [[ -z "$BASE_URL" ]]; then
  echo "✗  -url is required" >&2
  echo "   Example: ./run_load_test.sh -url https://alice.frontend.demo.com" >&2
  exit 1
fi

if [[ ! -f "$K6_SCRIPT" ]]; then
  echo "✗  Script not found: $K6_SCRIPT" >&2
  exit 1
fi

if ! command -v k6 &>/dev/null; then
  echo "✗  k6 not found. Install with:" >&2
  echo "   brew install k6" >&2
  exit 1
fi

# ── Load credentials from .env ────────────────────────────────────────────────
if [[ ! -f "$ENV_FILE" ]]; then
  echo "✗  .env not found at $ENV_FILE" >&2
  exit 1
fi

FRONTEND_USER=""
FRONTEND_PASSWORD=""
K6_TOKEN=""
K6_CLOUD_PROJECT_ID=""

while IFS='=' read -r key value || [[ -n "$key" ]]; do
  # Skip comments and blank lines
  [[ "$key" =~ ^[[:space:]]*# ]] && continue
  [[ -z "${key// }" ]] && continue
  # Strip inline comments and surrounding whitespace
  key="${key//[[:space:]]/}"
  value="${value%%#*}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  case "$key" in
    FRONTEND_USER)       FRONTEND_USER="$value" ;;
    FRONTEND_PASSWORD)   FRONTEND_PASSWORD="$value" ;;
    K6_TOKEN)            K6_TOKEN="$value" ;;
    K6_CLOUD_PROJECT_ID) K6_CLOUD_PROJECT_ID="$value" ;;
  esac
done < "$ENV_FILE"

if [[ -z "$FRONTEND_USER" || -z "$FRONTEND_PASSWORD" ]]; then
  echo "✗  FRONTEND_USER and FRONTEND_PASSWORD must be set in .env" >&2
  exit 1
fi

if [[ "$CLOUD" = true && -z "$K6_TOKEN" ]]; then
  echo "✗  K6_TOKEN must be set in .env to run in cloud mode" >&2
  exit 1
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo "▶  Travel app load test"
echo "   URL:    $BASE_URL"
echo "   User:   $FRONTEND_USER"
echo "   Mode:   $([ "$CLOUD" = true ] && echo "K6 Cloud (project $K6_CLOUD_PROJECT_ID)" || echo "local")"
echo "   Script: $K6_SCRIPT"
[[ ${#EXTRA_ARGS[@]} -gt 0 ]] && echo "   Extra:  ${EXTRA_ARGS[*]}"
echo ""

# ── Run ───────────────────────────────────────────────────────────────────────
export BASE_URL
export FRONTEND_USER
export FRONTEND_PASSWORD

if [[ "$CLOUD" = true ]]; then
  export K6_CLOUD_TOKEN="$K6_TOKEN"
  [[ -n "$K6_CLOUD_PROJECT_ID" ]] && export K6_CLOUD_PROJECT_ID
  k6 cloud ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} "$K6_SCRIPT"
else
  k6 run ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} "$K6_SCRIPT"
fi
