---
name: mrbd-llm-app
description: Bootstrap a Meta Ray-Ban Display Web App backed by a phone- or Mac-side llama.cpp LLM, with Japanese UI and TTS. Trigger when the user wants a "similar app", a new MRBD chatbot / assistant / tutor / guide that follows the dat-link / Interview recipe (Heroku + cloudflared + Gemma 4 + glassmorphism + ja-JP voice).
---

# MRBD LLM App — reusable recipe

A complete recipe for building Meta Ray-Ban Display Web Apps that use a
phone- or Mac-side `llama.cpp` LLM as the brain, with Japanese UI and
server-streamed Japanese TTS. The canonical implementation lives at
`~/dat-link` (`Interview`, a mock-interview chatbot). New apps follow
the same skeleton; only a handful of knobs change.

## When to invoke this skill

- The user says "similar to Interview / dat-link" or "another MRBD app"
- The user wants a new Ray-Ban Display assistant, tutor, guide, Q&A
- The user wants voice-driven chat on the glasses with a local LLM
- The user wants to build any of the personas listed under
  **Sample personas** below

## Architecture (do not change without reason)

```
[Mac]
  llama-server -m gemma-4-E2B-it-Q8_0.gguf -c 8192 --port 8080
  cloudflared tunnel --url http://localhost:8080 --protocol http2
                                ↓ public HTTPS URL
                          【Heroku Node app】
                          - in-memory conversation
                          - /v1/chat/completions proxy with
                            chat_template_kwargs: enable_thinking=false
                          - /api/tts MP3 proxy
                          - SSE broadcast
                                ↑
                ┌───────────────┴───────────────┐
            [スマホ /input]                  [MRBD /]
            text + Web Speech (ja-JP)        glassmorphism viewer,
                                              <audio> /api/tts,
                                              D-pad nav
```

## File structure to produce

```
<app>/
├── server.js              # Express + SSE + llama proxy + TTS proxy
├── package.json           # express dep, "node server.js"
├── Procfile               # web: node server.js
├── .env.example           # LLAMA_URL, MODEL, PORT
├── .gitignore             # node_modules, .env
├── README.md
└── chat/public/
    ├── index.html         # MRBD viewer (600x600, ja UI, TTS)
    ├── input.html         # phone input (Web Speech STT ja-JP)
    └── manifest.webmanifest
```

Easiest path: copy `~/dat-link` to a new directory, then change the
knobs below.

## Customization knobs (the only things that change per app)

| In `server.js` | What to set |
| --- | --- |
| `BASE_PROMPT` | The AI persona system prompt |
| `HINT_PROMPT` | What "hint mode" should produce (optional) |
| `END_PROMPT` | What "end / summarize" should produce (optional) |
| `SUGG_TEMPLATES` | Per-category MECE direction + few-shot example |
| `CATEGORIES`     | 3 themes with `name`, `focus`, `intro`, `suggs[2]` |

| In `chat/public/index.html` | What to set |
| --- | --- |
| `<title>` | App name |
| `.brand` | Top-bar label, e.g. `面接` → `料理` |
| `CATS` array | Three `{ id, label }` matching server CATEGORIES |
| Category-screen headline / subhead | Branding |
| `'面接官'` / `'ヒント'` / `'フィードバック'` labels | Re-label for the persona |

Everything else (D-pad nav, scroll, SSE, TTS, layout, glassmorphism)
stays as-is.

## Hard MRBD constraints (must not break)

- **Viewport**: `width=600, height=600, user-scalable=no`. `<body>`
  is `600×600`, `overflow: hidden`.
- **Input**: arrow keys + Enter only. No mouse, touch, keyboard, or
  mic. Every interactive element has `class="focusable"` and
  `min-height: 88px` (chips use `.chip` with `min-height: 116px`).
- **Display is additive**: black background must remain. Use bright,
  high-contrast colours (`#7cf6c8` accent, `#fff` text).
- **Min font**: 16 px for body, 20-24 px for primary content.
- **No scroll on the page** at the body level. Inside the content
  area, use `overflow-y: auto` with `justify-content: flex-start`
  (never `center` — it clips top/bottom on overflow). Up/Down keys
  scroll content first, then move focus.
- **HTTPS only** for the Web App URL. Use Heroku, Render, Vercel, etc.
  The llama.cpp endpoint also must be HTTPS — Cloudflare Tunnel is
  the simplest way.
- **Web Speech STT** runs on the phone only (`input.html`). MRBD has
  no mic.
- **TTS** must come from the server. MRBD's browser doesn't ship
  Japanese voices, so `speechSynthesis` plays on the Mac preview tab
  instead of the glasses. Stream MP3 from `/api/tts`.

## Gemma 4 specifics (these bit us; do not redo)

- Gemma 4 supports the native `system` role. Use it. Do **not** fold
  the system prompt into a `user` message.
- Default sampling: `temperature=1.0, top_p=0.95, top_k=64`.
- Thinking mode is **on by default** in the template and will consume
  the entire `max_tokens` budget on `reasoning_content`, leaving
  `content` empty. Always pass:
  ```json
  "chat_template_kwargs": { "enable_thinking": false }
  ```
