##############################################################################
#  Vidyaro Live Server — Dockerfile
#
#  Base image : tiangolo/nginx-rtmp (Alpine — includes nginx + nginx-rtmp-module)
#  Extra tools :
#    • ffmpeg     — FLV → MP4 transcoding
#    • python3    — URL-encode helper in recorder.sh
#    • aws-cli    — S3-compatible upload to Cloudflare R2
#    • curl       — webhook calls
#    • bash       — scripts require bash, not sh
##############################################################################
FROM tiangolo/nginx-rtmp:latest-alpine

# ── System tools ──────────────────────────────────────────────────────────────
RUN apk add --no-cache \
    bash \
    ffmpeg \
    curl \
    python3 \
    py3-pip \
    aws-cli \
    && rm -rf /var/cache/apk/*

# ── Nginx config (template — env vars substituted at container start) ─────────
COPY nginx.conf.template /etc/nginx/nginx.conf.template

# ── Post-recording pipeline script ───────────────────────────────────────────
COPY recorder.sh /etc/nginx/recorder.sh
RUN  chmod +x /etc/nginx/recorder.sh

# ── Container entrypoint (renders template, then starts nginx) ────────────────
COPY entrypoint.sh /entrypoint.sh
RUN  chmod +x /entrypoint.sh

# ── Runtime directories ───────────────────────────────────────────────────────
RUN mkdir -p \
    /tmp/live         \
    /tmp/keys         \
    /tmp/recordings   \
    /recordings       \
    /var/log/nginx

# ── Ports ─────────────────────────────────────────────────────────────────────
# 1935 = RTMP ingest (OBS → nginx)
# 8080 = HLS HTTP   (reverse-proxied by Traefik / Caddy → HTTPS)
EXPOSE 1935 8080

ENTRYPOINT ["/entrypoint.sh"]
