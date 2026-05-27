---
name: reachy-venue-deploy
description: Make a Reachy Mini voice demo (with or without Meta Ray-Ban Display glasses) survive an uncontrolled venue — pocket/guest wifi, changing IPs, ephemeral tunnel URLs, SSH/wifi drops, crashes. The OPS/hardening layer on top of reachy-voice-chat / reachy-glass-link. Trigger when the user is preparing a demo / exhibition / proof-of-concept / 実証実験 at an event or career center, or hits "works sometimes, fails others", "can't load page", "No route to host", IP changed, tunnel URL keeps changing, SSH keeps dropping, "Too many open files", or wants one-command startup / auto-restart / stable URL / offline operation.
---

# Reachy demo — venue deployment hardening

Hard-won playbook for running the Reachy Mini voice demo (and the glasses link)
**reliably at a venue**. The app itself (`reachy-voice-chat` /
`reachy-glass-link`) is solid — what breaks at events is the **ops layer**:
network addressing, ephemeral URLs, process supervision, and operator error
under pressure. Fix those and "works sometimes / fails others" goes away.

> Core lesson from the field: **the features all worked; the infrastructure
> around them was fragile.** Every changeable/external dependency — DHCP IPs,
> quick-tunnel URLs, venue wifi, cloud STT, manual multi-process startup,
> Mac-vs-Reachy command mixups — is a failure point. Remove or pin each one.

## The six fragilities (and the fix for each)

| Fragility seen in the field | Fix |
| --- | --- |
| Mac IP changes between sessions → all URLs dead (`No route to host`) | Use the Mac's **`.local` name**, never a hardcoded IP |
| cloudflared **quick-tunnel URL changes every restart** → re-register on glasses each time | **Named tunnel** = permanent URL (register on glasses once) |
| Pocket/guest wifi: Reachy can't see SSID (5GHz), AP isolation, drops | **2.4GHz**, set regdomain, **disable wifi power-save**, test reachability, keep AP close |
| SSH/wifi drop kills the foreground app | Run the app **detached** (systemd / nohup / tmux) + power-save off |
| Cloud STT (HF Whisper) needs the venue internet | **Local STT** (faster-whisper on the Mac) → conversation works offline |
| Manual multi-process startup + Mac/Reachy mixups under pressure | **One-command launcher**, **auto-start services**, labeled terminals, checklist |

## 1. Stable addressing — `.local` everywhere, never raw IP

On the Mac: `scutil --get LocalHostName` → e.g. `okazakikoujinoMacBook-Air`.
Use `okazakikoujinoMacBook-Air.local` in every Reachy-side URL
(`RELAY_URL`, `OLLAMA_URL`, `VOICEVOX_URL`, `STT_URL`). mDNS survives IP
changes; raw IPs do not. (Confirm the Reachy can resolve it:
`ping -c2 <macname>.local`.)

## 2. Permanent glasses URL — Cloudflare **named tunnel**

Quick tunnels (`*.trycloudflare.com`) get a **new random URL every restart** →
endless glasses re-registration. A named tunnel gives a fixed
`https://reachy.yourdomain.com` you register **once**. Needs a free Cloudflare
account + a domain added to it.

```sh
cloudflared tunnel login
cloudflared tunnel create reachy
cloudflared tunnel route dns reachy reachy.yourdomain.com
# ~/.cloudflared/config.yml:
#   tunnel: reachy
#   credentials-file: /Users/you/.cloudflared/<UUID>.json
#   ingress:
#     - hostname: reachy.yourdomain.com
#       service: http://127.0.0.1:4000
#     - service: http_404
cloudflared tunnel run reachy     # always the same URL
```
No domain? Then accept quick-tunnel churn and **register the new URL on the
glasses each session** (and never restart cloudflared mid-demo).

## 3. Local STT — remove the cloud dependency

Cloud STT is the weakest link on flaky venue wifi. Run faster-whisper on the
Mac so audio never leaves the LAN; with this, the **voice loop is fully
offline** (only the glasses tunnel still needs internet).

