import UserNotifications
import AppKit

class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    private var isMuted = false
    private var soundPath: String = "/System/Library/Sounds/Glass.aiff"

    override init() {
        super.init()

        let home = FileManager.default.homeDirectoryForCurrentUser.path

        // Check for custom audio file (takes priority)
        var customFound = false
        for ext in ["aiff", "wav", "mp3"] {
            let path = "\(home)/.claude/cc-status-light/notification.\(ext)"
            if FileManager.default.fileExists(atPath: path) {
                soundPath = path
                customFound = true
                break
            }
        }

        // If no custom file, check for system sound name config
        if !customFound {
            let nameFile = "\(home)/.claude/cc-status-light/sound_name"
            if let name = try? String(contentsOfFile: nameFile, encoding: .utf8) {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    let sysPath = "/System/Library/Sounds/\(trimmed).aiff"
                    if FileManager.default.fileExists(atPath: sysPath) {
                        soundPath = sysPath
                    }
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

    func sendCompletionNotification(for session: SessionInfo) {
        guard !isMuted else { return }

        // Play sound via full file path
        if let sound = NSSound(contentsOf: URL(fileURLWithPath: soundPath), byReference: false) {
            sound.play()
        } else {
            NSSound.beep()
        }

        // Try UserNotifications first
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

        // Also fire osascript notification as reliable fallback
        let title = projectName(from: session.cwd) ?? "Claude Code"
        let body = "Task completed — session \(session.shortId)"
        DispatchQueue.global(qos: .utility).async {
            let script = "display notification \"\(body)\" with title \"\(title)\" sound name \"Glass\""
            let task = Process()
            task.launchPath = "/usr/bin/osascript"
            task.arguments = ["-e", script]
            task.launch()
        }
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
