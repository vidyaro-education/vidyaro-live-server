# Coolify Setup Guide — Vidyaro Live Server

## What changed from your original setup

**Your original Coolify docker-compose:**
```yaml
services:
  rtmp:
    image: 'alfg/nginx-rtmp:latest'
    ports:
      - '1935:1935'
    volumes:
      - '/root/nginx.conf:/etc/nginx/nginx.conf'
    restart: unless-stopped
```

**What's added (no image changes, same alfg/nginx-rtmp):**
- Shared `/opt/vidyaro/recordings` bind-mount between nginx and recorder
- `recorder` service: auto-converts + uploads to R2 + updates Appwrite
- Proper `8080` port exposure for HLS playback

---

## Step-by-Step Coolify Setup

### 1. SSH onto your live server and run these once

```bash
# Create the shared recordings directory
mkdir -p /opt/vidyaro/recordings
chmod 777 /opt/vidyaro/recordings

# Copy the optimized nginx.conf
# (copy content from infrastructure/live-server/root-nginx.conf)
nano /root/nginx.conf
# Paste the content, save with Ctrl+X → Y → Enter
```

### 2. In Coolify — update the docker-compose

1. Open your live server service in Coolify
2. Go to **"Docker Compose"** tab
3. **Replace everything** with the content from `coolify-compose.yml`
4. Click **Save**

### 3. In Coolify — add Environment Variables

Go to **"Environment Variables"** tab and add:

| Variable | Value | Where to find it |
|----------|-------|-----------------|
| `R2_ACCOUNT_ID` | Your CF Account ID | Cloudflare → Right sidebar |
| `R2_ACCESS_KEY_ID` | R2 Access Key | CF → R2 → Manage API Tokens |
| `R2_SECRET_ACCESS_KEY` | R2 Secret | Same as above |
| `R2_BUCKET_NAME` | `vidyaro-recordings` | Your R2 bucket name |
| `R2_PUBLIC_URL` | `https://recordings.vidyaro.com` | Your R2 custom domain |
| `APPWRITE_ENDPOINT` | `https://cloud.appwrite.io/v1` | Appwrite Console |
| `APPWRITE_PROJECT_ID` | Your project ID | Appwrite → Settings |
| `APPWRITE_API_KEY` | Your server API key | Appwrite → API Keys |
| `APPWRITE_DATABASE_ID` | Your DB ID | Appwrite → Databases |
| `APPWRITE_LECTURES_COL_ID` | `lectures` | Your collection ID |
| `VIDYARO_APP_URL` | `https://vidyaro.com` | Your app URL |
| `INTERNAL_SECRET` | Random 32-char string | Run: `openssl rand -hex 32` |

Also add `INTERNAL_SECRET` to your **Next.js app** environment (Vercel/Coolify).

### 4. Also add INTERNAL_SECRET to your Vidyaro Next.js app

In Vercel (or wherever you deploy the Next.js app), add:
```
INTERNAL_SECRET=same_value_you_set_above
```

### 5. Redeploy in Coolify

Click **"Redeploy"** — Coolify will build the recorder service and start both containers.

### 6. Verify it's working

```bash
# On your server, check both containers are running
docker ps | grep vidyaro

# Check nginx health
curl http://localhost:8080/health

# Watch recorder logs in real-time
docker logs -f vidyaro-recorder
```

---

## How the recording flow works now

```
Admin clicks "Start Live"
  → Appwrite: lecture.videoUrl = https://live.vidyaro.com/live/{id}/index.m3u8
  → Teachers open OBS → stream to rtmp://live.vidyaro.com/stream
  → nginex records to /opt/vidyaro/recordings/{id}?pwd=XXXXX_timestamp.flv
  → Students watch HLS in CustomLecturePlayer

Admin clicks "Stop Live"
  → Appwrite: lecture.videoUrl = ""
  → Students see "Live Class Has Ended" screen
  → Teacher stops OBS

OBS disconnects → nginx finishes writing FLV
  → nginx writes: /opt/vidyaro/recordings/{id}?pwd=XXXXX.done  (tiny sentinel)
  → recorder service sees the .done file (polls every 5 seconds)
  → ffmpeg converts FLV → MP4 (web-optimised, fast-start)
  → aws s3 cp uploads MP4 to R2
  → Appwrite PATCH: lecture.videoUrl = https://recordings.vidyaro.com/recordings/{id}/...mp4
  → Webhook backup called for extra reliability

Students refresh → see the recorded video automatically ✅
```

---

## Cloudflare R2 Setup (if not done yet)

```bash
# 1. Create bucket in Cloudflare Dashboard → R2 → Create Bucket
#    Name: vidyaro-recordings

# 2. Enable public access:
#    R2 → vidyaro-recordings → Settings → Public Access → Allow Access

# 3. Set custom domain (recommended):
#    R2 → vidyaro-recordings → Settings → Custom Domains → Add domain
#    Domain: recordings.vidyaro.com
#    (Cloudflare will auto-add the CNAME record if domain is in CF)

# 4. Create API token:
#    R2 → Manage R2 API Tokens → Create API Token
#    Permissions: Object Read & Write
#    Copy: Access Key ID and Secret Access Key
```

---

## Troubleshooting

```bash
# Recorder not processing?
docker logs vidyaro-recorder

# Check if .done files are being created
ls -la /opt/vidyaro/recordings/*.done

# Manually test R2 upload from recorder container
docker exec -it vidyaro-recorder sh -c "
  AWS_ACCESS_KEY_ID=$R2_ACCESS_KEY_ID \
  AWS_SECRET_ACCESS_KEY=$R2_SECRET_ACCESS_KEY \
  aws s3 ls s3://$R2_BUCKET_NAME/ --endpoint-url https://$R2_ACCOUNT_ID.r2.cloudflarestorage.com
"

# nginx not starting?
docker logs vidyaro-live

# Test RTMP from your computer
ffmpeg -re -i test.mp4 -c copy -f flv rtmp://live.vidyaro.com/stream/test?pwd=TEST
```

---

## File structure on your server

```
/root/
  nginx.conf              ← paste from root-nginx.conf (update this file)

/opt/vidyaro/
  recordings/             ← shared between nginx + recorder containers
    *.flv                 ← raw recordings (auto-deleted after 7 days)
    *.done                ← sentinels (deleted after processing)
```
