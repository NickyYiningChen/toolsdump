import UserNotifications
import AppKit

class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    private var isMuted = false
    private var soundName = "Glass"
    private var pendingCWDs: [String: String] = [:]
    private let lock = NSLock()
    private var returnApp: String = ""

    override init() {
        super.init()

        let home = FileManager.default.homeDirectoryForCurrentUser.path

        // Read user-configured sound name
        let nameFile = "\(home)/.claude/cc-status-light/sound_name"
        if let name = try? String(contentsOfFile: nameFile, encoding: .utf8) {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let sysPath = "/System/Library/Sounds/\(trimmed).aiff"
                if FileManager.default.fileExists(atPath: sysPath) {
                    soundName = trimmed
                }
            }
        }

        // Read user-configured return app
        let appFile = "\(home)/.claude/cc-status-light/return_app"
        if let app = try? String(contentsOfFile: appFile, encoding: .utf8) {
            returnApp = app.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        NotificationCenter.default.addObserver(
            forName: .toggleMute,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.toggleMute()
        }
    }

    func sendWaitingNotification(for session: SessionInfo) {
        guard !isMuted else { return }
        fireNotification(title: "Help me!!", body: "Needs your input.", cwd: session.cwd)
    }

    func sendCompletionNotification(for session: SessionInfo) {
        guard !isMuted else { return }
        let dur = session.duration.map { " (\($0))" } ?? ""
        fireNotification(title: "Let's rock!!", body: "Done\(dur)", cwd: session.cwd)
    }

    private func fireNotification(title: String, body: String, cwd: String?) {
        let id = UUID().uuidString

        if let cwd {
            lock.lock()
            pendingCWDs[id] = cwd
            lock.unlock()
        }

        // osascript: reliable notification + sound
        DispatchQueue.global(qos: .utility).async {
            let script = "display notification \"\(body)\" with title \"\(title)\" sound name \"\(self.soundName)\""
            let task = Process()
            task.launchPath = "/usr/bin/osascript"
            task.arguments = ["-e", script]
            task.launch()
            task.waitUntilExit()
        }

        // UNUserNotification: click handling
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = cwd.map { ["cwd": $0] } ?? [:]
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: id,
            content: content,
            trigger: nil
        ))
    }

    @discardableResult
    func toggleMute() -> Bool {
        isMuted.toggle()
        return isMuted
    }

    func activateReturnApp(for session: SessionInfo? = nil) {
        let bundleID: String
        if let tp = session?.termProgram, !tp.isEmpty {
            switch tp {
            case "Apple_Terminal":
                bundleID = "com.apple.Terminal"
            case "iTerm.app":
                bundleID = "com.googlecode.iterm2"
            case "vscode", "code", "Code", "com.microsoft.VSCode":
                bundleID = "com.microsoft.VSCode"
            default:
                bundleID = "com.apple.Terminal"
            }
        } else if !returnApp.isEmpty {
            bundleID = returnApp
        } else {
            let defaults = ["com.apple.Terminal", "com.microsoft.VSCode", "com.googlecode.iterm2"]
            for bid in defaults {
                if activateApp(bundleID: bid) { return }
            }
            return
        }
        activateApp(bundleID: bundleID)
    }

    @discardableResult
    private func activateApp(bundleID: String) -> Bool {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            return false
        }
        app.unhide()
        app.activate()
        // AppleScript reopen: un-minimizes windows
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", "tell application id \"\(bundleID)\" to reopen"]
        task.launch()
        return true
    }

    private func openInApp(cwd: String) {
        // Bundle IDs to try, in priority order
        let bundleIDs: [String]
        if !returnApp.isEmpty {
            bundleIDs = [returnApp]
        } else {
            bundleIDs = ["com.apple.Terminal", "com.microsoft.VSCode", "com.googlecode.iterm2"]
        }

        for bid in bundleIDs {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first else { continue }
            app.activate()
            return
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let id = response.notification.request.identifier
        let cwd = response.notification.request.content.userInfo["cwd"] as? String
            ?? pendingCWDs[id]

        if let cwd {
            openInApp(cwd: cwd)
        }

        // Clean up
        lock.lock()
        pendingCWDs.removeValue(forKey: id)
        lock.unlock()

        completionHandler()
    }
}
