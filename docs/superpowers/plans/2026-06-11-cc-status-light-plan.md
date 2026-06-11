# cc-status-light Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a macOS floating traffic-light indicator that shows Claude Code session state (green/yellow/red) with completion notifications and custom sound.

**Architecture:** Swift macOS app using SPM. Claude Code hooks write per-session state JSON files to `~/.claude/cc-status-light/`. The Swift app watches that directory via FSEvents, aggregates state by priority (yellow > red > green), renders a vertical 3-circle floating window, and fires UserNotifications + NSSound on session completion.

**Tech Stack:** Swift 5.9+, SwiftUI, AppKit (NSPanel, FSEvents, UserNotifications, NSSound, SMAppService), bash hooks

---

### Task 1: Project scaffold

**Files:**
- Create: `Package.swift`
- Create: `Sources/cc-status-light/main.swift` (minimal placeholder)
- Create: `Sources/cc-status-light/Resources/.gitkeep`

- [ ] **Step 1: Write Package.swift**

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "cc-status-light",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "cc-status-light",
            path: "Sources/cc-status-light",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
```

- [ ] **Step 2: Write minimal main.swift placeholder**

```swift
import Cocoa

print("cc-status-light placeholder")
```

- [ ] **Step 3: Create Resources directory placeholder**

Run: `mkdir -p Sources/cc-status-light/Resources && touch Sources/cc-status-light/Resources/.gitkeep`

- [ ] **Step 4: Verify it builds**

Run: `swift build`
Expected: Build succeeds with the placeholder main.swift

- [ ] **Step 5: Git init and commit**

```bash
git init
git add Package.swift Sources/ .gitignore
git commit -m "feat: scaffold project with Package.swift and placeholder main"
```

---

### Task 2: Hook script

**Files:**
- Create: `hooks/cc-status-light-hook.sh`

- [ ] **Step 1: Write hook script**

```bash
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
    SESSION_ID=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('session_id',''))" 2>/dev/null)
    CWD=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('cwd',''))" 2>/dev/null)
fi

# Determine target file
if [ -n "$SESSION_ID" ]; then
    FILE="$STATE_DIR/${SESSION_ID}.json"
else
    FILE="$STATE_DIR/_default.json"
fi

# Preserve existing cwd if not in current input
if [ -z "$CWD" ] && [ -f "$FILE" ]; then
    CWD=$(python3 -c "import sys,json; print(json.load(open('$FILE')).get('cwd',''))" 2>/dev/null)
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
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x hooks/cc-status-light-hook.sh`

- [ ] **Step 3: Verify hook script runs standalone**

Run: `hooks/cc-status-light-hook.sh idle`
Expected: Creates `~/.claude/cc-status-light/_default.json` with state "idle"

Run: `cat ~/.claude/cc-status-light/_default.json`
Expected: `{"state": "idle", "session_id": "", "ts": ..., "cwd": ""}`

- [ ] **Step 4: Verify hook script reads stdin JSON**

Run:
```bash
echo '{"session_id":"test123","cwd":"/tmp/test"}' | hooks/cc-status-light-hook.sh busy
cat ~/.claude/cc-status-light/test123.json
```
Expected: `{"state": "busy", "session_id": "test123", "ts": ..., "cwd": "/tmp/test"}`

- [ ] **Step 5: Verify cwd preserved across events**

Run:
```bash
echo '{"session_id":"test456","cwd":"/tmp/myproject"}' | hooks/cc-status-light-hook.sh busy
echo '{"session_id":"test456"}' | hooks/cc-status-light-hook.sh idle
cat ~/.claude/cc-status-light/test456.json
```
Expected: `{"state": "idle", ... "cwd": "/tmp/myproject"}` (cwd preserved from previous event)

- [ ] **Step 6: Commit**

```bash
git add hooks/
git commit -m "feat: add Claude Code hook script for state file writing"
```

---

### Task 3: State model and StateManager

**Files:**
- Create: `Sources/cc-status-light/StateManager.swift`

- [ ] **Step 1: Write StateManager.swift with enums, models, and FSEvents watcher**

```swift
import Foundation
import Combine

// MARK: - State types

enum LightState: String, Codable, CaseIterable {
    case idle, busy, waiting

    var priority: Int {
        switch self {
        case .waiting: return 2
        case .busy:    return 1
        case .idle:    return 0
        }
    }
}

