##############################################################################
#  Vidyaro Live Server — Dockerfile
#
#  Base image : tiangolo/nginx-rtmp:latest (Debian-based)
#  Extra tools :
#    • ffmpeg     — FLV → MP4 transcoding
#    • python3    — JSON encoding + URL-encode helper in recorder.sh
#    • awscli     — S3-compatible upload to Cloudflare R2
#    • curl       — webhook calls + healthcheck
#    • bash       — scripts require bash, not sh
##############################################################################
FROM tiangolo/nginx-rtmp:latest

# ── System tools ──────────────────────────────────────────────────────────────
# tiangolo/nginx-rtmp:latest is Debian-based — use apt-get, NOT apk
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    ffmpeg \
    curl \
    python3 \
    python3-pip \
    && pip3 install --no-cache-dir awscli \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /root/.cache

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
    /var/log/nginx    \
    && chown -R www-data:www-data \
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
