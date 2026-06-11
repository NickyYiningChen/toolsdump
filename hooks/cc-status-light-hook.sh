#!/bin/bash
# cc-status-light-hook.sh — Claude Code hook for traffic light state
# Usage: cc-status-light-hook.sh <state>
#   state: busy | waiting | idle

set -e

STATE_DIR="$HOME/.claude/cc-status-light"
STATE="${1:-idle}"

mkdir -p "$STATE_DIR"

# Delegate all logic to a single Python invocation — no shell interpolation into code.
# Shell variables are passed via environment to avoid injection.
export STATE_DIR STATE

# Pass stdin through to Python (Python reads hook JSON from sys.stdin)
exec python3 -c '
import json, os, sys, time

state_dir = os.environ["STATE_DIR"]
state = os.environ["STATE"]

# Read hook JSON from stdin (if piped)
session_id = ""
cwd = ""
if not sys.stdin.isatty():
    raw = sys.stdin.read().strip()
    if raw:
        try:
            data = json.loads(raw)
            session_id = data.get("session_id", "")
            cwd = data.get("cwd", "")
        except json.JSONDecodeError:
            pass

# Determine target file
if session_id:
    filepath = f"{state_dir}/{session_id}.json"
else:
    filepath = f"{state_dir}/_default.json"

# Preserve existing cwd if not in current input
if not cwd:
    try:
        with open(filepath) as f:
            prev = json.load(f)
            cwd = prev.get("cwd", "")
    except (FileNotFoundError, json.JSONDecodeError):
        pass

# Write state file
with open(filepath, "w") as f:
    json.dump({
        "state": state,
        "session_id": session_id,
        "ts": int(time.time()),
        "cwd": cwd,
    }, f)
'
