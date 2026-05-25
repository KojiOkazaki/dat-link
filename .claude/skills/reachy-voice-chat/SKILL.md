---
name: reachy-voice-chat
description: Stand up a custom Japanese voice conversation on a Reachy Mini robot WITHOUT the official conversation app and WITHOUT AR glasses. Pipeline is USB mic → Hugging Face Whisper STT → Mac Ollama (Gemma) → Mac VOICEVOX TTS → Reachy speaker, plus antenna/head motion via the reachy_mini SDK. Trigger when the user wants Reachy Mini to talk/converse in Japanese with a Mac/local LLM, set up or edit mini_voice.py, or debug that pipeline (ASR "Model not supported", no audio, motion not moving, "No route to host", "Too many open files").
---

# Reachy Mini voice chat (no glasses) — reusable recipe

A from-scratch Japanese voice loop on a **Reachy Mini**, independent of the
official `reachy_mini_conversation_app`. The robot listens on a USB mic,
transcribes with Hugging Face Whisper, generates a reply with a Mac-side
Ollama model, synthesizes speech with Mac-side VOICEVOX, and plays it on the
Reachy speaker — while moving its antennas/head.

This skill is the **base**. To also mirror the speech onto Meta Ray-Ban
Display glasses and drive the robot from the glasses, layer the
**`reachy-glass-link`** skill on top.

## Two machines — internalize this first

Almost every failure in this project traced back to running a command on the
wrong machine. There are two:

| Machine | Prompt looks like | Runs |
| --- | --- | --- |
| **Mac** | `okazakikouji@...MacBook-Air %` | Ollama, VOICEVOX (Docker), (later) relay + cloudflared |
| **Reachy** | `pollen@reachy-mini:~ $` | `mini_voice.py`, `reachy_link.py`, the daemon |

Rules:
- Before running anything, confirm the machine with `hostname` (`reachy-mini`
  = Reachy; anything else = Mac).
