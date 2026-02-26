##############################################################################
#  Vidyaro Live Server — Dockerfile
#
#  Base image : tiangolo/nginx-rtmp (Alpine — includes nginx + nginx-rtmp-module)
#  Extra tools :
#    • ffmpeg     — FLV → MP4 transcoding
#    • python3    — JSON encoding + URL-encode helper in recorder.sh
#    • awscli     — S3-compatible upload to Cloudflare R2
#    • curl       — webhook calls + healthcheck
#    • bash       — scripts require bash, not sh
##############################################################################
FROM tiangolo/nginx-rtmp:latest-alpine

# ── System tools ──────────────────────────────────────────────────────────────
# FIX: aws-cli is NOT in Alpine's apk repo — it must be installed via pip3.
# The original "apk add aws-cli" silently fails or installs a broken stub,
# meaning R2 uploads would never work.
RUN apk add --no-cache \
    bash \
    ffmpeg \
    curl \
    python3 \
    py3-pip \
    && pip3 install --no-cache-dir awscli \
    && rm -rf /var/cache/apk/* /root/.cache

# ── Nginx config (template — env vars substituted at container start) ─────────
COPY nginx.conf.template /etc/nginx/nginx.conf.template

# ── Post-recording pipeline script ───────────────────────────────────────────
COPY recorder.sh /etc/nginx/recorder.sh
RUN  chmod +x /etc/nginx/recorder.sh

# ── Container entrypoint (renders template, then starts nginx) ────────────────
COPY entrypoint.sh /entrypoint.sh
RUN  chmod +x /entrypoint.sh

# ── Runtime directories ───────────────────────────────────────────────────────
# FIX: "|| true" kept because nginx user may already own some dirs in the
# base image — chown failure should not abort the build
RUN mkdir -p \
    /tmp/live         \
    /tmp/keys         \
    /tmp/recordings   \
    /recordings       \
    /var/log/nginx    \
    && chown -R nginx:nginx \
    /var/log/nginx    \
    /recordings       \
    /tmp/live         \
    /tmp/keys         \
    /tmp/recordings   \
    || true

# ── Ports ─────────────────────────────────────────────────────────────────────
# 1935 = RTMP ingest  (OBS → nginx, raw TCP — NOT proxied by Traefik)
# 8080 = HLS HTTP     (reverse-proxied by Traefik/Caddy → HTTPS)
EXPOSE 1935 8080

ENTRYPOINT ["/entrypoint.sh"]
