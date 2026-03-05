#!/bin/sh
set -e

# ── Basic auth: write htpasswd file from env vars ────────────────────────────
if [ -z "$FRONTEND_USER" ] || [ -z "$FRONTEND_PASSWORD" ]; then
  echo "ERROR: FRONTEND_USER and FRONTEND_PASSWORD must be set" >&2
  exit 1
fi
printf '%s:%s\n' \
  "$FRONTEND_USER" \
  "$(openssl passwd -apr1 "$FRONTEND_PASSWORD")" \
  > /etc/nginx/.htpasswd

# ── TLS cert: use real cert if available, otherwise generate a placeholder ────
# nginx cannot start without a certificate. The cert-manager Secret may not
# exist yet on first deploy (DNS-01 issuance takes 2-5 min). A temporary
# self-signed cert lets nginx start immediately so the HTTP→HTTPS redirect
# (port 80) works right away. The reload loop below picks up the real cert.
mkdir -p /etc/nginx/ssl-live
if [ -f /etc/nginx/ssl/tls.crt ]; then
  cp /etc/nginx/ssl/tls.crt /etc/nginx/ssl-live/tls.crt
  cp /etc/nginx/ssl/tls.key /etc/nginx/ssl-live/tls.key
else
  echo "INFO: TLS secret not yet available — starting with a temporary self-signed cert" >&2
  openssl req -x509 -newkey rsa:2048 \
    -keyout /etc/nginx/ssl-live/tls.key \
    -out    /etc/nginx/ssl-live/tls.crt \
    -days   1 -nodes -subj "/CN=placeholder"
fi

# ── Runtime config: substitute env vars into index.html ──────────────────────
envsubst '$GRAFANA_URL' < /usr/share/nginx/html/index.html.tmpl \
                        > /usr/share/nginx/html/index.html

# ── Background: watch for cert updates and reload nginx ──────────────────────
# Kubernetes updates secret volume mounts automatically when the Secret changes.
# nginx must be reloaded to pick up the new files. Check every 60 s so the
# real cert is picked up within 1 minute of issuance, and future renewals
# (cert-manager renews ~30 days before expiry) are applied automatically.
(
  while true; do
    sleep 60
    if [ -f /etc/nginx/ssl/tls.crt ]; then
      if ! diff -q /etc/nginx/ssl/tls.crt /etc/nginx/ssl-live/tls.crt > /dev/null 2>&1; then
        cp /etc/nginx/ssl/tls.crt /etc/nginx/ssl-live/tls.crt
        cp /etc/nginx/ssl/tls.key /etc/nginx/ssl-live/tls.key
        nginx -s reload 2>/dev/null || true
        echo "INFO: TLS certificate updated and nginx reloaded" >&2
      fi
    fi
  done
) &

exec nginx -g 'daemon off;'
