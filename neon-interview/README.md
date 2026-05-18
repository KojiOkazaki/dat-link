# NeonInterview

Cyberpunk-themed English mock-interview chat for Meta Ray-Ban Display,
backed by a Mac-side `llama.cpp` Gemma 4 server. Sibling of the original
`Interview` (Japanese) app — same architecture, retuned for American
candidates.

> **For day-to-day operation, troubleshooting, the API reference, and
> all upstream documentation links, read [MANUAL.md](./MANUAL.md).**
> This README is just the quick start.

```
[Mac]
  llama-server -m gemma-4-E2B-it-Q8_0.gguf -c 8192 --port 8080
  cloudflared tunnel --url http://localhost:8080 --protocol http2
                                ↓ public HTTPS
                          【Heroku Node app】
                          - /v1/chat/completions proxy
                            (enable_thinking=false)
                          - /api/tts (en-US MP3 stream)
                          - SSE broadcast
                                ↑
              ┌─────────────────┴─────────────────┐
            [phone /input]                    [MRBD /]
            text + Web Speech (en-US)         neon 600×600 viewer,
                                              <audio> /api/tts,
                                              D-pad nav
```

## Rounds

- **BEHAV** — Behavioral / STAR
- **TECH**  — Coding, data structures, system design
- **CASE**  — Business / product case

## Run locally

```sh
npm install
LLAMA_URL=https://your-tunnel.trycloudflare.com node server.js
open http://localhost:3000/         # MRBD viewer
open http://localhost:3000/input    # phone input
```

## Deploy to Heroku

```sh
heroku create neon-interview
heroku config:set LLAMA_URL=https://<tunnel>.trycloudflare.com
heroku config:set MODEL=gemma
git push heroku <branch>:main
```

## MRBD registration

Generate an `fb-viewapp` deep link QR:

```
fb-viewapp://web_app_deep_link?appName=NeonInterview&appUrl=<urlencoded-https-url>
```

Scan with the phone camera; the Meta AI app adds the Web App.
