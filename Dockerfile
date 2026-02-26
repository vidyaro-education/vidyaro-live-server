##############################################################################
#  Vidyaro Live Server — Dockerfile
##############################################################################
FROM tiangolo/nginx-rtmp:latest

# ── System tools ──────────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    ffmpeg \
    curl \
    python3 \
    python3-pip \
    gettext-base \
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
EXPOSE 1935 8080

ENTRYPOINT ["/entrypoint.sh"]
