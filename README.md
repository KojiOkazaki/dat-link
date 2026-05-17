# dat-link

Two Web Apps for Meta Ray-Ban Display, sharing one repo.

| App | Where it runs | URL |
| --- | --- | --- |
| **Glance** (clock / weather / compass / counter) | GitHub Pages | https://kojiokazaki.github.io/dat-link/ |
| **Interview** (mock-interview chat with phone-side LLM) | Heroku (Node) | set after deploy |

---

## Glance

Static `index.html` + `manifest.webmanifest` at the repo root. GitHub Pages
serves them as-is. No build step.

## Interview

`server.js` is a small Express app that:

- Serves the MRBD viewer at `/` and the phone input UI at `/input`
- Holds the in-memory conversation
- Forwards user messages to a local `llama.cpp` server over HTTPS
- Streams new messages + AI-generated reply suggestions to all clients via SSE

### 1. Run llama.cpp on the phone and expose it over HTTPS

`server.js` reads `LLAMA_URL` and POSTs to `${LLAMA_URL}/v1/chat/completions`
(OpenAI-compatible). The phone must therefore expose llama.cpp at a public
HTTPS URL. Cloudflare Tunnel is the simplest path.

On a Mac or in Termux on the phone:

```sh
brew install llama.cpp cloudflared
llama-server -m ~/models/gemma-4-e2b-it-Q8_0.gguf -c 8192 --port 8080
# In another shell
cloudflared tunnel --url http://localhost:8080
```

`cloudflared` prints something like
`https://random-words.trycloudflare.com`. Use that as `LLAMA_URL`.

The server is tuned for Gemma 4 — it uses the native `system` role and
the recommended sampling (`temperature=1.0`, `top_p=0.95`, `top_k=64`).
Older Gemma 2 / Gemma 3 models will still respond, but Gemma 4 E2B/E4B
is the intended target.

### 2. Deploy to Heroku

```sh
heroku create kojiokazaki-interview
heroku config:set LLAMA_URL=https://random-words.trycloudflare.com
heroku config:set MODEL=gemma
git push heroku claude/meta-rayban-display-app-rsI9C:main
heroku open
```

### 3. Register on MRBD

Open the Heroku URL on phone Chrome with arrow keys and Enter to sanity-check.
Then add it to MRBD the same way as Glance (Meta AI app → Devices → Display
Glasses settings → App connections → Web apps → Add).

The phone-side input UI lives at `${HEROKU_URL}/input` — open it in mobile
Safari/Chrome to type or use voice input (Japanese, Web Speech API).
