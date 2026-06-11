#!/bin/bash
set -e

APP_NAME="cc-status-light"
APP_DIR="/Applications/${APP_NAME}.app"
STATE_DIR="$HOME/.claude/cc-status-light"
SETTINGS_FILE="$HOME/.claude/settings.json"

echo "=== cc-status-light uninstaller ==="

# 1. Kill running process
echo "[1/4] Stopping cc-status-light..."
pkill -f "${APP_NAME}" 2>/dev/null && echo "  -> Process killed" || echo "  -> No running process found"

# 2. Remove .app bundle
echo "[2/4] Removing .app bundle..."
rm -rf "$APP_DIR"
echo "  -> $APP_DIR removed"

# 3. Remove hook entries from settings.json
echo "[3/4] Cleaning up Claude Code hooks..."
if [ -f "$SETTINGS_FILE" ]; then
    python3 - "$SETTINGS_FILE" <<'PY'
import sys, json

settings_path = sys.argv[1]
with open(settings_path) as f:
    settings = json.load(f)

hooks = settings.get("hooks", {})
# Remove entries whose command contains "cc-status-light-hook.sh"
for event in list(hooks.keys()):
    hooks[event] = [
        entry for entry in hooks[event]
        if not any(
            "cc-status-light-hook.sh" in h.get("command", "")
            for h in entry.get("hooks", [])
        )
    ]
    if not hooks[event]:
        del hooks[event]

settings["hooks"] = hooks

with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)
print("  -> Hook entries removed from", settings_path)
PY
fi

# 4. Remove state directory
echo "[4/4] Removing state files..."
if [ -d "$STATE_DIR" ]; then
    read -p "Remove state directory $STATE_DIR? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -rf "$STATE_DIR"
        echo "  -> $STATE_DIR removed"
    else
        echo "  -> Skipped"
    fi
fi

echo ""
echo "=== Uninstall complete ==="
