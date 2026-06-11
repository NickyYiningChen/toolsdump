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

        let contentView = TrafficLightView(stateManager: stateManager) { [weak self] in
            self?.notificationManager.activateReturnApp()
        }
        windowController = FloatingWindowController(contentView: contentView)
        windowController.showWindow(nil)

        // Wire state changes to notifications
        stateManager.onSessionCompleted = { [weak self] info in
            self?.notificationManager.sendCompletionNotification(for: info)
        }
        stateManager.onWaitingForInput = { [weak self] info in
            self?.notificationManager.sendWaitingNotification(for: info)
        }

        stateManager.startWatching()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // User clicked notification — forward activation to their terminal/VSCode
        notificationManager.activateReturnApp()
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
