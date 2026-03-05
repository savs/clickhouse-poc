#!/bin/sh
# Substitute $GRAFANA_URL into index.html at container startup, then start nginx.
envsubst '$GRAFANA_URL' < /usr/share/nginx/html/index.html.tmpl \
                        > /usr/share/nginx/html/index.html
exec nginx -g 'daemon off;'
