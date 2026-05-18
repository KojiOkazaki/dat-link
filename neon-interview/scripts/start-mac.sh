#!/usr/bin/env bash
# Convenience launcher for the local llama-server + cloudflared stack
# that powers the NeonInterview Heroku app.
#
# Usage:
#   ./scripts/start-mac.sh
#
# Restart-safe: kills any prior llama-server / cloudflared first so you
# never end up with two copies fighting over port 8080.
#
# Logs:
#   /tmp/neon-llama.log     - llama-server stdout/stderr
#   /tmp/neon-tunnel.log    - cloudflared output (look here for the URL)
#
# After it boots, set the new tunnel URL on Heroku:
#   heroku config:set -a neon-interview LLAMA_URL=https://NEW-URL.trycloudflare.com

set -euo pipefail

MODEL_PATH="${MODEL_PATH:-$HOME/models/gemma-4-E4B-it-Q4_0.gguf}"
CTX="${CTX:-8192}"
PORT="${PORT:-8080}"
LLAMA_LOG=/tmp/neon-llama.log
TUNNEL_LOG=/tmp/neon-tunnel.log

if [[ ! -f "$MODEL_PATH" ]]; then
  echo "model file not found: $MODEL_PATH" >&2
  exit 1
fi

echo "stopping any previous instances..."
pkill -f 'llama-server' 2>/dev/null || true
pkill -f 'cloudflared'  2>/dev/null || true
sleep 1

echo "starting llama-server  (logs: $LLAMA_LOG)"
nohup llama-server -m "$MODEL_PATH" -c "$CTX" --port "$PORT" \
  > "$LLAMA_LOG" 2>&1 &
LLAMA_PID=$!

# Wait until 8080 is listening (max 120s for slow first-time mmap)
for _ in $(seq 1 120); do
  if curl -s -o /dev/null "http://127.0.0.1:$PORT/v1/models"; then
    break
  fi
  sleep 1
done
if ! curl -s -o /dev/null "http://127.0.0.1:$PORT/v1/models"; then
  echo "llama-server did not come up in 120s; tail of log:" >&2
  tail -20 "$LLAMA_LOG" >&2
  exit 1
fi
echo "llama-server pid=$LLAMA_PID is ready on :$PORT"

echo "starting cloudflared quick tunnel (logs: $TUNNEL_LOG)"
nohup cloudflared tunnel --url "http://localhost:$PORT" --protocol quic \
  > "$TUNNEL_LOG" 2>&1 &
TUNNEL_PID=$!

# Pull the new public URL out of the log
URL=""
for _ in $(seq 1 30); do
  URL=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$TUNNEL_LOG" | head -1 || true)
  [[ -n "$URL" ]] && break
  sleep 1
done

if [[ -z "$URL" ]]; then
  echo "could not detect tunnel URL; tail of log:" >&2
  tail -20 "$TUNNEL_LOG" >&2
  exit 1
fi

echo
echo "  llama-server :  pid $LLAMA_PID   log $LLAMA_LOG"
echo "  cloudflared  :  pid $TUNNEL_PID  log $TUNNEL_LOG"
echo "  public URL   :  $URL"
echo
echo "  to wire Heroku to this URL:"
echo "    heroku config:set -a neon-interview LLAMA_URL=$URL"
echo
echo "  to stop everything:"
echo "    pkill -f llama-server; pkill -f cloudflared"
