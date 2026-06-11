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
        // Default app names to try, in order
        let names: [String]
        if !returnApp.isEmpty {
            names = [returnApp]
        } else {
            names = ["Visual Studio Code", "Terminal", "iTerm"]
        }

        for name in names {
            let task = Process()
            task.launchPath = "/usr/bin/open"
            task.arguments = ["-a", name]
            task.launch()
            task.waitUntilExit()
            if task.terminationStatus == 0 { return }
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
