import UserNotifications
import AppKit

class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    private var isMuted = false
    private var soundName = "Glass"

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

        let title = "Help me!!"
        let project = projectName(from: session.cwd)
        let body = project != nil ? "\(project!) needs your input" : "Waiting for your input"

        fireNotification(title: title, body: body)
    }

    func sendCompletionNotification(for session: SessionInfo) {
        guard !isMuted else { return }

        let title = "Let's rock!!"
        let project = projectName(from: session.cwd) ?? ""
        let dur = session.duration.map { " (\($0))" } ?? ""
        let body = project.isEmpty
            ? "All tasks completed\(dur)"
            : "\(project) done\(dur)"

        fireNotification(title: title, body: body)
    }

    private func fireNotification(title: String, body: String) {
        DispatchQueue.global(qos: .utility).async {
            let script = "display notification \"\(body)\" with title \"\(title)\" sound name \"\(self.soundName)\""
            let task = Process()
            task.launchPath = "/usr/bin/osascript"
            task.arguments = ["-e", script]
            task.launch()
            task.waitUntilExit()
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = UNNotificationSound.defaultCritical
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        ))
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
