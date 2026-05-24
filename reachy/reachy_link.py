#!/usr/bin/env python3
"""Reachy Mini <-> Meta Ray-Ban Display relay client.

Runs on the Reachy Mini (or the Mac next to it). It does two things:

  1. Pushes spoken text to the relay so the glasses can display it
     (post_speech / post_state).
  2. Pulls control commands the glasses sent and hands them to a callback
     so the robot can act on them (start_command_listener).

Standard library only (urllib) — no pip installs needed on either machine.

Wiring it into mini_voice.py (from the conversation manual)
------------------------------------------------------------
At the top of mini_voice.py:

    import reachy_link

Then sprinkle these calls into the loop:

    reachy_link.post_state("listening")            # before record()
    user_text = transcribe(wav)
    reachy_link.post_speech(user_text, speaker="user", state="listening")

    reachy_link.post_state("thinking")             # before generate_reply()
    reply = generate_reply(user_text)
    reachy_link.post_speech(reply)                 # speaker defaults to "reachy"

    speech = synthesize(reply)
    play(speech)                                   # audio still comes from Reachy
    reachy_link.post_state("idle")

To act on commands from the glasses, start the listener once at startup:

    reachy_link.start_command_listener(handle_command)

where handle_command(command: str, params: dict) drives the Reachy SDK.

Environment
-----------
    RELAY_URL   default http://127.0.0.1:4000   (the relay's base URL)
    LINK_DEBUG  "1" to print every post/poll
"""

import os
import sys
import time
import json
import threading
import urllib.request
import urllib.error

RELAY_URL = os.environ.get("RELAY_URL", "http://127.0.0.1:4000").rstrip("/")
DEBUG = os.environ.get("LINK_DEBUG", "0") == "1"
_TIMEOUT = float(os.environ.get("LINK_TIMEOUT", "5"))


def _log(*a):
    if DEBUG:
        print("[reachy_link]", *a, file=sys.stderr)


def _request(method, path, body=None):
    """Tiny urllib JSON request. Returns (status_code, text)."""
    data = json.dumps(body).encode("utf-8") if body is not None else None
    headers = {"Content-Type": "application/json"} if data is not None else {}
    req = urllib.request.Request(f"{RELAY_URL}{path}", data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=_TIMEOUT) as r:
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")


def post_speech(text, speaker="reachy", emotion=None, state=None):
    """Send a spoken line to the glasses. Never raises — link issues must
    not break the conversation loop. Returns True on success."""
    text = (text or "").strip()
    if not text:
        return False
    body = {"speaker": speaker, "text": text}
    if emotion:
        body["emotion"] = emotion
    if state:
        body["state"] = state
    try:
        st, _ = _request("POST", "/api/speech", body)
        _log("post_speech", st, text[:40])
        return 200 <= st < 300
    except Exception as e:  # noqa: BLE001 - best effort
        _log("post_speech failed:", e)
        return False


def post_state(state, emotion=None):
    """Update robot state (idle|listening|thinking|speaking|error) and/or
    emotion without sending text."""
    body = {"state": state}
    if emotion:
        body["emotion"] = emotion
    try:
        st, _ = _request("POST", "/api/state", body)
        _log("post_state", st, state, emotion or "")
        return 200 <= st < 300
    except Exception as e:  # noqa: BLE001
        _log("post_state failed:", e)
        return False


def poll_commands():
    """Return the list of pending commands [{id, command, params, ts}, ...].
    Also acts as the heartbeat that keeps the glasses' 'robot ON' indicator
    lit."""
    try:
        st, raw = _request("GET", "/api/commands")
        if 200 <= st < 300:
            return json.loads(raw).get("commands", [])
    except Exception as e:  # noqa: BLE001
        _log("poll_commands failed:", e)
    return []


def start_command_listener(handler, interval=1.0):
    """Spawn a daemon thread that polls for commands and calls
    handler(command, params) for each one. Returns the thread."""
    def _loop():
        _log("command listener started, polling", RELAY_URL)
        while True:
            for cmd in poll_commands():
                try:
                    handler(cmd.get("command", ""), cmd.get("params", {}) or {})
                except Exception as e:  # noqa: BLE001
                    _log("handler error:", e)
            time.sleep(interval)

    t = threading.Thread(target=_loop, name="reachy-link-cmds", daemon=True)
    t.start()
    return t


# --------------------------------------------------------------------------
# Standalone mode: heartbeat + print received commands. Use this to test the
# relay + glasses end-to-end without the full conversation app, e.g.:
#
#     RELAY_URL=http://192.168.3.5:4000 python3 reachy_link.py "こんにちは"
# --------------------------------------------------------------------------
def _demo_handler(command, params):
    print(f"  ↳ command: {command}  params={json.dumps(params, ensure_ascii=False)}")


if __name__ == "__main__":
    print(f"reachy_link demo → {RELAY_URL}")
    first = sys.argv[1] if len(sys.argv) > 1 else "こんにちは。Reachy Miniです。テスト中です。"
    post_state("speaking", emotion="happy")
    post_speech(first)
    start_command_listener(_demo_handler)
    print("listening for commands from the glasses… (Ctrl+C to quit)")
    try:
        i = 0
        while True:
            time.sleep(8)
            i += 1
            post_state("idle")
            post_speech(f"テスト発話 #{i} です。操作ボタンを押すと、ここに表示されます。")
    except KeyboardInterrupt:
        print("\nbye")
