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

        // Store cwd for click-to-open
        if let cwd {
            lock.lock()
            pendingCWDs[id] = cwd
            lock.unlock()
        }

        // osascript notification (reliable, includes sound)
        DispatchQueue.global(qos: .utility).async {
            let script = "display notification \"\(body)\" with title \"\(title)\" sound name \"\(self.soundName)\""
            let task = Process()
            task.launchPath = "/usr/bin/osascript"
            task.arguments = ["-e", script]
            task.launch()
            task.waitUntilExit()
        }

        // UNUserNotification (supports click action)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = UNNotificationSound.defaultCritical
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

    private func openInApp(cwd: String) {
        let apps = candidateApps()
        for app in apps {
            if NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) != nil {
                // Open directory in this app
                let task = Process()
                task.launchPath = "/usr/bin/open"
                task.arguments = ["-a", app, cwd]
                task.launch()
                return
            }
        }
        // Fallback: open Finder
        NSWorkspace.shared.open(URL(fileURLWithPath: cwd))
    }

    private func candidateApps() -> [String] {
        if !returnApp.isEmpty {
            // Try bundle ID first, then app name
            let bundleIds = [
                "com.microsoft.VSCode": "Visual Studio Code",
                "com.googlecode.iterm2": "iTerm",
                "com.apple.Terminal": "Terminal",
                "dev.warp.Warp-Stable": "Warp",
            ]
            if let name = bundleIds[returnApp] {
                return [returnApp, name]
            }
            for (bid, name) in bundleIds where name == returnApp {
                return [bid, name]
            }
            return [returnApp]
        }
        // Default: VSCode → Terminal → iTerm → Finder
        return [
            "com.microsoft.VSCode",
            "com.apple.Terminal",
            "com.googlecode.iterm2",
        ]
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
