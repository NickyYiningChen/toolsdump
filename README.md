# cc-status-light

A macOS floating traffic-light indicator for Claude Code. Shows session state at a glance without switching back to the terminal.

| Light | Meaning |
|-------|---------|
| Red (top) | Busy — Claude is working |
| Yellow (middle) | Waiting for your input |
| Green (bottom) | Idle / done |

Green also triggers a macOS notification with sound (customizable).

## Install

```bash
git clone https://github.com/yourname/cc-status-light.git
cd cc-status-light
./install.sh
```

## How It Works

Claude Code hooks write session state to `~/.claude/cc-status-light/`. The app watches that directory and updates the floating traffic light. On session completion (green), a system notification fires with a chime sound.

## Custom Notification Sound

Replace the default sound:
```bash
cp /path/to/your/sound.aiff ~/.claude/cc-status-light/notification.aiff
```
Supports `.aiff`, `.wav`, `.mp3`.

## Uninstall

```bash
./uninstall.sh
```

## Requirements

- macOS 14+
- Xcode Command Line Tools
- Claude Code CLI
