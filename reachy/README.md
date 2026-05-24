# Reachy Link

A Meta Ray-Ban Display Web App that shows what **Reachy Mini** is saying as a
floating AR-style speech bubble, plus an emotion icon, connection status, and a
command menu to drive the robot. Audio stays on the Reachy (the glasses only
show text).

```
[Reachy Mini]  mini_voice.py + reachy_link.py
   │  POST /api/speech   (spoken text + emotion + state)
   │  GET  /api/commands (pull control commands  ← also the heartbeat)
   ▼
[Relay]  server.js  (Express + SSE, in-memory state)
   ▲  SSE /api/events (speech / status / command / error)
   │  POST /api/command
   ├──────────────► [Meta Ray-Ban Display]  /            (the AR viewer)
   └──────────────► [Phone]                  /control     (big-button control)
```

The relay is a self-contained Node app under `reachy/`. The only dependency is
`express`.

## Run the relay

```sh
cd reachy
npm install
npm start            # listens on :4000 (PORT to override)
```

- MRBD viewer:  `http://localhost:4000/`
- Phone control: `http://localhost:4000/control`
- Health check:  `http://localhost:4000/api/health`

The glasses need **HTTPS**. On the LAN, expose the relay with a tunnel:

```sh
cloudflared tunnel --url http://localhost:4000
```

Use the printed `https://…trycloudflare.com` URL both for MRBD registration and
as `RELAY_URL` on the Reachy side. (Or deploy the relay to Heroku — see below —
and point the Reachy at the Heroku HTTPS URL.)

## Wire it into the Reachy conversation app

Copy `reachy_link.py` next to `mini_voice.py` on the Reachy, then add a few
calls to the loop in `mini_voice.py`:

```python
import reachy_link

# optional: let the glasses drive the robot
def handle_command(command, params):
    # map command -> your Reachy Mini SDK motion
    # e.g. look_left / look_right / nod / shake_head / wave / dance / stop ...
    print("command:", command)
reachy_link.start_command_listener(handle_command)

# inside the while loop:
reachy_link.post_state("listening")                       # before record()
user_text = transcribe(wav)
reachy_link.post_speech(user_text, speaker="user", state="listening")

reachy_link.post_state("thinking")                        # before generate_reply()
reply = generate_reply(user_text)
reachy_link.post_speech(reply)                            # shown big on the glasses

speech = synthesize(reply)
play(speech)                                              # audio plays from Reachy
reachy_link.post_state("idle")
```

Set the relay URL on the Reachy before launching:

```sh
export RELAY_URL="http://192.168.3.5:4000"   # or the cloudflared / Heroku URL
```

`post_speech` / `post_state` never raise — a down relay can't break the
conversation. The relay infers an emotion from the text when `mini_voice.py`
doesn't pass one explicitly.

### Test without the robot

`reachy_link.py` runs standalone: it posts demo speech and prints any commands
the glasses send, so you can verify the whole chain end-to-end.

```sh
RELAY_URL=http://localhost:4000 python3 reachy_link.py "テストです"
```

Open `/` and `/control`, press a command button, and watch it print.

## Commands

`look_left` · `look_right` · `look_up` · `look_down` · `look_user` · `nod` ·
`shake_head` · `wave` · `dance` · `happy` · `surprised` · `thinking` · `idle` ·
`excited` · `start_conversation` · `pause_conversation` · `stop` · `clear_text`

`stop` is always one step away in the viewer (the red full-width button on the
main screen) as an emergency halt. `clear_text` clears the on-glasses
transcript.

## API

| Method | Path | Who | Body / result |
| --- | --- | --- | --- |
| GET  | `/api/events`   | viewer / control | SSE: `snapshot`, `speech`, `status`, `command`, `clear`, `error`, `ping` |
| POST | `/api/speech`   | Reachy | `{ text, speaker?, emotion?, state? }` |
| POST | `/api/state`    | Reachy | `{ state, emotion? }` |
| GET  | `/api/commands` | Reachy | `{ commands: [...] }` (drains the queue; heartbeat) |
| POST | `/api/command`  | viewer / control | `{ command, params? }` |
| POST | `/api/clear`    | any | clears the transcript |
| GET  | `/api/health`   | any | diagnostics |

## Deploy the relay to Heroku

The relay is a subdirectory of this repo, so the simplest path is to copy it out
to its own repo (matches the dat-link deploy recipe):

```sh
cp -R reachy ~/reachy-link && cd ~/reachy-link
git init && git add -A && git commit -m "scaffold reachy-link"
heroku create my-reachy-link
git push heroku HEAD:main
heroku open
```

Then set `RELAY_URL` on the Reachy to the Heroku URL and register the same URL
on MRBD (Meta AI app → Devices → Display Glasses → App connections → Web apps →
Add). A deep link works too:
`fb-viewapp://web_app_deep_link?appName=Reachy&appUrl=<urlencoded https URL>`.

## MRBD notes

- Viewport is locked to 600×600; input is arrow keys + Enter only.
- Black is transparent on the display, so the real Reachy shows through and the
  bubble floats near it. Up/Down scrolls long speech/history before moving focus;
  Left/Right and Enter drive the menu; Esc returns to the main screen.
- No TTS on the glasses by design — the voice comes from the Reachy speaker.
