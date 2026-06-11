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
