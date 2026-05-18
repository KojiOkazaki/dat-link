# NeonInterview — Operations Manual

> Cyberpunk-themed English mock-interview chatbot for Meta Ray-Ban
> Display, backed by a Mac-side `llama.cpp` / Gemma 4 server and
> fronted by a Heroku Node.js app.

This manual covers the full stack end to end: what the app is, the
architecture, how to set it up from scratch, day-to-day operation, the
API surface, customization, and a troubleshooting flow tied to the
diagnostic endpoints we added to the server.

Links throughout this document point to the **canonical upstream
docs** so you can dig into each component's own source of truth.

---

## Table of contents

1. [What NeonInterview is](#what-neoninterview-is)
2. [Architecture overview](#architecture-overview)
3. [Hardware & software requirements](#hardware--software-requirements)
4. [First-time setup](#first-time-setup)
5. [Day-to-day operation](#day-to-day-operation)
6. [API reference (`server.js`)](#api-reference-serverjs)
7. [Customization](#customization)
8. [Troubleshooting](#troubleshooting)
9. [Architectural decisions & gotchas](#architectural-decisions--gotchas)
10. [References](#references)

---

## What NeonInterview is

A two-screen English mock-interview experience.

- **On the Meta Ray-Ban Display** (`/`): a 600×600 glass viewer styled
  in cyberpunk neon + monospace + scan-lines + HUD-notched buttons.
  The interviewer's question is read aloud through the device speakers
  via server-streamed MP3 TTS. The Neural Band D-pad navigates a small
  set of pre-generated reply chips so the user never has to talk.
- **On a phone** (`/input`): the same cyberpunk UI but with a text
  composer + Web Speech (`en-US`) microphone, in case the candidate
  wants to type or speak a free-form answer.

Both views are served by the same Heroku Node app and stay in sync over
[Server-Sent Events][mdn-sse] (SSE).

The brain is a local Gemma 4 E4B Q4_0 GGUF model served by
[`llama.cpp`'s `llama-server`][llama-server-readme] on the developer's
Mac, exposed publicly through a quick [Cloudflare Tunnel][cf-tunnel].
The Heroku app only proxies the relevant chat completion + TTS
requests; **no model weights or API keys ever live in Heroku**.

Three rounds are shipped:

| ID           | Label  | Style                                           |
| ------------ | ------ | ----------------------------------------------- |
| `behavioral` | BEHAV  | STAR-frame questions about past experience      |
| `technical`  | TECH   | Coding / data-structure / system-design probes  |
| `case`       | CASE   | Business or product case with quant estimates   |

---

## Architecture overview

```
                                ┌──────────────────────────────┐
                                │  HEROKU  neon-interview-…    │
                                │  (Node.js / Express)         │
                                │                              │
                                │   /          → MRBD HTML     │
                                │   /input     → phone HTML    │
                                │   /api/say   → llama proxy   │
                                │   /api/hint  → llama proxy   │
                                │   /api/end   → llama proxy   │
                                │   /api/tts   → Google TTS    │
                                │   /api/events → SSE          │
                                │   /api/health → self-probe   │
                                └────────────┬─────────────────┘
                                             │ HTTPS POST
                                             ▼
              ┌──────────────────────────────────────────────────────┐
              │  CLOUDFLARE QUICK TUNNEL (QUIC)                      │
              │  https://xxxx-xxxx-xxxx.trycloudflare.com            │
              └──────────────────────────┬───────────────────────────┘
                                         │
                                         ▼
                            ┌──────────────────────────────┐
                            │  cloudflared (Mac, QUIC)     │
                            │  forwards to 127.0.0.1:8080  │
                            └──────────────┬───────────────┘
                                           ▼
                            ┌──────────────────────────────┐
                            │  llama-server (llama.cpp)    │
                            │  -m gemma-4-E4B-it-Q4_0.gguf │
                            │  -c 8192   --port 8080       │
                            │  OpenAI-compat /v1/...       │
                            └──────────────────────────────┘

                  ┌──────────────────────────────┐
                  │  Meta Ray-Ban Display Web App│
                  │  (registered via fb-viewapp  │
                  │   deep link + Meta AI app)   │
                  │  D-pad / Enter input only    │
                  └──────────────────────────────┘
                                ▲
                                │ HTTPS, SSE
                                ▼
                  ┌──────────────────────────────┐
                  │  Phone /input  (Safari etc.) │
                  │  Web Speech STT (en-US)      │
                  └──────────────────────────────┘
```

A few important properties:

- **Heroku has no GPU and no model weights.** It only routes JSON.
  The expensive work runs on your Mac.
- **The Cloudflare quick tunnel is the only public ingress to your
  Mac.** When you stop `cloudflared`, your Mac is fully private again.
- **SSE (`/api/events`) runs between Heroku and the browser/MRBD**, not
  through the cloudflared tunnel — important because [quick tunnels
  explicitly do not support SSE][cf-quick-limits], but ours doesn't
  need that, only POST to `/v1/chat/completions` flows through.

---

## Hardware & software requirements

### Hardware
- Apple Silicon Mac (M1 or newer) with **≥16 GB unified memory**.
  Gemma 4 E4B Q4_0 is ~3 GB on disk and uses a few GB of working
  memory under llama.cpp's Metal backend.
- iPhone with the **Meta AI app** installed and paired Ray-Ban Display
  + Neural Band ([setup guide][meta-rbd-setup]).
- A Heroku account (the free Eco dyno is enough — this app is mostly idle).

### Software (Mac)
- macOS with [Homebrew](https://brew.sh).
- `llama.cpp` (`brew install llama.cpp` or build from
  [ggml-org/llama.cpp][llama-cpp-repo]). Provides the `llama-server`
  binary.
- `cloudflared` (`brew install cloudflared` or from
  [cloudflare/cloudflared][cloudflared-repo]).
- `heroku` CLI (`brew install heroku/brew/heroku`).
- `hf` (the new unified [Hugging Face CLI][hf-cli], replaces
  `huggingface-cli`).

### Cloud
- One Heroku app (`neon-interview` in this repo's deploy).
- A Hugging Face account (only needed if the GGUF repo is gated; the
  ones we use here are not).

---

## First-time setup

> If you already have the repo and a Heroku app, jump straight to
> [Day-to-day operation](#day-to-day-operation).

### 1. Clone

```sh
cd ~
git clone https://github.com/KojiOkazaki/dat-link.git
cd dat-link
git checkout claude/cooking-guide-app-5Unui   # (or whichever branch
                                              # contains neon-interview/)
```

### 2. Download the model

We use `unsloth/gemma-4-E4B-it-GGUF`'s Q4_0 (~3 GB). It's a clean,
multilingual instruction-tuned Gemma 4 with the current chat template
(no "outdated gemma4 chat template" warning from llama.cpp).

```sh
mkdir -p ~/models
hf download unsloth/gemma-4-E4B-it-GGUF \
  gemma-4-E4B-it-Q4_0.gguf --local-dir ~/models
```

If you prefer a different quant (`Q4_K_M`, `Q5_K_M`, `Q8_0`, etc.),
list them first:

```sh
curl -s https://huggingface.co/api/models/unsloth/gemma-4-E4B-it-GGUF \
  | python3 -c "import sys,json; print('\n'.join(f['rfilename'] for f in json.load(sys.stdin).get('siblings',[]) if f.get('rfilename','').endswith('.gguf')))"
```

See the [Gemma 4 model card][gemma-4-model-card] for guidance on
trade-offs between quants.

### 3. Create the Heroku app

The `neon-interview/` directory is a Heroku-ready Node app, but the
outer `dat-link/` repo is **not** — Heroku's buildpack auto-detection
needs `package.json` at the repo root, so we deploy from
`neon-interview/` as its own git repo.

```sh
cd ~/dat-link/neon-interview
git init -b main
git add -A
git commit -m "scaffold from dat-link"

heroku create neon-interview            # use any unique name
heroku git:remote -a neon-interview     # wires the heroku remote
```

Set the two config vars (`MODEL` is just a label sent in the OpenAI
JSON body; llama-server doesn't gate on it):

```sh
heroku config:set -a neon-interview MODEL=gemma
# LLAMA_URL will be set automatically by scripts/start-mac.sh below.
```

### 4. First deploy

```sh
git push heroku main
```

Heroku detects Node.js from `package.json` and runs `node server.js`
on its dyno (see [Procfile docs][heroku-procfile] and
[Node.js support reference][heroku-nodejs]).

### 5. Bring up the Mac stack

```sh
bash ~/dat-link/neon-interview/scripts/start-mac.sh
```

The script:

1. `pkill`s any prior `llama-server` / `cloudflared` (avoids port
   8080 collisions and stale tunnels).
2. Starts `llama-server` with your model in the background, logging
   to `/tmp/neon-llama.log`.
3. Waits up to 120 s for `:8080` to listen.
4. Starts `cloudflared` over **QUIC** (UDP egress to the Cloudflare
   edge — POSTs through this transport have been more reliable for us
   than the default HTTP/2 path) into the background, logging to
   `/tmp/neon-tunnel.log`.
5. Extracts the new `https://*.trycloudflare.com` URL from the log.
6. If your `heroku` CLI is logged in, runs
   `heroku config:set -a neon-interview LLAMA_URL=<new-URL>`
   automatically, so the Heroku app picks the new URL on its next
   request.

Override defaults with environment variables:

```sh
MODEL_PATH=~/models/some-other.gguf \
CTX=4096 \
HEROKU_APP=my-other-app \
  bash ~/dat-link/neon-interview/scripts/start-mac.sh
```

### 6. Verify

```sh
curl -s https://neon-interview-XXXXX.herokuapp.com/api/health
```

Expected:

```json
{
  "ok": true,
  "hasLlama": true,
  "llamaUrl": "https://...-...-...trycloudflare.com",
  "llamaOk": true,
  "llamaStatus": 200,
  "llamaProbeError": null,
  "lastError": null,
  "model": "gemma",
  ...
}
```

`llamaOk: true` + `llamaStatus: 200` means Heroku can reach your Mac
through the tunnel right now.

### 7. Register the app on the Meta Ray-Ban Display

Construct the `fb-viewapp` deep link, embed it in a QR, scan with your
phone's camera. The Meta AI app picks it up and adds NeonInterview as
a Web App on the Display ([Meta wearables developer docs][meta-wear-docs]).

```
fb-viewapp://web_app_deep_link?appName=NeonInterview&appUrl=https%3A%2F%2Fneon-interview-XXXXX.herokuapp.com%2F
```

Once added, the Display can launch it the same way as any other Meta
Web App.

---

## Day-to-day operation

### Starting the stack

After a Mac reboot, the tunnel and the local model server are gone.
Run:

```sh
bash ~/dat-link/neon-interview/scripts/start-mac.sh
```

That's the only command you need. The Heroku app keeps running on its
own; the script just brings up the dependencies it talks to, and
re-points `LLAMA_URL` at the fresh tunnel URL.

### Stopping the stack

```sh
pkill -f llama-server
pkill -f cloudflared
```

The Heroku app keeps idling. If you want it offline too:

```sh
heroku ps:scale web=0 -a neon-interview
# later:
heroku ps:scale web=1 -a neon-interview
```

### Using the Display app

1. On the Display, open the Apps drawer and launch **NeonInterview**.
2. Top bar shows `NEON//INTERVIEW · SYS·EN-US` and a status diamond:
   - **cyan** = live (SSE connected, server healthy)
   - **yellow pulsing** = thinking (waiting on llama)
   - **red** = error
3. The first screen is a round picker. Pick BEHAV / TECH / CASE with
   ← → and Enter.
4. The interviewer asks a question. The Display reads it aloud via
   `/api/tts`. Two suggested reply chips appear below.
5. Move focus with the D-pad, press Enter to send a reply. While the
   model is thinking your picked reply is shown in greyed-out echo.
6. Press the MENU bar at the bottom to open HINT / END / ROUND / BACK
   / VOICE.
   - **HINT** asks the coach for a short structural hint (yellow card).
   - **END** ends the interview and shows STRENGTH / GAP / NEXT TIME /
     VERDICT feedback (green card).
   - **ROUND** goes back to the round picker (resets history).
   - **VOICE** toggles MP3 TTS on this device (saved in localStorage).

### Using the phone view

Open `https://neon-interview-XXXXX.herokuapp.com/input` on Safari/Chrome.
Same conversation as the Display, but with a text box and a microphone
button. STT uses the browser's Web Speech API with `lang='en-US'`.

The Display and the phone share state — they're two views of the same
in-memory conversation.

---

## API reference (`server.js`)

All endpoints are JSON unless stated. The conversation is stored
in-memory in a single global slot; restarting the dyno wipes it.

| Method | Path                    | Purpose                                                              |
| ------ | ----------------------- | -------------------------------------------------------------------- |
| GET    | `/`                     | Serves the MRBD viewer (`chat/public/index.html`).                   |
| GET    | `/input`                | Serves the phone composer (`chat/public/input.html`).                |
| GET    | `/api/events`           | SSE stream. Emits `snapshot`, `append`, `suggestions`, `ping`.       |
| POST   | `/api/category`         | Body `{category}`. Resets history and seeds with that round's intro. |
| POST   | `/api/start`            | Re-seeds the current round with its intro.                           |
| POST   | `/api/say`              | Body `{text}`. Sends a candidate turn and gets the next question.    |
| POST   | `/api/hint`             | Generates a coach hint for the last interviewer question.            |
| POST   | `/api/end`              | Generates the 4-section interview feedback (STRENGTH/GAP/...).       |
| POST   | `/api/reset`            | Clears all in-memory state.                                          |
| GET    | `/api/tts?text=…&lang=` | Streams an `audio/mpeg` of `text` from Google Translate TTS.         |
| GET    | `/api/health`           | Self-diagnosis (see below).                                          |

### `GET /api/health` — the diagnostic endpoint

This is the single most useful endpoint when something is broken. It
returns the current config, *live-probes the configured `LLAMA_URL`*
with a 3-second timeout, and shows the last error any handler hit.

```json
{
  "ok": true,
  "hasLlama": true,
  "llamaUrl": "https://....trycloudflare.com",
  "llamaOk": true,
  "llamaStatus": 200,
  "llamaProbeError": null,
  "lastError": null,
  "model": "gemma",
  "messages": 0,
  "listeners": 1,
  "state": {
    "category": "behavioral",
    "questionNum": 0,
    "startedAt": null,
    "ended": false,
    "categoryName": "Behavioral"
  }
}
```

`llamaProbeError` (probe-time) and `lastError` (handler-time) are the
two fields to read first. See
[Troubleshooting](#troubleshooting) for the playbook.

### llama.cpp body shape

We call llama-server with the standard
[OpenAI-compatible chat completions][llama-server-readme] payload,
plus one critical extra parameter:

```json
{
  "model": "gemma",
  "messages": [...],
  "max_tokens": 250,
  "temperature": 1.0,
  "top_p": 0.95,
  "top_k": 64,
  "stream": false,
  "chat_template_kwargs": { "enable_thinking": false }
}
```

`enable_thinking: false` is non-negotiable for Gemma 4 — see
[Gotchas](#architectural-decisions--gotchas).

---

## Customization

To brand the app or repurpose it (e.g. a different language, a
different persona) most of the work happens in two files:

### `server.js`

- `BASE_PROMPT`   – the interviewer's persona / tone / length rules
- `HINT_PROMPT`   – what "hint mode" should produce
- `END_PROMPT`    – the 4-section feedback template
- `SUGG_TEMPLATES` – per-round MECE direction + one few-shot example
- `CATEGORIES`    – the 3 rounds (`name`, `focus`, `intro`, two seed
                    `suggs`)

### `chat/public/index.html` (MRBD viewer)

- `<title>`, `.brand` (top-bar label)
- `CATS` array (must match the `CATEGORIES` keys in `server.js`)
- Headlines on the category / ended screens
- `INTERVIEWER` / `HINT` / `FEEDBACK` labels
- TTS language: `splitEnForTTS` is split on `[.!?\n]`; for Japanese
  swap to `[。！？\n]` and change the `/api/tts?lang=` query string
  (see [google translate TTS][gtranslate-tts-note] for available
  language codes).

The MRBD-specific layout constraints (600×600, `.focusable {
min-height: 88px }`, `.chip { min-height: 116px }`, flex-start
scrolling) **must stay** — Meta enforces these via human-interface
review.

---

## Troubleshooting

The diagnostic flow always starts at the same place:

```sh
curl -s https://neon-interview-XXXXX.herokuapp.com/api/health
```

Read the result top-down:

### `hasLlama: false`
The Heroku dyno didn't see `LLAMA_URL` at boot. Set it and restart:

```sh
heroku config:set -a neon-interview LLAMA_URL=https://....trycloudflare.com
# (Heroku auto-restarts on a config:set, but you can force it:)
heroku restart -a neon-interview
```

### `llamaOk: false` & `llamaProbeError: "fetch failed"` / "ENOTFOUND"
The tunnel URL doesn't resolve. The quick tunnel is dead. Restart it:

```sh
bash ~/dat-link/neon-interview/scripts/start-mac.sh
```

The script rotates `LLAMA_URL` on Heroku for you.

### `llamaOk: false` & `llamaStatus: 502` + `llamaProbeError: "..."` mentioning "origin"
Cloudflare can reach the tunnel but `cloudflared` can't reach
`localhost:8080`. `llama-server` crashed or was killed. Check:

```sh
lsof -nP -iTCP:8080 -sTCP:LISTEN
tail -50 /tmp/neon-llama.log
```

If nothing listens, rerun `scripts/start-mac.sh` — it kills the stale
`cloudflared`, restarts `llama-server`, and brings up a fresh tunnel.

### `llamaOk: true` but app still 502s on POST
Look at `lastError` in `/api/health`. Cross-check with:

```sh
heroku logs -a neon-interview --source app --tail
```

Every `/api/say`, `/api/hint`, `/api/end` failure now logs
`[/api/<path>] <error>` to Heroku stdout, so you'll see the actual
exception (timeout, connection reset, model unloaded mid-stream, etc.).

### Model responds in Japanese (or wrong language)
You're probably running a Japanese-tuned fine-tune (`shukatsu-gemma4`
etc.). Either:
- Replace with the stock `google/gemma-4-E4B-it` via the Hugging Face
  CLI: `hf download unsloth/gemma-4-E4B-it-GGUF gemma-4-E4B-it-Q4_0.gguf
  --local-dir ~/models`, then change `MODEL_PATH` in the launcher; or
- Append `Respond in English only. Never use Japanese characters.` to
  `BASE_PROMPT` in `server.js` (less reliable).

### Display QR doesn't open in the Meta AI app
- Confirm you're scanning with the iPhone's stock camera, not inside
  the Meta AI app.
- The deep link must use `fb-viewapp://web_app_deep_link?appName=...&appUrl=...`
  with `appUrl` URL-encoded.
- Make sure your Display is paired and you've enabled developer
  options in the Meta AI app ([setup guide][meta-rbd-setup]).

### "outdated gemma4 chat template" warning at llama-server boot
Your GGUF was built against an older chat template. Re-download from
`unsloth/...` or `ggml-org/...` — both are kept current. See the
[Gemma 4 HF release blog post][hf-gemma4-blog] for details on the
template rev.

---

## Architectural decisions & gotchas

### Why Heroku in front of a local model?
Two reasons. **(a)** The MRBD requires HTTPS for Web Apps; Heroku
hands you a TLS-terminated `*.herokuapp.com` URL out of the box.
**(b)** It gives us a stable URL to register with `fb-viewapp` — if
the MRBD pointed directly at the quick tunnel, every restart would
require re-registering the app.

### Why a quick tunnel and not a named tunnel?
Speed of bring-up. The tradeoff is documented:
[quick tunnels][cf-quick-limits] (`trycloudflare.com`) have no SLA, a
200-concurrent-request cap, and **do not support SSE**. None of those
matter for our path — SSE runs Heroku→browser, not through the
tunnel — but if you want a stable URL, switch to a [named tunnel][cf-named-tunnel]
with your own domain.

### Why QUIC for cloudflared?
The default `http2` cloudflared protocol consistently lost POST bodies
in our setup (GET worked, POST returned empty). Switching to
`--protocol quic` (UDP egress to the Cloudflare edge) made POST
roundtrips reliable. This is supported by Cloudflare and is one of
the three available protocols (`auto`, `quic`, `http2`).

### Why `enable_thinking: false`?
Gemma 4's chat template defaults to **thinking mode**, where the model
fills `reasoning_content` with chain-of-thought before producing the
visible answer. With our typical `max_tokens` budget (~250), the
thinking block consumes the entire budget and `content` comes back as
the empty string. `chat_template_kwargs.enable_thinking = false`
makes llama-server feed the model the no-think variant of the
template, restoring normal behavior. See the
[Gemma 4 model card][gemma-4-model-card] for the upstream behavior
description.

### Why a separate inner git repo in `neon-interview/`?
Heroku's Node buildpack needs `package.json` at the repository root,
but the outer `dat-link/` repo is mixed (Glance + Interview +
NeonInterview). Initializing `neon-interview/` as its own git repo
lets Heroku see a clean Node app while the outer repo stays
multi-project.

### Why is `MODEL=gemma` even a config var?
`llama-server` is single-model — whatever you load with `-m` is what
it serves, and the OpenAI `model` field in the request is ignored. We
still send it because the spec expects it, and we use it as a label
in Heroku for clarity.

### Why don't errors persist forever in the UI?
They do, sort of: `/api/say` pushes `{role: 'assistant', content:
'(error: …)'}` into history so the user has visibility. To clear,
either pick a round again (resets history) or POST `/api/reset`.

---

## References

### Meta Ray-Ban Display / Wearables
- [Meta Wearables Developer Documentation][meta-wear-docs]
- [Introducing the Meta Wearables Device Access Toolkit (developer
  blog)][meta-wear-blog]
- [Meta Wearables FAQ][meta-wear-faq]
- [Meta Ray-Ban Display + Neural Band setup guide][meta-rbd-setup]
- [Ray-Ban | Meta Display product FAQs][rb-meta-faq]

### Gemma 4
- [Gemma 4 model overview (Google AI for Developers)][gemma-4-overview]
- [Gemma 4 model card][gemma-4-model-card]
- [`google/gemma-4-E4B-it` on Hugging Face][gemma-4-e4b-it-hf]
- [Welcome Gemma 4 — Hugging Face blog post][hf-gemma4-blog]

### llama.cpp
- [ggml-org/llama.cpp repository][llama-cpp-repo]
- [`llama-server` README][llama-server-readme]
- [Function-calling docs][llama-fn-call]

### GGUF distributions
- [unsloth/gemma-4-E4B-it-GGUF][unsloth-gemma4]  (what we use)
- [ggml-org/gemma-4-E4B-it-GGUF][ggml-org-gemma4]
- [bartowski/google_gemma-4-E4B-it-GGUF][bartowski-gemma4]

### Cloudflare Tunnel
- [Cloudflare Tunnel docs (Cloudflare One)][cf-tunnel]
- [Quick Tunnels — `trycloudflare.com`][cf-quick-limits]
- [`cloudflared` setup][cf-tunnel-setup]
- [cloudflare/cloudflared on GitHub][cloudflared-repo]

### Heroku
- [Getting started with Node.js on Heroku][heroku-nodejs-start]
- [Procfile reference][heroku-procfile]
- [Node.js support reference][heroku-nodejs]
- [Config vars][heroku-config]

### Hugging Face
- [Hugging Face CLI (`hf`)][hf-cli]

### Web platform pieces we rely on
- [Server-Sent Events (MDN)][mdn-sse]
- [Web Speech API (MDN)][mdn-webspeech]


[meta-wear-docs]:    https://wearables.developer.meta.com/docs
[meta-wear-blog]:    https://developers.meta.com/blog/introducing-meta-wearables-device-access-toolkit/
[meta-wear-faq]:     https://developers.meta.com/wearables/faq/
[meta-rbd-setup]:    https://www.meta.com/help/ai-glasses/621680547224505/
[rb-meta-faq]:       https://www.ray-ban.com/usa/c/frequently-asked-questions-meta-ray-ban-display

[gemma-4-overview]:   https://ai.google.dev/gemma/docs/core
[gemma-4-model-card]: https://ai.google.dev/gemma/docs/core/model_card_4
[gemma-4-e4b-it-hf]:  https://huggingface.co/google/gemma-4-E4B-it
[hf-gemma4-blog]:     https://huggingface.co/blog/gemma4

[llama-cpp-repo]:      https://github.com/ggml-org/llama.cpp
[llama-server-readme]: https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md
[llama-fn-call]:       https://github.com/ggml-org/llama.cpp/blob/master/docs/function-calling.md

[unsloth-gemma4]:    https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF
[ggml-org-gemma4]:   https://huggingface.co/ggml-org/gemma-4-E4B-it-GGUF
[bartowski-gemma4]:  https://huggingface.co/bartowski/google_gemma-4-E4B-it-GGUF

[cf-tunnel]:         https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/
[cf-quick-limits]:   https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/trycloudflare/
[cf-tunnel-setup]:   https://developers.cloudflare.com/tunnel/setup/
[cf-named-tunnel]:   https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/local-management/create-local-tunnel/
[cloudflared-repo]:  https://github.com/cloudflare/cloudflared

[heroku-nodejs-start]: https://devcenter.heroku.com/articles/getting-started-with-nodejs
[heroku-procfile]:     https://devcenter.heroku.com/articles/procfile
[heroku-nodejs]:       https://devcenter.heroku.com/articles/nodejs-support
[heroku-config]:       https://devcenter.heroku.com/articles/config-vars

[hf-cli]: https://huggingface.co/docs/huggingface_hub/main/en/guides/cli

[gtranslate-tts-note]: https://cloud.google.com/text-to-speech/docs/voices
[mdn-sse]:             https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events/Using_server-sent_events
[mdn-webspeech]:       https://developer.mozilla.org/en-US/docs/Web/API/Web_Speech_API