- Get onto the Reachy with `ssh pollen@reachy-mini.local` (password is
  invisible while typing — that's normal). If it just hangs with no prompt,
  the Reachy is off / not on the LAN (`ping -c3 reachy-mini.local` →
  `Unknown host` confirms).
- `~/.reachy_voice_env`, `mini_voice.py`, `reachy_link.py` live on the
  **Reachy**. Editing the Mac's copies is the #1 time sink.

## Architecture

```
[Reachy Mini]  mini_voice.py
  USB mic ─ arecord ─► /tmp wav
        └─► HF Whisper (STT)        https://router.huggingface.co/hf-inference/models/<ASR_MODEL>
        └─► Mac Ollama (reply)      http://<MAC>:11434/api/chat
        └─► Mac VOICEVOX (TTS)      http://<MAC>:50021
        └─► aplay ─► Reachy speaker
        └─► reachy_mini SDK ─► antenna/head motion (needs the daemon running)
[Mac]  Ollama serve (0.0.0.0:11434) + VOICEVOX Docker (0.0.0.0:50021)
```

## Mac setup (run on the Mac, keep them alive)

Run services bound to **0.0.0.0** (not just localhost) so the Reachy can
reach them, and background them so they survive:

```sh
# Ollama (pick a model you have: gemma4:e4b, gemma3:4b, llama3.2:3b …)
pkill ollama 2>/dev/null; sleep 1
OLLAMA_HOST=0.0.0.0:11434 nohup ollama serve > /tmp/ollama.log 2>&1 &

# VOICEVOX (needs Docker Desktop running)
open -a Docker
docker run -d --name voicevox -p 0.0.0.0:50021:50021 voicevox/voicevox_engine:cpu-latest
# later: docker start voicevox
```

Find the Mac address the Reachy should use. **Prefer the Mac's `.local`
name over its IP — the IP changes between sessions (DHCP) and breaks
everything ("No route to host").**

```sh
scutil --get LocalHostName    # e.g. okazakikoujinoMacBook-Air  → use okazakikoujinoMacBook-Air.local
ipconfig getifaddr en0        # the current IP, fallback if .local won't resolve from the Reachy
```

## Reachy setup

### mini_voice.py pipeline (the loop)

```
input("Enter で録音開始")          # gate (the glasses skill makes this hands-free)
record()      → arecord USB mic, ffmpeg normalize → /tmp/reachy_user.wav
transcribe()  → POST wav to HF Whisper, returns text
generate_reply() → POST to Ollama /api/chat (system prompt = persona, "1〜2文")
synthesize()  → VOICEVOX /audio_query + /synthesis → wav
play()        → ffmpeg gain + aplay on the Reachy speaker
gesture()/speaking_motion() → reachy_mini SDK antenna/head moves
```

Motion helpers inside the file use the official SDK:
`r = ReachyMini("localhost"); r.enable_motors()`, then
`r.look_at_world(x, y, z)` (y = left/right), `r.set_target_body_yaw(yaw)`,
`r.set_target_antenna_joint_positions([left, right])`, and
`r.play_move(RecordedMove(...))` for recorded moves (e.g. `simple_nod.json`
from the `pollen-robotics/reachy-mini-dances-library` HF cache).

### Environment (`~/.reachy_voice_env`, sourced before launch)

```sh
export HF_TOKEN="hf_xxx"
export ASR_MODEL="openai/whisper-large-v3-turbo"        # see gotcha below
export MIC_DEVICE="plughw:CARD=Audio_1,DEV=0"           # external USB mic (built-in records silence)
export SPEAKER_DEVICE="plughw:0,0"
export OLLAMA_URL="http://<MAC>.local:11434/api/chat"   # MAC = scutil LocalHostName, NOT a raw IP
export OLLAMA_MODEL="gemma4:e4b"
export VOICEVOX_URL="http://<MAC>.local:50021"
export VOICEVOX_SPEAKER="2"
export VOICEVOX_VOLUME="1.0"
export PLAYBACK_FILTER="volume=18dB,alimiter=limit=0.98"   # no loudnorm — see gotcha
export RECORD_SECONDS="6"
```

### Launch

```sh
source ~/.reachy_voice_env
sudo systemctl start reachy-mini-daemon.service   # REQUIRED for motion (see gotcha)
/venvs/mini_daemon/bin/python ~/mini_voice.py
```

Sanity-check reachability from the Reachy first:
```sh
curl -s "http://<MAC>.local:11434/api/tags" | head -c 30   # {"models" …
curl -s "http://<MAC>.local:50021/version"                 # "0.x.x"
```

## Gotchas (each cost real time — read before debugging)

- **`ASR failed: Model not supported by provider hf-inference`** → `ASR_MODEL`
  is **empty or unsupported**. An empty env value is passed through verbatim
  (no default kicks in) and fails. Use `openai/whisper-large-v3-turbo`
  (fast) or `openai/whisper-large-v3`. `whisper-small/base/distil-*` were
  **not** served by `hf-inference`. Verify a model directly:
  `curl -s -X POST ".../hf-inference/models/<M>" -H "Authorization: Bearer $HF_TOKEN" -H "Content-Type: audio/wav" --data-binary @/tmp/reachy_user.wav`.
- **`No route to host` / `Connection refused` to the Mac** → the Mac slept or
  its **IP changed**. Use the Mac's `.local` name in the URLs so IP changes
  don't matter; otherwise update `OLLAMA_URL`/`VOICEVOX_URL` to the new IP.
- **Motion does nothing / `Auto connection … daemon … failed`** → the Reachy
  **daemon is stopped**. The manual's "stop the daemon for audio" kills all
  motion. In practice the daemon coexists with the USB mic + speaker, so
  **keep it running** (`systemctl start`). Motion needs it.
- **`Too many open files` then SSH drops** → something created a new
  `ReachyMini("localhost")` connection per call and leaked file descriptors.
  **Reuse ONE connection** (module-level singleton) for repeated motion; never
  open one per gesture/command in a tight loop.
- **`gesture("nod")` looks like it does nothing** → in the reference file the
  `else`/default branch only re-centers. Real visible moves are `happy`
  (body sway), `thinking` (head turn), and `talking` (the recorded
  `simple_nod.json`). Map your intents to those or drive `look/body/antenna`
  directly.
- **Voice too quiet even at high dB** → `loudnorm` in `PLAYBACK_FILTER`
  normalizes/caps loudness. Drop it: `volume=18dB,alimiter=limit=0.98`
  (raise dB for louder; lower if it distorts).
- **Feels slow** → biggest win is `ASR_MODEL=…-turbo`; then lower
  `RECORD_SECONDS`, a lighter `OLLAMA_MODEL` (3–4B), and `VOICEVOX_SPEED=1.1`.
  Shorter replies (system prompt "1〜2文") help TTS + LLM latency.
- **Built-in mic records silence (-91 dB)** → use the external USB mic device
  by name (`plughw:CARD=Audio_1,DEV=0`); card numbers change on reconnect, so
  prefer the `CARD=` name.

## Keeping it stable across sessions

- Put everything in `~/.reachy_voice_env` **on the Reachy** and `source` it.
  Use the Mac `.local` name, not an IP.
- Mac services: background with `nohup`/`-d` so closing a terminal or running
  the next command doesn't kill them.
- A `~/start_reachy_voice.sh` that does `source ~/.reachy_voice_env` then
  launches `mini_voice.py` makes restarts one command.
