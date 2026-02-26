# Vidyaro Live Server

> **nginx-rtmp** based live-streaming & recording server for the Vidyaro edutech platform.  
> Standalone repo — deploy independently from the main Next.js app.

---

## Architecture

```
Teacher (OBS / any RTMP client)
  │  rtmp://<server>:1935/stream
  │  Stream key: <roomId>?key=<streamKey>
  ▼
nginx-rtmp container
  ├── on_publish  → POST /api/stream-auth  (Next.js validates roomId + streamKey)
  ├── HLS output  → /tmp/live/<roomId>/index.m3u8   (AES-128 encrypted segments)
  ├── FLV record  → /recordings/<roomId>-TIMESTAMP.flv
  │
  └── on stream end: exec recorder.sh
          │
          ├── ffmpeg: FLV → MP4 (stream-copy, faststart)
          ├── aws s3 cp → Cloudflare R2  (s3://<bucket>/recordings/<roomId>/...mp4)
          ├── ffprobe: calculate duration
          ├── Appwrite REST: look up lectureId from roomId (stream_keys collection)
          └── POST /api/internal/recording-ready → Next.js
                  └── Appwrite: lecture.videoUrl = <R2 public URL>

Students
  └── HLS player → https://live.vidyaro.com/hls/<roomId>/index.m3u8
                     (AES-128 key fetched from https://vidyaro.com/api/hls-key/<roomId>)
```

---

## Quick Start (local)

```bash
git clone https://github.com/vidyaro-education/vidyaro-live-server.git
cd vidyaro-live-server

# 1. Configure environment
cp .env.example .env
nano .env          # fill in all values

# 2. Build & run
docker compose up -d --build

# 3. Verify
curl http://localhost:8080/health   # → OK
```

---

## Environment Variables

| Variable | Description |
|---|---|
| `STREAM_AUTH_URL` | Full URL of Next.js `/api/stream-auth` endpoint |
| `VIDYARO_APP_DOMAIN` | Domain only — e.g. `vidyaro.com` |
| `VIDYARO_APP_URL` | Base URL of Next.js app — e.g. `https://vidyaro.com` |
| `INTERNAL_SECRET` | Shared secret for internal webhook (must match Next.js) |
| `R2_ACCOUNT_ID` | Cloudflare account ID |
| `R2_ACCESS_KEY_ID` | R2 API token access key |
| `R2_SECRET_ACCESS_KEY` | R2 API token secret |
| `R2_BUCKET` | R2 bucket name |
| `R2_PUBLIC_URL` | Public base URL of the R2 bucket |
| `APPWRITE_ENDPOINT` | Appwrite API endpoint |
| `APPWRITE_PROJECT_ID` | Appwrite project ID |
| `APPWRITE_API_KEY` | Appwrite server API key (needs `databases.write`) |
| `APPWRITE_DATABASE_ID` | Appwrite database ID |
| `APPWRITE_STREAM_KEYS_COLLECTION_ID` | Collection that links `roomId` ↔ `lectureId` |

---

## Ports

| Port | Protocol | Purpose |
|------|----------|---------|
| `1935` | TCP | RTMP ingest (OBS → nginx) — must be open in firewall |
| `8080` | TCP | HLS HTTP — reverse-proxied by Traefik/Caddy to HTTPS |

---

## Coolify Deployment

1. In Coolify → **New Resource → Docker Compose**
2. Repository: `https://github.com/vidyaro-education/vidyaro-live-server`
3. **Port**: `8080` (Traefik proxies this to `https://live.vidyaro.com`)
4. **Environment Variables**: paste all vars from `.env.example` with real values
5. **Server → Firewall**: open port `1935` TCP for RTMP
6. Click **Deploy**

### Caddy / Traefik reverse proxy

```
# Caddyfile example
live.vidyaro.com {
    reverse_proxy localhost:8080
}
```

---

## Files

| File | Purpose |
|------|---------|
| `Dockerfile` | nginx-rtmp + ffmpeg + awscli image (Alpine) |
| `nginx.conf.template` | RTMP + HLS + auth config — env vars substituted at start |
| `entrypoint.sh` | Renders template → validates → starts nginx |
| `recorder.sh` | Post-stream pipeline: FLV→MP4→R2→Appwrite webhook |
| `docker-compose.yaml` | Compose definition with tmpfs mounts |
| `.env.example` | All environment variables with descriptions |

---

## Troubleshooting

```bash
# Live logs
docker compose logs -f nginx-rtmp

# Enter container
docker compose exec nginx-rtmp bash

# Test RTMP auth manually
curl -X POST http://localhost:8080/api/stream-auth \
  -d 'name=rm_test123&key=mysecretkey'

# Check HLS output
ls /tmp/live/

# Check nginx config rendered correctly
docker compose exec nginx-rtmp nginx -T
```
