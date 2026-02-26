# Vidyaro Live Server

A dedicated **nginx-rtmp** based live-streaming & recording microservice for the
Vidyaro edutech platform. Fully decoupled from the main Next.js app and deployed
via **Coolify** as a single Docker Compose service.

---

## Architecture

```text
Teacher (OBS)
  │  rtmp://<server>:1935/stream
  │  Stream key: <roomId>?key=<streamKey>
  ▼
Nginx-RTMP Container (Coolify)
  ├── on_publish  → POST /api/stream-auth      (Next.js validates key)
  ├── HLS output  → /tmp/live/<roomId>/index.m3u8  (AES-128 encrypted)
  ├── FLV record  → /recordings/<roomId>-TIMESTAMP.flv
  │
  └── On stream end: exec_record_done → recorder.sh
          ├── ffmpeg: FLV → MP4 (stream-copy, faststart)
          ├── aws s3 cp: upload to Cloudflare R2
          ├── ffprobe: calculate duration
          ├── Appwrite query: resolve lectureId from roomId
          └── POST /api/internal/recording-ready → Next.js updates lecture

Students
  └── HLS player → https://live.vidyaro.com/live/<roomId>/index.m3u8
                   (AES-128 keys served by Next.js /api/hls-key/[roomId])
```

---

## Coolify Deployment

### Steps

1. **Create Resource**: Coolify → Projects → Add Resource → **Docker Compose**
2. **Repository**: `vidyaro-education/vidyaro-live-server`
3. **Domain**: Set `live.vidyaro.com` → port `8080` in Coolify proxy settings
4. **Port 1935**: Open raw TCP port `1935` in both:
   - Coolify → Servers → your server → Firewall
   - Hostinger VPS firewall (separate from Coolify)
   - RTMP is raw TCP — Traefik/Caddy **cannot** proxy it
5. **Environment Variables**: Add all vars from `.env.example` in Coolify UI
6. **Deploy**: Click Deploy

### Environment Variables

| Variable | Description |
|---|---|
| `STREAM_AUTH_URL` | Next.js stream validation endpoint e.g. `https://vidyaro.com/api/stream-auth` |
| `VIDYARO_APP_DOMAIN` | Domain for CORS and HLS key URL e.g. `vidyaro.com` |
| `VIDYARO_APP_URL` | App base URL for recording webhook e.g. `https://vidyaro.com` |
| `INTERNAL_SECRET` | Shared secret for `/api/hls-key/` — generate with `openssl rand -hex 32` only |
| `R2_ACCOUNT_ID` | Cloudflare account hash |
| `R2_ACCESS_KEY_ID` | R2 API token access key |
| `R2_SECRET_ACCESS_KEY` | R2 API token secret |
| `R2_BUCKET` | R2 bucket name e.g. `vidyaro-recordings` |
| `R2_PUBLIC_URL` | R2 public URL e.g. `https://recordings.vidyaro.com` |
| `APPWRITE_ENDPOINT` | Appwrite instance URL e.g. `https://cloud.appwrite.io/v1` |
| `APPWRITE_PROJECT_ID` | Appwrite project ID |
| `APPWRITE_API_KEY` | Appwrite server key — `databases.read` permission only |
| `APPWRITE_DATABASE_ID` | Appwrite database ID |
| `APPWRITE_STREAM_KEYS_COLLECTION_ID` | Collection holding `roomId → lectureId` mappings |

---

## Local Development

```bash
cp .env.example .env
# Fill in real values

docker compose up -d --build

# Confirm container is healthy
curl http://localhost:8080/health
# → {"status":"ok"}

# Watch recorder logs
docker exec vidyaro-live tail -f /var/log/nginx/recorder.log

# Watch nginx error log
docker exec vidyaro-live tail -f /var/log/nginx/error.log
```

### Test a stream locally

Point OBS to:
- **Server**: `rtmp://localhost:1935/stream`
- **Stream Key**: `<roomId>?key=<streamKey>`

---

## File Reference

| File | Purpose |
|---|---|
| `Dockerfile` | Builds Alpine image with nginx-rtmp, ffmpeg, awscli |
| `docker-compose.yaml` | Coolify/VPS deployment — tmpfs volumes, ports, env passthrough |
| `nginx.conf.template` | RTMP ingest + AES-128 HLS + HTTP delivery config |
| `entrypoint.sh` | Substitutes env vars into nginx template, validates, starts nginx |
| `recorder.sh` | Post-stream pipeline: FLV→MP4→R2→Appwrite→webhook |
| `.env.example` | All required environment variables with descriptions |
