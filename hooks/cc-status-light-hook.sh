#!/bin/bash
# cc-status-light-hook.sh — Claude Code hook for traffic light state
# Usage: cc-status-light-hook.sh <state>
#   state: busy | waiting | idle

set -e

STATE_DIR="$HOME/.claude/cc-status-light"
STATE="${1:-idle}"

mkdir -p "$STATE_DIR"

# Read all stdin (hook JSON from Claude Code)
SESSION_ID=""
CWD=""
if [ ! -t 0 ]; then
    INPUT=$(cat)
    if [ -n "$INPUT" ]; then
        SESSION_ID=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('session_id',''))" 2>/dev/null || true)
        CWD=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('cwd',''))" 2>/dev/null || true)
    fi
fi

# Determine target file
if [ -n "$SESSION_ID" ]; then
    FILE="$STATE_DIR/${SESSION_ID}.json"
else
    FILE="$STATE_DIR/_default.json"
fi

# Preserve existing cwd if not in current input
if [ -z "$CWD" ] && [ -f "$FILE" ]; then
    CWD=$(python3 -c "import sys,json; print(json.load(open('$FILE')).get('cwd',''))" 2>/dev/null || true)
fi

# Write state file
python3 -c "
import json, time
data = {
    'state': '${STATE}',
    'session_id': '${SESSION_ID}',
    'ts': int(time.time()),
    'cwd': '${CWD}'
}
with open('${FILE}', 'w') as f:
    json.dump(data, f)
"
