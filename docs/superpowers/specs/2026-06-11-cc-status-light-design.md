# cc-status-light Design Spec

**Date**: 2026-06-11
**Status**: Approved

## Overview

A macOS floating traffic-light indicator for Claude Code session state. Shows green/yellow/red lights so the user can see Claude Code's status at a glance without switching back to the terminal or VSCode. Also sends system notifications with custom sound when a task completes.

## Display

- **Form**: Floating window, always on top, visible on all Spaces
- **Style**: Vertical 3-circle traffic light (like a real traffic light). Black base frame with slight transparency (mimics real traffic light housing). Current-state light is bright + breathing animation; other two are dimmed
- **Position**: Default top-right corner of screen. Draggable, remembers last position across restarts
- **Interaction**: Not click-through. Right-click menu with Quit, mute notifications, reposition. Window can be dragged
- **Size**: Approx 40×120px

## States and Priority

| Light | Color | Meaning | Trigger |
|-------|-------|---------|---------|
| Top    | 🔴 Red | Busy — Claude is working | `PreToolUse`, `UserPromptSubmit` |
| Middle | 🟡 Yellow | Waiting for user | `Notification` with "waiting for input" / "permission" / approval prompts |
| Bottom | 🟢 Green | Idle/done | `Stop` |

**Multi-session aggregation priority**: Yellow > Red > Green

If any session needs user input, show yellow, even if other sessions are still working. If no session needs input but at least one is working, show red. Green only when all sessions are idle.

## Notifications

- **Trigger**: When an individual session transitions to idle (Stop event), send a macOS system notification banner with sound, regardless of the aggregated state
- **Content**: Project name + job duration (e.g., "my-project: job #3 done, duration: 2m15s")
- **Click action**: Brings the relevant terminal/VSCode window to front
- **Sound**: Custom notification sound. Default bundled with app. User can replace by placing an audio file at `~/.claude/cc-status-light/notification.{aiff,wav,mp3}`

## Architecture

```
Claude Code Hook Events
  (PreToolUse, Notification, Stop, UserPromptSubmit)
        │
        ▼
  hooks/cc-status-light-hook.sh
  → writes per-session state JSON to ~/.claude/cc-status-light/
        │
        ▼ (FSEvents file-system watch)
  Swift App
   ├── StateManager       — reads/aggregates state files
   ├── TrafficLightView   — SwiftUI vertical 3-circle view
   ├── FloatingWindow     — NSWindow with .floating level, all-spaces visible
   └── NotificationManager — UserNotifications + NSSound
        │
   ┌────┴────┐
   ▼         ▼
Floating    System Notification
Window      (banner + sound)
```

## Components

### 1. Hook Script (`hooks/cc-status-light-hook.sh`)

- Receives hook event type as first argument (`$1`)
- Reads JSON from stdin to extract `session_id`
- Writes state file: `~/.claude/cc-status-light/<session_id>.json`
- State file format: `{"state":"<busy|waiting|idle>","session_id":"...","ts":<unix_epoch>}`

### 2. StateManager

- Uses FSEvents to watch `~/.claude/cc-status-light/` directory (event-driven, no polling)
- On change: reads all `.json` files, filters stale sessions (>5 min since last `ts`), aggregates by priority
- Exposes current aggregated state as an ObservableObject published property

### 3. TrafficLightView (SwiftUI)

- Three circles vertically stacked in a black rounded-rectangle background
- Active light: full brightness + soft pulsing animation (opacity 0.7↔1.0, ~1.5s period)
- Inactive lights: dimmed (~0.25 opacity)
- Light colors: Red `#FF3B30`, Yellow `#FFCC00`, Green `#34C759`
- Black housing: `#1A1A1A` with ~85% opacity (slight transparency)

### 4. FloatingWindow (NSWindow + NSPanel)

- Level: `.floating` (above normal windows)
- Collection behavior: `canJoinAllSpaces` + `stationary`
- Style: borderless, non-activating (doesn't steal focus)
- Default position: top-right, with margin from screen edge
- Position persistence via UserDefaults

### 5. NotificationManager

- Uses `UserNotifications` framework (no external dependency)
- Requests notification permission on first launch
- Plays sound via `NSSound` for custom audio, falls back to default system sound
- Notification click opens relevant project (via `NSWorkspace.open`)

## Hook Events Mapping

| Hook | State | Notes |
|------|-------|-------|
| `PreToolUse` | busy | Claude starts using a tool |
| `UserPromptSubmit` | busy | User submits a new prompt |
| `Notification` (waiting/input/permission) | waiting | Claude needs user action |
| `Stop` | idle | Claude finished responding |

## Installation

`install.sh` does:

1. `swift build -c release` to compile the app
2. Copies `.app` bundle to `/Applications/cc-status-light.app` (or `~/Applications/`)
3. Registers as Login Item via `SMAppService.mainApp.register()`
4. Merges hook configuration into `~/.claude/settings.json` (preserves existing settings)
5. Creates state directory `~/.claude/cc-status-light/`
6. Launches the app immediately

## Uninstall

`uninstall.sh` does:

1. Kills running cc-status-light process
2. Removes `.app` bundle
3. Unregisters Login Item
4. Removes hook entries from `~/.claude/settings.json`
5. Removes `~/.claude/cc-status-light/` directory (optional, with confirmation)

## File Structure

```
cc-status-light/
├── install.sh
├── uninstall.sh
├── hooks/
│   └── cc-status-light-hook.sh
├── Sources/
│   ├── main.swift
│   ├── AppDelegate.swift
│   ├── StateManager.swift
│   ├── TrafficLightView.swift
│   ├── FloatingWindowController.swift
│   └── NotificationManager.swift
├── Resources/
│   └── notification.aiff        # Default notification sound
├── Package.swift
└── README.md
```

## Requirements

- macOS 14+ (Sonoma)
- Xcode Command Line Tools (for `swift build`)
- Claude Code CLI (configured with hooks)

## Edge Cases

- **No state files yet**: Default to green (idle)
- **Stale session**: Session files older than 5 minutes are ignored and cleaned up
- **Claude Code not running**: All lights dimmed / show green
- **Multiple sessions**: Aggregated by priority (yellow > red > green). Notifications fire per-session
- **Notification permission denied**: Sound still plays via NSSound, just no banner
- **settings.json already has hooks**: install.sh merges intelligently, doesn't overwrite unrelated hooks
