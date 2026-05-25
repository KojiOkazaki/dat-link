---
name: reachy-glass-link
description: Mirror a Reachy Mini's spoken replies onto Meta Ray-Ban Display glasses as a cyber AR speech bubble (typewriter reveal), show robot state/emotion + connection, and drive the robot from the glasses / Neural Band (look, nod, wave, dance, start conversation hands-free). Builds on the reachy-voice-chat pipeline. Stack = a tiny relay (Express + SSE + 1s polling) + an MRBD viewer + reachy_link.py (post speech/state, pull commands) + reachy_moves.py (command → motion) + cloudflared. Trigger when the user wants Reachy speech on the glasses, glasses/band control of Reachy, or to rebuild/debug this (tunnel URL churn, SSE buffering, "Too many open files", Mac IP change, daemon/motion).
---

# Reachy Mini ⟷ Meta Ray-Ban Display link — reusable recipe

Adds AR glasses to a Reachy Mini voice chat. The robot keeps talking with its
own voice (the **reachy-voice-chat** skill); this layer shows the **same text**
on the glasses and lets the glasses/Neural Band **drive the robot**. Audio
stays on the Reachy — the glasses show **text only** (no TTS on the glasses).

The canonical, working implementation is committed at **`~/dat-link/reachy/`**.
Reuse those files; don't rewrite from scratch.

## Architecture (3 layers)

```
[Reachy Mini]  mini_voice.py + reachy_link.py + reachy_moves.py
   │  POST /api/speech  {text,emotion,state,speaker}   (Reachy → glasses text)
   │  POST /api/state   {state,emotion}
   │  GET  /api/commands  (pull queued commands ← also the heartbeat)
   ▼
[Relay]  reachy/server.js  (Express, in-memory state)
   ▲  GET /api/snapshot   (viewer/phone POLL this every 1s — NOT SSE, see gotcha)
   │  POST /api/command   {command}
   ├────────► [MRBD viewer]  reachy/public/index.html   (cyber AR bubble + menu)
   └────────► [Phone]        reachy/public/control.html  (big-button control)
[Mac]  node server.js (:4000)  +  cloudflared (HTTPS tunnel for the glasses)
       +  Ollama + VOICEVOX (from reachy-voice-chat)
```

## Canonical files (in `~/dat-link/reachy/`)

| File | Role |
| --- | --- |
| `server.js` | Relay: `/api/speech`, `/api/state`, `/api/command`, `/api/commands`, **`/api/snapshot`** (poll), `/api/health`. In-memory `latest`/`history`/`status`, command queue, heartbeat (robot ON/OFF), keyword emotion inference. |
| `public/index.html` | MRBD viewer (600×600). Cyan neon HUD, **typewriter** speech bubble (cyan text, blinking block cursor, scrollable), emotion/state/mic/spk/robot chips, D-pad menu MOVE/EMOTION/ACTION/TALK + red STOP with per-category focus colours. Polls `/api/snapshot`. |
| `public/control.html` | Phone control surface (same commands, big touch targets). Polls `/api/snapshot`. |
| `reachy_link.py` | Reachy-side client, **stdlib only (urllib)**: `post_speech`, `post_state`, `poll_commands`, `start_command_listener(handler)`. |
| `reachy_moves.py` | `command_motion(command)` → reachy_mini SDK moves (look/nod/shake/wave/dance/emotes). **Uses ONE shared `ReachyMini` connection (singleton)** — see gotcha. |
| `README.md` | Run + wire-up + deploy notes. |

## Bring it up

1. Get the reachy-voice-chat pipeline working first (mini_voice.py talks).
2. **Mac** — relay + HTTPS tunnel, backgrounded so they don't die:
   ```sh
   cd ~/dat-link/reachy && npm install
   nohup node server.js > /tmp/reachy-relay.log 2>&1 &
   nohup cloudflared tunnel --url http://127.0.0.1:4000 > /tmp/cf.log 2>&1 &
   sleep 6; grep -a trycloudflare /tmp/cf.log | tail -1     # the public HTTPS URL
   ```
   Register that `https://….trycloudflare.com` on the glasses
   (Meta AI app → Display → App connections → Web apps → Add). Open `/` for the
   viewer, `/control` on a phone.
3. **Reachy** — drop `reachy_link.py` and `reachy_moves.py` next to
   `mini_voice.py` (create with `cat > ~/reachy_link.py <<'PY' … PY` — avoids
   scp), set `RELAY_URL`, and patch `mini_voice.py` (below).

   ```sh
   export RELAY_URL="http://<MAC>.local:4000"     # Mac .local name, not a raw IP
   ```

## mini_voice.py integration (patch points)