struct SessionState: Codable, Equatable {
    let state: LightState
    let session_id: String
    let ts: Int
    var cwd: String?

    var shortId: String { String(session_id.prefix(8)) }

    static func == (lhs: SessionState, rhs: SessionState) -> Bool {
        lhs.session_id == rhs.session_id && lhs.state == rhs.state && lhs.ts == rhs.ts
    }
}

struct SessionInfo {
    let sessionId: String
    let shortId: String
    let cwd: String?
}

// MARK: - StateManager

class StateManager: ObservableObject {
    @Published var currentState: LightState = .idle
    @Published var activeSessions: [SessionState] = []

    var onSessionCompleted: ((SessionInfo) -> Void)?

    private let stateDir: String
    private var eventStream: FSEventStreamRef?
    private var previousStates: [String: LightState] = [:]
    private let staleThreshold: TimeInterval = 300
    private let fm = FileManager.default

    init() {
        let home = fm.homeDirectoryForCurrentUser.path
        stateDir = "\(home)/.claude/cc-status-light"
        try? fm.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
    }

    // MARK: - FSEvents

    func startWatching() {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let paths = [stateDir] as CFArray

        eventStream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { (_, clientCallBackInfo, _, _, _, _) in
                guard let info = clientCallBackInfo else { return }
                let manager = Unmanaged<StateManager>.fromOpaque(info).takeUnretainedValue()
                manager.refresh()
            },
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.25,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
        )