- Recommended model file: `gemma-4-E2B-it-Q8_0.gguf` (≈4.6 GB,
  Google's "SFP8" closest equivalent). Q4_0 (3.2 GB) is fine on
  phones.

## Suggestion-generation recipe (do not regress)

`generateSuggestions` must:
1. Filter `kind: 'hint' | 'end'` out of history
2. Pull out the **latest assistant turn** and pass it as the explicit
   "面接官 (or persona) が今投げかけた質問: 「...」"
3. Use a single-turn `[{role:'system', content: suggSystemPrompt(cat)},
   {role:'user', content: userPrompt}]` request (not the whole chat
   thread — Gemma 4 will emit EOS on token 1 if the thread ends in an
   assistant turn)
4. Ask for **exactly 2** MECE candidates, each ≤ 60 chars
5. Per-category direction template + few-shot example (see
   `SUGG_TEMPLATES` in dat-link's `server.js`)
6. `temperature=0.4` for tight alignment

## TTS recipe

- Server: `/api/tts?text=...&lang=ja` proxies to
  `https://translate.googleapis.com/translate_tts` (the `.com` host
  is geo-blocked from some clouds; use `googleapis.com`). Returns
  `audio/mpeg`, cap text at 200 chars per request.
- Client: split message on `[。！？\n]` into ≤180-char chunks, queue
  through a single `<audio>` element. Token-based abort so user
  actions silence in-flight playback.
- `localStorage.tts === 'off'` mutes the device — use this so the Mac
  preview tab can be silenced without affecting MRBD.

## Deploy recipe

```sh
# 1. New repo
cp -R ~/dat-link ~/my-new-app && cd ~/my-new-app
rm -rf .git node_modules .env
git init && git add -A && git commit -m "scaffold from dat-link"

# 2. Customize the knobs above. Run locally to sanity check.
node --check server.js

# 3. Heroku
heroku create my-new-app
heroku config:set LLAMA_URL=https://<tunnel>.trycloudflare.com
heroku config:set MODEL=gemma
git push heroku HEAD:main
heroku open -a my-new-app

# 4. MRBD registration
# Generate fb-viewapp deep link QR:
#   fb-viewapp://web_app_deep_link?appName=<App>&appUrl=<urlencoded>
# Scan with phone camera → Meta AI app adds the Web App.
```

## Sample personas (starter values)

Use these as starting points and adapt the language. The
`SUGG_TEMPLATES[cat].directions` field is what makes the chips
feel domain-aware — invest there.

### 1. 模擬面接 (Interview practice) — the original

Already implemented in dat-link. Reference for everything else.

### 2. 料理ガイド (Cooking guide)

- `BASE_PROMPT`: 「あなたは経験豊富な料理講師です。日本の家庭料理を中心に、ユーザーの質問に応じて手順を1つずつ簡潔に教えてください。1ターン80文字以内、必ず次に進むかどうかを問いかけて締める。」
- Categories: `washoku` (和食) / `yoshoku` (洋食) / `quick` (時短)
- Suggestion directions per category, e.g. washoku: (1)使う食材を確認 (2)次の手順を進める

### 3. 英会話練習 (English conversation tutor)

- `BASE_PROMPT`: 「あなたは英会話の先生です。日本語でやさしくシナリオを設定し、英語フレーズを1つだけ提示してユーザーに発音や応答を促してください。1ターン80文字以内。」
- Categories: `daily` / `business` / `travel`

### 4. 健康ルーティン (Daily health routine)

- `BASE_PROMPT`: 「あなたは健康コーチです。ユーザーの今日の状態を1問ずつ聞き、無理のない次の一歩を1つだけ提案してください。1ターン80文字以内。」
- Categories: `morning` / `meal` / `sleep`

### 5. 観光案内 (Tourism / point-of-interest guide)

- `BASE_PROMPT`: 「あなたは地元の観光ガイドです。ユーザーの興味に応じて、近隣の見どころを1つだけ紹介してください。距離や所要時間を必ず含める。1ターン80文字以内。」
- Categories: `food` / `history` / `nature`

## Workflow when this skill is invoked

1. Ask the user (briefly) for: app name, persona one-liner, 3 categories.
2. Copy `~/dat-link` to a new directory (or scaffold the files
   directly if no source is available).
3. Rewrite the knobs listed in **Customization knobs** based on the
   user's answers. Keep everything else identical.
4. Run `node --check server.js` and a smoke test of `/api/category`.
5. Walk the user through Heroku create + cloudflared + QR registration.
6. Iterate on suggestions / system prompt with the live MRBD as the
   feedback loop.

## Anti-patterns (don't do these — we already tried)

- Folding the system prompt into a user message for Gemma 4 (works
  for Gemma 2, regresses with 4)
- Asking for 5 suggestions (signal-to-noise drops; 2 is the sweet
  spot)
- `justify-content: center` on a scrollable content area
- Three vertical full-width category buttons on the FEEDBACK view
  (no room left for the feedback text — use 3 horizontal columns)
- Relying on `speechSynthesis` for the glasses (no ja voice on MRBD)
- Quick Cloudflare Tunnel + auto-restarts (URL changes; either move
  to a Named Tunnel with a stable subdomain or accept that
  `heroku config:set LLAMA_URL=...` is a per-session step)
