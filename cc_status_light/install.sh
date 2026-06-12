#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="cc-status-light"
APP_DIR="/Applications/${APP_NAME}.app"
HOOK_SCRIPT="$SCRIPT_DIR/hooks/cc-status-light-hook.sh"
STATE_DIR="$HOME/.claude/cc-status-light"
SETTINGS_FILE="$HOME/.claude/settings.json"

echo "=== cc-status-light installer ==="
echo ""

# 1. Build the executable
echo "[1/6] Building..."
cd "$SCRIPT_DIR"
swift build -c release
BIN="$SCRIPT_DIR/.build/release/${APP_NAME}"

# 2. Create .app bundle
echo "[2/6] Creating .app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BIN" "$APP_DIR/Contents/MacOS/${APP_NAME}"
cp "$SCRIPT_DIR/Sources/${APP_NAME}/Resources/notification.aiff" "$APP_DIR/Contents/Resources/" 2>/dev/null || true

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>com.cc-status-light.app</string>
    <key>CFBundleName</key>
    <string>cc-status-light</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

echo "  -> $APP_DIR"

# 3. Create state directory
echo "[3/6] Creating state directory..."
mkdir -p "$STATE_DIR"

# 4. Configure Claude Code hooks
echo "[4/6] Configuring Claude Code hooks..."

HOOK_CMD="$HOOK_SCRIPT"

HOOKS_JSON=$(cat <<EOF
{
  "PreToolUse": [
    {
      "hooks": [
        {"type": "command", "command": "${HOOK_CMD} busy"}
      ]
    }
  ],
  "UserPromptSubmit": [
    {
      "hooks": [
        {"type": "command", "command": "${HOOK_CMD} busy"}
      ]
    }
  ],
  "Notification": [
    {
      "matcher": "waiting|input|permission|approval|choose",
      "hooks": [
        {"type": "command", "command": "${HOOK_CMD} waiting"}
      ]
    }
  ],
  "Stop": [
    {
      "hooks": [
        {"type": "command", "command": "${HOOK_CMD} idle"}
      ]
    }
  ]
}
EOF
)

# Merge with existing settings.json using Python
python3 - "$HOOKS_JSON" "$SETTINGS_FILE" <<'PY'
import sys, json, os

new_hooks = json.loads(sys.argv[1])
settings_path = sys.argv[2]

settings = {}
if os.path.exists(settings_path):
    with open(settings_path) as f:
        try:
            settings = json.load(f)
        except json.JSONDecodeError:
            settings = {}

existing_hooks = settings.get("hooks", {})

# Merge: for each hook event, append our hook entries
for event, entries in new_hooks.items():
    if event not in existing_hooks:
        existing_hooks[event] = []
    # Check if our hook already present
    for entry in entries:
        existing_commands = []
        for e in existing_hooks.get(event, []):
            for h in e.get("hooks", []):
                existing_commands.append(h.get("command", ""))
        new_commands = [h.get("command", "") for h in entry.get("hooks", [])]
        already_present = any(c in existing_commands for c in new_commands)
        if not already_present:
            existing_hooks[event].append(entry)

settings["hooks"] = existing_hooks

with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)
f.close()
print("  -> Hooks configured in", settings_path)
PY

# 5. Copy notification sound to state dir (so user can find and replace it)
echo "[5/6] Copying default notification sound..."
cp "$SCRIPT_DIR/Sources/${APP_NAME}/Resources/notification.aiff" "$STATE_DIR/" 2>/dev/null || true

# 6. Launch app
echo "[6/6] Launching..."
open "$APP_DIR"

echo ""
echo "=== Done! cc-status-light is running ==="
echo "  Traffic light: top-right corner of screen"
echo "  State files:   $STATE_DIR"
echo "  Custom sound:  replace $STATE_DIR/notification.aiff"
echo ""
