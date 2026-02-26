#!/usr/bin/env bash
##############################################################################
#  entrypoint.sh
#
#  Renders nginx.conf from its template (substituting env vars),
#  validates the config, then starts nginx in the foreground.
#
#  Variables substituted:
#    ${STREAM_AUTH_URL}    — e.g. https://vidyaro.com/api/stream-auth
#    ${VIDYARO_APP_DOMAIN} — e.g. vidyaro.com
##############################################################################
set -euo pipefail

log() { echo "[entrypoint] $*"; }

log "Rendering nginx.conf from template..."
envsubst '${STREAM_AUTH_URL} ${VIDYARO_APP_DOMAIN} ${INTERNAL_SECRET}' \
    < /etc/nginx/nginx.conf.template \
    > /etc/nginx/nginx.conf

log "Validating nginx config..."
nginx -t

log "Starting nginx..."
exec nginx -g 'daemon off;'
