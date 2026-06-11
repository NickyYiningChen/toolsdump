import Cocoa
import SwiftUI
import ServiceManagement

class AppDelegate: NSObject, NSApplicationDelegate {
    var stateManager: StateManager!
    var windowController: FloatingWindowController!
    var notificationManager: NotificationManager!
    private var latestSession: SessionInfo?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Register as login item on first launch
        registerLoginItem()

        stateManager = StateManager()
        notificationManager = NotificationManager()

        let contentView = TrafficLightView(stateManager: stateManager) { [weak self] in
            self?.notificationManager.activateReturnApp(for: self?.latestSession)
        }
        windowController = FloatingWindowController(contentView: contentView)
        windowController.showWindow(nil)

        // Wire state changes to notifications
        stateManager.onSessionCompleted = { [weak self] info in
            self?.latestSession = info
            self?.notificationManager.sendCompletionNotification(for: info)
        }
        stateManager.onWaitingForInput = { [weak self] info in
            self?.latestSession = info
            self?.notificationManager.sendWaitingNotification(for: info)
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
