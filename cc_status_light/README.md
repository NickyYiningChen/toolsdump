# cc-status-light

A floating traffic-light indicator for Claude Code that lives on your desktop. Know whether Claude is working, waiting, or done — without switching back to the terminal or VSCode.


## How It Looks

A small vertical traffic light (40×120px) that floats above all windows, visible on every Space. The active state pulses gently; the other two lights dim.

| Light | State | Meaning |
|-------|-------|---------|
| Red | Busy | Claude is working (calling tools, processing) |
| Yellow | Waiting | Claude needs your input (approval, clarification) |
| Green | Idle | All sessions done — notification fires with a chime |

Drag it anywhere. It remembers its spot across restarts.

## Why You Want This

Claude Code runs in a terminal or VSCode tab you're not always looking at. Sessions can take minutes. This light sits in your peripheral vision so you don't have to keep checking. When it turns green, you hear a chime and know your results are ready. When it turns yellow, Claude's stuck waiting on you.

**Multi-session**: If you're running Claude Code in multiple terminals, the light aggregates across all of them. Yellow wins over red (someone needs you). Red wins over green (someone's still working). Green only when everyone's done.

## Smart Notification Clicks

Notifications know where they came from. Click a notification and you land in the right place:

- **Terminal.app** — detected via `TERM_PROGRAM`
- **VSCode** — detected via `VSCODE_*` environment variables
- **iTerm2** — detected via `ITERM_SESSION_ID`

No manual setup needed. The hook script sniffs the environment when Claude Code starts and the notification system uses it to activate the right app on click.

## Notifications

Two kinds of system notifications, both with sound:

1. **"Help me!!"** — Claude is waiting for your input. Don't leave it hanging.
2. **"Let's rock!!"** — Job done, with duration (e.g., `2m15s`).

Right-click the light to mute notifications if you're in a flow.

## Install

```bash
git clone https://github.com/NickyYiningChen/toolsdump.git
cd toolsdump/cc_status_light
./install.sh
```

The installer does everything:
- Compiles the Swift app in release mode
- Copies the `.app` bundle to `/Applications/`
- Registers it as a macOS Login Item (auto-starts on boot)
- Merges the hook into `~/.claude/settings.json` (preserves your existing hooks)
- Creates the state directory at `~/.claude/cc-status-light/`
- Launches the app

## Custom Sound

Replace the default chime with any `.aiff`, `.wav`, or `.mp3` file:

```bash
cp /path/to/your/sound.aiff ~/.claude/cc-status-light/notification.aiff
```

Or use a built-in system sound by writing its name (without path or extension):

```bash
echo "Funk" > ~/.claude/cc-status-light/sound_name
```

## Uninstall

```bash
./uninstall.sh
```

Removes the app, login item registration, hook entries, and state directory.

## Requirements

- macOS 14+ (Sonoma)
- Xcode Command Line Tools (`xcode-select --install`)
- Claude Code CLI

## How It Works

```
Claude Code Hook Events
  (PreToolUse, Notification, Stop, UserPromptSubmit)
        │
        ▼
hooks/cc-status-light-hook.sh
  → detects TERM_PROGRAM / VSCODE_* / ITERM_SESSION_ID
  → writes per-session JSON to ~/.claude/cc-status-light/
        │
        ▼  (FSEvents file-system watch — zero polling)
Swift App
  ├── StateManager       — reads/aggregates all session files
  ├── TrafficLightView   — SwiftUI 3-circle light with pulse animation
  ├── FloatingWindow     — NSWindow at .floating level, all Spaces
  └── NotificationManager — osascript chime + UNNotification click handling
```

The hook writes a tiny JSON file per session (`{session_id}.json`) with the current state and timestamp. The Swift app watches that directory with FSEvents — no polling, instant updates. Sessions stale for longer than 5 minutes are automatically ignored and cleaned up.

## Multi-Session Priority

```
Yellow (waiting) > Red (busy) > Green (idle)
```

If *any* session needs input, the light shows yellow — even if others are still working. If nobody needs input but at least one is busy, it's red. Only when every session is idle does it turn green and fire the completion notification.