```python
import reachy_link                                   # top of file

def main():
    import threading as _th
    _start_turn = _th.Event()                         # hands-free START trigger
    def _on_command(command, params):
        if command == "start_conversation":
            _start_turn.set(); return                 # glasses TALK→START starts a turn
        if command == "pause_conversation":
            return
        try:
            import reachy_moves
            reachy_moves.command_motion(command)      # MOVE/EMOTION/ACTION → real motion
        except Exception as e:
            print("cmd motion error:", e)
    reachy_link.start_command_listener(_on_command)   # also keeps robot ON (1s heartbeat)
    def _enter_watch():
        while True:
            try: input()
            except EOFError: return
            _start_turn.set()                         # Enter still works too
    _th.Thread(target=_enter_watch, daemon=True).start()

    while True:
        # replace input("Enterで録音開始") with:
        _start_turn.wait(); _start_turn.clear()
        reachy_link.post_state("listening")           # → glasses LISTENING / 🎤
        wav = record(...)
        user_text = transcribe(wav)
        reachy_link.post_speech(user_text, speaker="user", state="listening")
        reachy_link.post_state("thinking")            # → glasses THINKING
        reply = generate_reply(user_text)
        reachy_link.post_speech(reply)                # → glasses bubble (the key requirement)
        speech = synthesize(reply); play(speech)      # audio stays on the Reachy
        reachy_link.post_state("idle")
```

Note: `post_speech(reply)` runs **before** `synthesize()`, so the glasses show
the reply even if VOICEVOX is down (only the voice is lost).

## Commands

`look_left/right/up/down/look_user · nod · shake_head · wave · dance · happy ·
surprised · thinking · idle · excited · start_conversation · pause_conversation
· stop · clear_text`. STOP is always one step away in the viewer.

## Gotchas (hard-won — read first)

- **SSE is buffered by Cloudflare quick tunnels** → the glasses got the initial
  snapshot but no live updates (speech/status never arrived), while POST
  commands worked. **Use 1-second polling of `GET /api/snapshot`**, not
  `EventSource`. The viewer/control already do this.
- **`Too many open files` → SSH drops** → `command_motion` (or any motion) must
  reuse **one** `ReachyMini("localhost")` connection (module-level singleton in
  `reachy_moves.py`). Opening a connection per button press leaks FDs and
  crashes the box, especially when mashing buttons.
- **Tunnel URL changes every cloudflared restart** → the old
  `…trycloudflare.com` 404s/NXDOMAINs; re-register the new URL on the glasses.
  For a stable URL set up a Cloudflare **named tunnel** (free account) — stops
  the re-registration loop.
- **Mac IP changes between sessions** → `RELAY_URL` (and the Ollama/VOICEVOX
  URLs) should use the Mac's **`.local` name** (`scutil --get LocalHostName`),
  not a hardcoded IP. `No route to host` from the Reachy = Mac slept or its IP
  moved.
- **Motion needs the daemon** (`reachy-mini-daemon.service` running). All
  glasses-driven moves and the speak-while-talking motion "skip" if it's
  stopped. Keep it running.
- **Audio is Reachy-only by design** (requirement): the glasses render text;
  there is no TTS/`<audio>` on the viewer.
- **Wrong-machine commands** waste the most time. `hostname` →`reachy-mini`
  for Reachy commands; the relay/tunnel/Ollama/VOICEVOX commands are on the
  Mac. `mini_voice.py` / `reachy_link.py` / `reachy_moves.py` /
  `~/.reachy_voice_env` are on the **Reachy** (creating them on the Mac is a
  classic dead end).
- **`ASR_MODEL` empty** still bites here too — see the reachy-voice-chat skill.

## MRBD viewer conventions (already implemented; keep them)

- Viewport locked `600×600`, input is arrow keys + Enter only, black background
  (transparent on the display so the real Reachy shows through).
- Arrows move focus between menu buttons (with wrap); the speech bubble joins
  the focus ring **only when it overflows**, so Up/Down scroll it then return
  to the menu — button nav is never blocked.
- Per-category neon focus colours (MOVE cyan / EMOTION magenta / ACTION amber /
  TALK blue / STOP red); monochrome inline-SVG icons (no emoji); typewriter
  reveal with blinking block cursor; cyan neon body text.
- See the **`mrbd-llm-app`** skill for the broader MRBD web-app constraints.

## Tuning knobs

- Typewriter speed: `typeInto`'s interval (ms/char) in `index.html`.
- Bubble font / height: `.btext` `font-size` / `max-height`.
- Text colour: `.btext` `color` (default `var(--cy)` = #1ef0e0).
- Command motions: edit the per-command branches in `reachy_moves.py`
  (look amplitudes, antenna values, recorded-move filenames).
