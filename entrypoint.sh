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
#    ${INTERNAL_SECRET}    — shared secret for HLS key endpoint protection
##############################################################################
set -euo pipefail

log() { echo "[entrypoint] $*"; }

# ── Validate required env vars before doing anything ─────────────────────────
# FIX: Original had no validation — if any of these are missing, envsubst
# silently writes an empty string into nginx.conf, nginx starts with a broken
# config, and the failure is very hard to trace.
: "${STREAM_AUTH_URL:?ERROR: STREAM_AUTH_URL is not set}"
: "${VIDYARO_APP_DOMAIN:?ERROR: VIDYARO_APP_DOMAIN is not set}"
: "${INTERNAL_SECRET:?ERROR: INTERNAL_SECRET is not set}"

# ── Save full environment for recorder.sh ─────────────────────────────────────
# recorder.sh sources /etc/nginx/.env as a fallback for local dev.
# In production Docker, vars are already injected — this is just the safety net.
log "Saving environment to /etc/nginx/.env..."
printenv > /etc/nginx/.env
# FIX: Lock down permissions — this file contains R2 keys, Appwrite API key,
# and INTERNAL_SECRET. Should not be world-readable inside the container.
chmod 600 /etc/nginx/.env

# ── Render nginx.conf from template ──────────────────────────────────────────
log "Rendering nginx.conf from template..."
# FIX: Explicit variable whitelist passed to envsubst — without the whitelist,
# envsubst replaces ALL $VARIABLE patterns in the template including nginx
# variables like $name, $binary_remote_addr, $request_method, $invalid_referer
# etc., breaking the entire nginx config silently.
envsubst '${STREAM_AUTH_URL} ${VIDYARO_APP_DOMAIN} ${INTERNAL_SECRET}' \
    < /etc/nginx/nginx.conf.template \
    > /etc/nginx/nginx.conf

# ── Validate rendered config ──────────────────────────────────────────────────
log "Validating nginx config..."
nginx -t

# ── Start nginx ───────────────────────────────────────────────────────────────
log "Starting nginx..."
exec nginx -g 'daemon off;'