```sh
# Mac (once): pip3 install flask faster-whisper   (first run downloads the model)
cat > ~/stt_server.py <<'PY'
import os, tempfile
from faster_whisper import WhisperModel
from flask import Flask, request, jsonify
model = WhisperModel(os.environ.get("STT_MODEL","medium"), device="cpu", compute_type="int8")
app = Flask(__name__)
@app.post("/transcribe")
def t():
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
        f.write(request.get_data()); p=f.name
    segs,_ = model.transcribe(p, language="ja", beam_size=1)
    txt="".join(s.text for s in segs).strip(); os.unlink(p)
    return jsonify({"text": txt})
app.run(host="0.0.0.0", port=5005)
PY
STT_MODEL=medium python3 ~/stt_server.py     # small=faster, large-v3=accurate
```
Reachy: `export STT_URL="http://<macname>.local:5005/transcribe"` (mini_voice's
`transcribe()` already prefers `STT_URL` if patched — see reachy-glass-link).
Unset `STT_URL` to fall back to HF cloud.

## 4. One-command Mac launcher

```sh
cat > ~/start_demo.sh <<'SH'
#!/bin/bash
curl -s localhost:11434/api/tags >/dev/null 2>&1 || { pkill ollama 2>/dev/null; sleep 1; OLLAMA_HOST=0.0.0.0:11434 nohup ollama serve >/tmp/ollama.log 2>&1 & }
curl -s localhost:50021/version >/dev/null 2>&1 || { open -a Docker; sleep 8; docker start voicevox 2>/dev/null || docker run -d --name voicevox -p 0.0.0.0:50021:50021 voicevox/voicevox_engine:cpu-latest; }
curl -s localhost:5005/ >/dev/null 2>&1 || ( STT_MODEL=${STT_MODEL:-medium} nohup python3 ~/stt_server.py >/tmp/stt.log 2>&1 & )   # local STT (optional)
curl -s localhost:4000/api/health >/dev/null 2>&1 || ( cd ~/dat-link/reachy && nohup node server.js >/tmp/reachy-relay.log 2>&1 & )
# Quick tunnel (skip if using a named tunnel):
pkill -f "cloudflared tunnel" 2>/dev/null; sleep 1; nohup cloudflared tunnel --url http://127.0.0.1:4000 >/tmp/cf.log 2>&1 &
sleep 8
MAC=$(scutil --get LocalHostName).local
echo "===== READY ====="; echo "Mac host: $MAC"
echo "Glasses : $(grep -ao 'https://[a-z0-9-]*\.trycloudflare\.com' /tmp/cf.log | tail -1)"
echo "Reachy  : export RELAY_URL=http://$MAC:4000 OLLAMA_URL=http://$MAC:11434/api/chat VOICEVOX_URL=http://$MAC:50021 STT_URL=http://$MAC:5005/transcribe"
SH
chmod +x ~/start_demo.sh
```
Verify the **whole path** with curl before trusting the browser/glasses:
`curl -s https://<tunnel-or-named-url>/api/health` → must return `{"ok":true...}`.

## 5. Reachy: survive drops + auto-start

Disable wifi power-save (stops idle drops) and run the app **detached** so an
SSH/wifi blip never kills it:

```sh
sudo iw dev wlan0 set power_save off
sudo systemctl stop reachy-mini-daemon.service     # frees the speaker for aplay (see note)
nohup /venvs/mini_daemon/bin/python ~/mini_voice.py > /tmp/voice.log 2>&1 &
tail -f /tmp/voice.log    # watch; Ctrl+C leaves the app running
```

