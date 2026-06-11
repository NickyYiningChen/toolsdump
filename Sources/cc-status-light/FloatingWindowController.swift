import Cocoa
import SwiftUI

class FloatingWindowController: NSWindowController {

    private let defaultWidth: CGFloat = 44
    private let defaultHeight: CGFloat = 130

    init<V: View>(contentView: V) {
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = NSRect(x: 0, y: 0, width: defaultWidth, height: defaultHeight)

        // Compute initial frame: restore saved position or default to top-right
        var initialRect = NSRect(x: 0, y: 0, width: defaultWidth, height: defaultHeight)
        if let saved = UserDefaults.standard.string(forKey: "windowFrame"),
           !saved.isEmpty {
            initialRect = NSRectFromString(saved)
        } else if let screen = NSScreen.main {
            let sf = screen.visibleFrame
            let margin: CGFloat = 16
            initialRect.origin.x = sf.maxX - defaultWidth - margin
            initialRect.origin.y = sf.maxY - defaultHeight - margin
        }

        let window = NSPanel(
            contentRect: initialRect,
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
    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.orderFrontRegardless()
    }
}
