#!/usr/bin/env bash
# fault_inject.sh — Inject Istio faults into the travel-app for demo/testing.
#
# Usage:
#   ./fault_inject.sh <scenario> [-prefix <name>]
#
# Scenarios:
#   slow-hotels      50% of hotel searches get a 3s delay
#   flaky-flights    25% of flight searches return 503
#   checkout-chaos   booking-service: 20% slow (2s) + 10% errors (503)
#   total-outage     booking-service returns 503 for all requests
#   cascading        hotel-service slow (2s) + flight-service errors — booking times out
#   clear            remove all injected faults
#   status           show which faults are currently active
#
# Flags:
#   -prefix <name>   cluster name prefix, same as deploy_k8s.sh (default: none)
#
# Examples:
#   ./fault_inject.sh slow-hotels -prefix alice
#   ./fault_inject.sh clear -prefix alice

set -euo pipefail

NAMESPACE="travel-app"
PREFIX=""

# ── Parse args ────────────────────────────────────────────────────────────────
SCENARIO="${1:-}"
shift || true

while [[ $# -gt 0 ]]; do
  case "$1" in
    -prefix) PREFIX="$2"; shift 2 ;;
    *) echo "✗  Unknown flag: $1" >&2; exit 1 ;;
  esac
done

CLUSTER_NAME="${PREFIX:+${PREFIX}-}travel-app"
KUBECTL_CONTEXT="$CLUSTER_NAME"
export AWS_PROFILE="$CLUSTER_NAME"
KCT=(kubectl --context "$KUBECTL_CONTEXT" -n "$NAMESPACE")

# ── Helpers ───────────────────────────────────────────────────────────────────
log() { echo "▶  $*"; }
ok()  { echo "✓  $*"; }
die() { echo "✗  $*" >&2; exit 1; }

apply_vs() {
  local name="$1"; shift
  local yaml="$1"
  echo "$yaml" | "${KCT[@]}" apply -f -
  ok "VirtualService '$name' applied"
}

delete_vs() {
  local name="$1"
  if "${KCT[@]}" get virtualservice "$name" &>/dev/null; then
    "${KCT[@]}" delete virtualservice "$name"
    ok "VirtualService '$name' removed"
  fi
}

# ── Scenario definitions ──────────────────────────────────────────────────────

scenario_slow_hotels() {
  log "Injecting 3s delay on 50% of hotel-service requests"
  apply_vs "fault-slow-hotels" "$(cat <<'EOF'
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: fault-slow-hotels
  namespace: travel-app
spec:
  hosts: [hotel-service]
  http:
    - fault:
        delay:
          percentage:
            value: 50
          fixedDelay: 3s
      route:
        - destination:
            host: hotel-service
            port:
              number: 3001
EOF
)"
}

scenario_flaky_flights() {
  log "Injecting 503 on 25% of flight-service requests"
  apply_vs "fault-flaky-flights" "$(cat <<'EOF'
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: fault-flaky-flights
  namespace: travel-app
spec:
  hosts: [flight-service]
  http:
    - fault:
        abort:
          percentage:
            value: 25
          httpStatus: 503
      route:
        - destination:
            host: flight-service
            port:
              number: 3002
EOF
)"
}

scenario_checkout_chaos() {
  log "Injecting 20% slow (2s) + 10% errors (503) on booking-service"
  apply_vs "fault-checkout-chaos" "$(cat <<'EOF'
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: fault-checkout-chaos
  namespace: travel-app
spec:
  hosts: [booking-service]
  http:
    - fault:
        delay:
          percentage:
            value: 20
          fixedDelay: 2s
        abort:
          percentage:
            value: 10
          httpStatus: 503
      route:
        - destination:
            host: booking-service
            port:
              number: 4000
EOF
)"
}

scenario_total_outage() {
  log "Injecting 100% 503 on booking-service (total checkout outage)"
  apply_vs "fault-total-outage" "$(cat <<'EOF'
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: fault-total-outage
  namespace: travel-app
spec:
  hosts: [booking-service]
  http:
    - fault:
        abort:
          percentage:
            value: 100
          httpStatus: 503
      route:
        - destination:
            host: booking-service
            port:
              number: 4000
EOF
)"
}

scenario_cascading() {
  log "Injecting cascading failure: hotel-service slow (2s, 75%) + flight-service errors (40%)"
  log "booking-service will time out trying to aggregate results"
  apply_vs "fault-slow-hotels" "$(cat <<'EOF'
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: fault-slow-hotels
  namespace: travel-app
spec:
  hosts: [hotel-service]
  http:
    - fault:
        delay:
          percentage:
            value: 75
          fixedDelay: 2s
      route:
        - destination:
            host: hotel-service
            port:
              number: 3001
EOF
)"
  apply_vs "fault-flaky-flights" "$(cat <<'EOF'
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: fault-flaky-flights
  namespace: travel-app
spec:
  hosts: [flight-service]
  http:
    - fault:
        abort:
          percentage:
            value: 40
          httpStatus: 503
      route:
        - destination:
            host: flight-service
            port:
              number: 3002
EOF
)"
}

scenario_clear() {
  log "Removing all injected faults"
  for name in fault-slow-hotels fault-flaky-flights fault-checkout-chaos fault-total-outage; do
    delete_vs "$name"
  done
  ok "All faults cleared"
}

scenario_status() {
  echo ""
  echo "Active fault VirtualServices in namespace '$NAMESPACE':"
  echo ""
  local found=false
  for name in fault-slow-hotels fault-flaky-flights fault-checkout-chaos fault-total-outage; do
    if "${KCT[@]}" get virtualservice "$name" &>/dev/null; then
      found=true
      echo "  ● $name"
      "${KCT[@]}" get virtualservice "$name" -o jsonpath='    {.spec.http[0].fault}' | \
        python3 -c "import sys,json; d=json.load(sys.stdin); \
          delay=d.get('delay',{}); abort=d.get('abort',{}); \
          parts=[]; \
          delay and parts.append(f\"{delay['percentage']['value']}% delayed {delay['fixedDelay']}\"); \
          abort and parts.append(f\"{abort['percentage']['value']}% aborted HTTP {abort['httpStatus']}\"); \
          print('   ', ' + '.join(parts))" 2>/dev/null || true
      echo ""
    fi
  done
  if [[ "$found" = false ]]; then
    echo "  (none — all services running normally)"
    echo ""
  fi
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
case "$SCENARIO" in
  slow-hotels)     scenario_slow_hotels ;;
  flaky-flights)   scenario_flaky_flights ;;
  checkout-chaos)  scenario_checkout_chaos ;;
  total-outage)    scenario_total_outage ;;
  cascading)       scenario_cascading ;;
  clear)           scenario_clear ;;
  status)          scenario_status ;;
  "")
    echo "Usage: ./fault_inject.sh <scenario> [-prefix <name>]"
    echo ""
    echo "Scenarios:"
    echo "  slow-hotels      50% of hotel searches delayed 3s"
    echo "  flaky-flights    25% of flight searches return 503"
    echo "  checkout-chaos   booking-service: 20% slow + 10% errors"
    echo "  total-outage     booking-service 100% down"
    echo "  cascading        hotel slow + flights failing → booking timeouts"
    echo "  clear            remove all injected faults"
    echo "  status           show which faults are active"
    exit 1
    ;;
  *) die "Unknown scenario: $SCENARIO. Run without arguments for usage." ;;
esac
