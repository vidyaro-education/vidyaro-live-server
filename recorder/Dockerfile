########################################################################
# recorder/Dockerfile
#
# Lightweight Alpine image with:
#   - Python 3        (watcher script)
#   - ffmpeg          (FLV → MP4 conversion)
#   - awscli          (S3-compatible Cloudflare R2 upload)
#   - curl            (Appwrite + webhook calls)
########################################################################

FROM python:3.12-alpine

LABEL description="Vidyaro recording watcher: FLV → MP4 → R2 → Appwrite"

# Install system packages
RUN apk add --no-cache \
    ffmpeg \
    curl \
    bash \
    tzdata \
    && pip install --no-cache-dir awscli \
    && rm -rf /root/.cache /tmp/*

# IST timezone
ENV TZ=Asia/Kolkata
RUN cp /usr/share/zoneinfo/Asia/Kolkata /etc/localtime

WORKDIR /app
COPY watch_and_upload.py .

# /recordings is mounted from the host (shared with rtmp container)
VOLUME ["/recordings"]

CMD ["python3", "-u", "watch_and_upload.py"]
