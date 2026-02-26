#!/bin/bash
set -e

echo "🚀 Deploying Vidyaro Live Server..."

# Check .env exists
if [ ! -f .env ]; then
  echo "❌  .env not found. Copy .env.example and fill in your values first."
  exit 1
fi

# Load env vars
set -a; source .env; set +a

# Validate INTERNAL_SECRET is set
if [ -z "$INTERNAL_SECRET" ]; then
  echo "❌  INTERNAL_SECRET is empty in .env"
  exit 1
fi

# Inject secret into nginx.conf
echo "→ Generating nginx.conf from template..."
sed "s|INTERNAL_SECRET_PLACEHOLDER|${INTERNAL_SECRET}|g" \
  nginx.conf.template > nginx.conf
echo "✓ nginx.conf generated"

# Build recorder image
echo "→ Building recorder..."
docker compose build recorder

# Start the stack
echo "→ Starting stack..."
docker compose up -d

echo ""
echo "✅  Live server running!"
echo "   RTMP  → rtmp://<server-ip>:1935/stream"
echo "   HLS   → https://live.vidyaro.com/hls/<stream_key>.m3u8"
echo ""
docker compose ps