For a kiosk, make it a service that auto-starts on boot and restarts on crash
(`/etc/systemd/system/reachy-voice.service`):
```ini
[Unit]
Description=Reachy voice chat
After=network-online.target
Wants=network-online.target
[Service]
User=pollen
EnvironmentFile=/home/pollen/.reachy_voice_env
ExecStartPre=/bin/sh -c 'iw dev wlan0 set power_save off || true'
ExecStartPre=/bin/sh -c 'systemctl stop reachy-mini-daemon.service || true'
ExecStart=/venvs/mini_daemon/bin/python /home/pollen/mini_voice.py
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
```
`sudo systemctl enable --now reachy-voice`. Driven hands-free by the glasses
TALK→START (keyboard Enter won't work without a TTY — that's fine; the
`_enter_watch` thread error is harmless).

## 6. Wifi pre-config (do this BEFORE the venue, on the real network)

- **Reachy radio is effectively 2.4GHz** → the venue/pocket wifi must broadcast
  2.4GHz (5GHz-only SSIDs are invisible to it).
- Pre-join so it auto-connects on the day:
  `sudo nmcli device wifi connect "<SSID>" password "<pass>"`
- If the SSID won't appear: `sudo iw reg set JP; sudo raspi-config nonint do_wifi_country JP; sudo nmcli device wifi rescan` (unlocks 2.4GHz ch 12-13), and fix the AP to ch 1-11 if possible.
- **AP-isolation test** (both on the venue wifi): from the Reachy
  `ping -c2 <macname>.local` AND `curl http://<macname>.local:4000/api/health`.
  No reply = client isolation on → disable it on the AP, or **bring your own
  router/hotspot** you control.
- Keep the AP physically next to the Reachy (signal).

## 7. The audio ↔ motion conflict (known limitation)

The reachy_mini SDK uses WebRTC **bidirectional audio**, so any SDK connection
(motion via the daemon, or `command_motion`) grabs the speaker → `aplay` fails
`Device or resource busy`. Today's reliable choice: **daemon OFF = voice + glasses
work, no physical motion.** Proper fix (post-demo): play TTS **through the SDK**
(e.g. `r.play_sound`) instead of `aplay`, so audio + motion share one owner.
Also reuse **one** `ReachyMini` connection (singleton) — opening one per command
leaks FDs → `Too many open files` → crash.

## 8. Operator discipline (this cost the most time)

- **Always know the machine.** `hostname` → `reachy-mini` = Reachy; else Mac.
  Reachy commands (`iw`, `nmcli`, `/venvs/...python`, `sudo systemctl`) fail on
  the Mac; relay/tunnel/Ollama/VOICEVOX live on the Mac.
- Put URLs in the **browser address bar**, never the terminal.
- `~/.reachy_voice_env`, `mini_voice.py`, `reachy_link.py`, `reachy_moves.py`
  live on the **Reachy** (creating them on the Mac is a dead end).
- **Rehearse on the actual venue network, days ahead, full run, several times.**

## 9. Graceful fallback (design the demo for it)

`reachy_link` posts are best-effort, so **if the glasses/tunnel die, the robot
keeps conversing** — the demo auto-degrades from ② (glasses) to ① (voice only).
Always have "talk to the robot" as the can't-fail baseline; the glasses are the
bonus. Decide up front what the minimum viable demo is and make sure that path
needs the fewest dependencies.

## Pre-flight checklist (print it)

- [ ] Reachy auto-joins the venue wifi (2.4GHz, pre-saved); `power_save off`
- [ ] Mac + Reachy on the **same** wifi; `ping <macname>.local` works both ways
- [ ] `~/start_demo.sh` brings up relay + Ollama + VOICEVOX + (local STT) + tunnel
- [ ] `curl https://<url>/api/health` → `{"ok":true}` (verify the full path)
- [ ] Glasses registered with the **current** URL; **phone has internet**
- [ ] mini_voice running **detached** (systemd/nohup); `tail /tmp/voice.log` shows the prompt
- [ ] Speak a test turn → voice out + glasses text + (TALK→START works)
- [ ] Fallback rehearsed: glasses off → robot still converses
- [ ] Don't touch cloudflared/daemon once green
