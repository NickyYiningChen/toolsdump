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

# Detect which app this session is from
term_program = os.environ.get("TERM_PROGRAM", "")
# VSCode detection: check VSCODE_* env vars
if not term_program:
    for key in os.environ:
        if key.startswith("VSCODE_") or key.startswith("CODE_"):
            term_program = "vscode"
            break
# iTerm detection
if not term_program:
    if os.environ.get("ITERM_SESSION_ID"):
        term_program = "iTerm.app"

# Read hook JSON from stdin (if piped)
session_id = ""
cwd = ""
tool_name = ""
if not sys.stdin.isatty():
    raw = sys.stdin.read().strip()
    if raw:
        try:
            data = json.loads(raw)
            session_id = data.get("session_id", "")
            cwd = data.get("cwd", "")
            tool_name = data.get("tool_name", "")
        except json.JSONDecodeError:
            pass

# PreToolUse: if the tool being called requires user interaction,
# treat it as "waiting" (yellow) instead of "busy" (red).
# AskUserQuestion blocks until the user responds — so we need the
# yellow light + notification to fire immediately.
# Tools that can trigger permission prompts and block waiting for user.
# When these fire PreToolUse, the light should be yellow (waiting), not red (busy).
INTERACTIVE_TOOLS = {
    "AskUserQuestion",
}
if state == "busy" and tool_name in INTERACTIVE_TOOLS:
    state = "waiting"

# On idle (Stop hook), remove all state files to guarantee clean exit.
# This is more robust than writing an idle file — it handles the case
# where notification hooks wrote extra "waiting" files that would
# otherwise keep the light yellow.
if state == "idle":
    import glob
    for f in glob.glob(f"{state_dir}/*.json"):
        try:
            os.remove(f)
        except OSError:
            pass
    sys.exit(0)

# Determine target file
if session_id:
    filepath = f"{state_dir}/{session_id}.json"
else:
    filepath = f"{state_dir}/_default.json"

# Preserve existing cwd/term_program if not in current input
if not cwd or not term_program:
    try:
        with open(filepath) as f:
            prev = json.load(f)
            if not cwd:
                cwd = prev.get("cwd", "")
            if not term_program:
                term_program = prev.get("term_program", "")
    except (FileNotFoundError, json.JSONDecodeError):
        pass

# Write state file
with open(filepath, "w") as f:
    json.dump({
        "state": state,
        "session_id": session_id,
        "ts": int(time.time()),
        "cwd": cwd,
        "term_program": term_program,
    }, f)
'
