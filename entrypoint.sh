#!/usr/bin/env bash
##############################################################################
#  entrypoint.sh
#
#  Renders nginx.conf from its template (substituting env vars),
#  validates the config, then starts nginx in the foreground.
#
#  Variables substituted:
#    ${STREAM_AUTH_URL}             — NO LONGER USED in nginx.conf (kept for
#                                     recorder.sh / webhook use only)
#    ${VIDYARO_APP_DOMAIN}          — e.g. vidyaro.com
#    ${VIDYARO_APP_INTERNAL_HOST}   — e.g. ywcggc0ocwwgc8g8wsg4gs84-150317765250:3000
#    ${INTERNAL_SECRET}             — shared secret for HLS key endpoint
##############################################################################
set -euo pipefail

log() { echo "[entrypoint] $*"; }

# ── Validate required env vars before doing anything ─────────────────────────
: "${VIDYARO_APP_DOMAIN:?ERROR: VIDYARO_APP_DOMAIN is not set}"
: "${VIDYARO_APP_INTERNAL_HOST:?ERROR: VIDYARO_APP_INTERNAL_HOST is not set}"
: "${INTERNAL_SECRET:?ERROR: INTERNAL_SECRET is not set}"

# ── Save full environment for recorder.sh ─────────────────────────────────────
log "Saving environment to /etc/nginx/.env..."
printenv > /etc/nginx/.env
chmod 600 /etc/nginx/.env

# ── Render nginx.conf from template ──────────────────────────────────────────
log "Rendering nginx.conf from template..."
# Explicit whitelist — prevents envsubst from destroying nginx variables like
# $name, $binary_remote_addr, $request_method, $invalid_referer etc.
envsubst '${VIDYARO_APP_DOMAIN} ${VIDYARO_APP_INTERNAL_HOST} ${INTERNAL_SECRET}' \
    < /etc/nginx/nginx.conf.template \
    > /etc/nginx/nginx.conf

# ── Validate rendered config ──────────────────────────────────────────────────
log "Validating nginx config..."
nginx -t

# ── Start nginx ───────────────────────────────────────────────────────────────
log "Starting nginx..."
exec nginx -g 'daemon off;'