        if let stream = eventStream {
            FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
            FSEventStreamStart(stream)
        }
        refresh()
    }

    func stopWatching() {
        guard let stream = eventStream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        eventStream = nil
    }

    // MARK: - State aggregation

    func refresh() {
        guard let files = try? fm.contentsOfDirectory(atPath: stateDir) else {
            DispatchQueue.main.async { self.currentState = .idle }
            return
        }

        let now = Date()
        var sessions: [SessionState] = []

        for file in files where file.hasSuffix(".json") {
            let path = "\(stateDir)/\(file)"
            guard let data = fm.contents(atPath: path),
                  var session = try? JSONDecoder().decode(SessionState.self, from: data) else { continue }

            let ts = Date(timeIntervalSince1970: Double(session.ts))
            if now.timeIntervalSince(ts) > staleThreshold {
                try? fm.removeItem(atPath: path)
                continue
            }
            sessions.append(session)
        }

        // Detect completions: session went from non-idle to idle
        var completed: [SessionInfo] = []
        for session in sessions {
            let sid = session.session_id
            guard !sid.isEmpty else { continue }
            let prev = previousStates[sid]
            if session.state == .idle, let prev = prev, prev != .idle {
                completed.append(SessionInfo(
                    sessionId: sid,
                    shortId: session.shortId,
                    cwd: session.cwd
                ))
            }
            previousStates[sid] = session.state
        }
        // Clean stale previousStates entries
        let activeIds = Set(sessions.map(\.session_id))
        previousStates = previousStates.filter { activeIds.contains($0.key) || $0.key.isEmpty }

        // Aggregate: yellow > red > green
        let agg: LightState
        if sessions.contains(where: { $0.state == .waiting }) {
            agg = .waiting
        } else if sessions.contains(where: { $0.state == .busy }) {
            agg = .busy
        } else {
            agg = .idle
        }

        DispatchQueue.main.async {
            self.currentState = agg
            self.activeSessions = sessions.sorted { $0.state.priority > $1.state.priority }
        }

        // Fire completion notifications (outside of main queue if needed)
        for info in completed {
            DispatchQueue.main.async {
                self.onSessionCompleted?(info)
            }
        }
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build`
Expected: Build succeeds with StateManager.swift

- [ ] **Step 3: Commit**

```bash
git add Sources/cc-status-light/StateManager.swift
git commit -m "feat: add StateManager with FSEvents watching and priority aggregation"
```

---

### Task 4: TrafficLightView (SwiftUI)

**Files:**
- Create: `Sources/cc-status-light/TrafficLightView.swift`

- [ ] **Step 1: Write TrafficLightView.swift**

```swift
import SwiftUI

// MARK: - Traffic light view

struct TrafficLightView: View {
    @ObservedObject var stateManager: StateManager

    var body: some View {
        VStack(spacing: 8) {
            LightCircle(color: .red,    isActive: stateManager.currentState == .busy)
            LightCircle(color: .yellow, isActive: stateManager.currentState == .waiting)
            LightCircle(color: .green,  isActive: stateManager.currentState == .idle)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(red: 0.1, green: 0.1, blue: 0.1, opacity: 0.88))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .frame(width: 44)
        .contextMenu {
            Button("Mute Notifications") {
                NotificationCenter.default.post(name: .toggleMute, object: nil)
            }
            Divider()
            Button("Quit cc-status-light") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}

// MARK: - Single light circle

struct LightCircle: View {
    let color: Color
    let isActive: Bool

    @State private var breathe = false

    private let lightColors: [Color: Color] = [
        .red:    Color(red: 1.0, green: 0.23, blue: 0.19),
        .yellow: Color(red: 1.0, green: 0.80, blue: 0.0),
        .green:  Color(red: 0.20, green: 0.78, blue: 0.35),
    ]

    var body: some View {
        let activeColor = lightColors[color] ?? color

        ZStack {
            // Outer glow
            Circle()
                .fill(activeColor)
                .frame(width: 24, height: 24)
                .blur(radius: isActive ? 6 : 0)
                .opacity(isActive ? (breathe ? 0.6 : 0.9) : 0)

            // Main circle
            Circle()
                .fill(activeColor)
                .frame(width: 22, height: 22)
                .opacity(isActive ? (breathe ? 0.75 : 1.0) : 0.2)

            // Inner highlight
            Circle()
                .fill(Color.white)
                .frame(width: 8, height: 8)
                .offset(x: -3, y: -3)
                .opacity(isActive ? (breathe ? 0.15 : 0.3) : 0.05)
        }
        .frame(width: 24, height: 24)
        .onAppear {
            if isActive {
                withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                    breathe = true
                }
            }
        }
        .onChange(of: isActive) { newValue in
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                breathe = newValue
            }
        }
    }
}

// MARK: - Notification name for mute toggle

extension Notification.Name {
    static let toggleMute = Notification.Name("ccStatusLightToggleMute")
}
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build`
Expected: Build succeeds

- [ ] **Step 3: Commit**

```bash
git add Sources/cc-status-light/TrafficLightView.swift
git commit -m "feat: add vertical 3-circle traffic light view with breathing animation"
```

---

### Task 5: FloatingWindowController

**Files:**
- Create: `Sources/cc-status-light/FloatingWindowController.swift`

- [ ] **Step 1: Write FloatingWindowController.swift**

```swift
import Cocoa
import SwiftUI

class FloatingWindowController: NSWindowController {

    private let defaultWidth: CGFloat = 44
    private let defaultHeight: CGFloat = 130

    init<V: View>(contentView: V) {
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = NSRect(x: 0, y: 0, width: defaultWidth, height: defaultHeight)

        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: defaultWidth, height: defaultHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true

        // Restore saved position or default to top-right
        if let saved = UserDefaults.standard.string(forKey: "windowFrame"),
           !saved.isEmpty {
            window.setFrame(NSRectFromString(saved), display: true)
        } else {
            positionInTopRight(window: window)
        }

        super.init(window: window)

        // Save position on move
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: window,
            queue: .main
        ) { [weak window] _ in
            guard let window else { return }
            UserDefaults.standard.set(
                NSStringFromRect(window.frame),
                forKey: "windowFrame"
            )
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func positionInTopRight(window: NSWindow) {
        guard let screen = NSScreen.main else { return }
        let sf = screen.visibleFrame
        let margin: CGFloat = 16
        let x = sf.maxX - defaultWidth - margin
        let y = sf.maxY - defaultHeight - margin
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.orderFrontRegardless()
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build`
Expected: Build succeeds

- [ ] **Step 3: Commit**

```bash
git add Sources/cc-status-light/FloatingWindowController.swift
git commit -m "feat: add floating NSPanel window controller with position persistence"
```

---

### Task 6: NotificationManager

**Files:**
- Create: `Sources/cc-status-light/NotificationManager.swift`

- [ ] **Step 1: Write NotificationManager.swift**

```swift
import UserNotifications
import AppKit

class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    private var isMuted = false
    private var customSoundURL: URL?

    override init() {
        super.init()

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        // Listen for mute toggle from context menu
        NotificationCenter.default.addObserver(
            forName: .toggleMute,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.toggleMute()
        }

        // Check for custom sound file
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for ext in ["aiff", "wav", "mp3"] {
            let path = "\(home)/.claude/cc-status-light/notification.\(ext)"
            if FileManager.default.fileExists(atPath: path) {
                customSoundURL = URL(fileURLWithPath: path)
                break
            }
        }

        // Also check bundled default sound
        if customSoundURL == nil {
            if let bundled = Bundle.main.url(forResource: "notification", withExtension: "aiff") {
                customSoundURL = bundled
            }
        }
    }

    func sendCompletionNotification(for session: SessionInfo) {
        guard !isMuted else { return }

        // Play sound via NSSound (works even if notification permission denied)
        if let url = customSoundURL {
            let sound = NSSound(contentsOf: url, byReference: false)
            sound?.play()
        } else {
            NSSound.beep()
        }

        // Send system notification
        let content = UNMutableNotificationContent()
        content.title = projectName(from: session.cwd) ?? "Claude Code"
        content.body = "Task completed — session \(session.shortId)"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func projectName(from cwd: String?) -> String? {
        guard let cwd else { return nil }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    @discardableResult
    func toggleMute() -> Bool {
        isMuted.toggle()
        return isMuted
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build`
Expected: Build succeeds

- [ ] **Step 3: Commit**

```bash
git add Sources/cc-status-light/NotificationManager.swift
git commit -m "feat: add NotificationManager with UserNotifications and custom sound support"
```

---

### Task 7: AppDelegate and main entry point

**Files:**
- Create: `Sources/cc-status-light/AppDelegate.swift`
- Modify: `Sources/cc-status-light/main.swift` (replace placeholder)

- [ ] **Step 1: Write AppDelegate.swift**

```swift
import Cocoa
import SwiftUI
import ServiceManagement

class AppDelegate: NSObject, NSApplicationDelegate {
    var stateManager: StateManager!
    var windowController: FloatingWindowController!
    var notificationManager: NotificationManager!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Register as login item on first launch
        registerLoginItem()

        stateManager = StateManager()
        notificationManager = NotificationManager()

        let contentView = TrafficLightView(stateManager: stateManager)
        windowController = FloatingWindowController(contentView: contentView)
        windowController.showWindow(nil)

        // Wire state changes to notifications
        stateManager.onSessionCompleted = { [weak self] info in
            self?.notificationManager.sendCompletionNotification(for: info)
        }

        stateManager.startWatching()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stateManager.stopWatching()
    }

    private func registerLoginItem() {
        let key = "didRegisterLoginItem"
        guard !UserDefaults.standard.bool(forKey: key) else { return }

        do {
            try SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: key)
        } catch {
            print("Warning: Could not register login item: \(error)")
        }
    }
}
```

- [ ] **Step 2: Write main.swift (replacing placeholder)**

```swift
import Cocoa

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate

app.run()
```

- [ ] **Step 3: Verify it compiles**

Run: `swift build`
Expected: Build succeeds

- [ ] **Step 4: Commit**

```bash
git add Sources/cc-status-light/AppDelegate.swift Sources/cc-status-light/main.swift
git commit -m "feat: add AppDelegate wiring and main entry point"
```

---

### Task 8: Default notification sound

**Files:**
- Create: `Sources/cc-status-light/Resources/notification.aiff`

- [ ] **Step 1: Generate a simple two-tone chime AIFF using Python**

```bash
python3 -c "
import struct, math, os

sample_rate = 44100
duration = 0.12
freq1, freq2 = 880.0, 1108.73  # A5, C#6
volume = 0.4

def tone(freq, dur):
    n = int(sample_rate * dur)
    samples = []
    for i in range(n):
        env = 1.0 - (i / n)
        v = volume * env * math.sin(2 * math.pi * freq * i / sample_rate)
        samples.append(int(v * 32767))
    return samples

samples = tone(freq1, duration) + tone(freq2, duration * 1.2)
data = struct.pack('<' + 'h' * len(samples), *samples)

# Write AIFF file
nchannels, sampwidth, framerate, nframes = 1, 2, sample_rate, len(samples)
compsize = nframes * nchannels * sampwidth
ssnd_size = 8 + compsize
comm_size = 18
form_size = 4 + comm_size + ssnd_size + 8

with open('Sources/cc-status-light/Resources/notification.aiff', 'wb') as f:
    f.write(b'FORM')
    f.write(struct.pack('>I', form_size))
    f.write(b'AIFF')
    # COMM chunk
    f.write(b'COMM')
    f.write(struct.pack('>I', comm_size))
    f.write(struct.pack('>h', nchannels))
    f.write(struct.pack('>I', nframes))
    f.write(struct.pack('>h', sampwidth))
    # sample rate as 80-bit extended float
    exp = 0
    mant = int(sample_rate * (1 << 31))
    while mant >= (1 << 32):
        mant >>= 1
        exp += 1
    f.write(struct.pack('>H', 0x4000 + (exp + 16383)))  # exponent
    f.write(struct.pack('>I', mant & 0xFFFFFFFF))        # mantissa high
    f.write(struct.pack('>I', 0))                         # mantissa low
    # SSND chunk
    f.write(b'SSND')
    f.write(struct.pack('>I', ssnd_size))
    f.write(struct.pack('>II', 0, 0))  # offset, block size
    f.write(data)

print(f'AIFF generated: {os.path.getsize(\"Sources/cc-status-light/Resources/notification.aiff\")} bytes')
"
```

- [ ] **Step 2: Verify the sound file plays**

Run: `afplay Sources/cc-status-light/Resources/notification.aiff`
Expected: Hear a two-tone chime

- [ ] **Step 3: Build with the resource included**

Run: `swift build`
Expected: Build succeeds, resource bundled

- [ ] **Step 4: Commit**

```bash
git add Sources/cc-status-light/Resources/notification.aiff
git commit -m "feat: add default two-tone chime notification sound"
```

---

### Task 9: Install script

**Files:**
- Create: `install.sh`

- [ ] **Step 1: Write install.sh**

```bash
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
```

- [ ] **Step 2: Make install.sh executable**

Run: `chmod +x install.sh`

- [ ] **Step 3: Commit**

```bash
git add install.sh
git commit -m "feat: add install script (build + .app bundle + hooks merge + login item)"
```

---

### Task 10: Uninstall script

**Files:**
- Create: `uninstall.sh`

- [ ] **Step 1: Write uninstall.sh**

```bash
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
```

- [ ] **Step 2: Make uninstall.sh executable**

Run: `chmod +x uninstall.sh`

- [ ] **Step 3: Commit**

```bash
git add uninstall.sh
git commit -m "feat: add uninstall script"
```

---

### Task 11: README

**Files:**
- Create: `README.md`

- [ ] **Step 1: Write README.md**

```markdown
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
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: add README"
```

---

### Task 12: End-to-end integration test

- [ ] **Step 1: Run install.sh**

Run: `./install.sh`
Expected: Build succeeds, app launches, traffic light appears in top-right corner.
Expected: `~/.claude/settings.json` has hook entries added.

- [ ] **Step 2: Verify hook integration**

Run:
```bash
echo '{"session_id":"e2e-test","cwd":"/tmp/test"}' | hooks/cc-status-light-hook.sh busy
sleep 0.5
cat ~/.claude/cc-status-light/e2e-test.json
```
Expected: State file shows `"state": "busy"`

Run:
```bash
echo '{"session_id":"e2e-test"}' | hooks/cc-status-light-hook.sh idle
sleep 0.5
```
Expected: Traffic light turns green, notification fires with sound.

- [ ] **Step 3: Verify state aggregation**

Run:
```bash
# Session 1: busy
echo '{"session_id":"s1","cwd":"/tmp/a"}' | hooks/cc-status-light-hook.sh busy
# Session 2: waiting
echo '{"session_id":"s2","cwd":"/tmp/b"}' | hooks/cc-status-light-hook.sh waiting
sleep 0.5
```
Expected: Traffic light shows yellow (waiting has higher priority).

- [ ] **Step 4: Verify stale session cleanup**

Run:
```bash
# Create a stale state file (6 min old)
cat > ~/.claude/cc-status-light/stale.json <<EOF
{"state":"busy","session_id":"stale","ts":$(date -v-6M +%s)}
EOF
# Also create a fresh one
echo '{"session_id":"fresh","cwd":"/tmp"}' | hooks/cc-status-light-hook.sh busy
sleep 1
```
Expected: `stale.json` is cleaned up, only fresh session affects the light.

- [ ] **Step 5: Verify position persistence**

Drag the traffic light to a new position. Quit via right-click menu. Re-launch via `open /Applications/cc-status-light.app`.
Expected: Window appears at the new position.

- [ ] **Step 6: Commit final state**

```bash
git add -A
git commit -m "chore: final integration test adjustments"
```
