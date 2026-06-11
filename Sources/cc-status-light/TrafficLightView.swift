import SwiftUI

// MARK: - Traffic light view

struct TrafficLightView: View {
    @ObservedObject var stateManager: StateManager
    var onTap: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
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
        .onTapGesture {
            onTap?()
        }
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
    @State private var timer: Timer?

    private let lightColors: [Color: Color] = [
        .red:    Color(red: 1.0, green: 0.23, blue: 0.19),
        .yellow: Color(red: 1.0, green: 0.80, blue: 0.0),
        .green:  Color(red: 0.20, green: 0.78, blue: 0.35),
    ]

    var body: some View {
        let activeColor = lightColors[color] ?? color

        ZStack {
            // Outer glow — only when active
            if isActive {
                Circle()
                    .fill(activeColor)
                    .frame(width: 24, height: 24)
                    .blur(radius: 6)
                    .opacity(breathe ? 0.9 : 0.6)
            }

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
                .opacity(isActive ? (breathe ? 0.3 : 0.15) : 0.05)
        }
        .frame(width: 24, height: 24)
        .animation(nil, value: isActive)
        .onAppear { syncBreathing() }
        .onChange(of: isActive, initial: false) { _, _ in syncBreathing() }
        .onDisappear { timer?.invalidate() }
    }

    private func syncBreathing() {
        timer?.invalidate()
        if isActive {
            breathe = true
            timer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { _ in
                withAnimation(.easeInOut(duration: 0.75)) {
                    breathe.toggle()
                }
            }
            timer?.fire()
        } else {
            breathe = false
            timer = nil
        }
    }
}

// MARK: - Notification name for mute toggle

extension Notification.Name {
    static let toggleMute = Notification.Name("ccStatusLightToggleMute")
}
