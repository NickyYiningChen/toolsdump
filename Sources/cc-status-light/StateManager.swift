import Foundation

// MARK: - State types

enum LightState: String, Codable, CaseIterable {
    case idle, busy, waiting

    var priority: Int {
        switch self {
        case .waiting: return 2
        case .busy:    return 1
        case .idle:    return 0
        }
    }
}

struct SessionState: Codable, Equatable {
    let state: LightState
    let session_id: String
    let ts: Int
    var cwd: String?
    var term_program: String?

    var shortId: String { String(session_id.prefix(8)) }

    static func == (lhs: SessionState, rhs: SessionState) -> Bool {
        lhs.session_id == rhs.session_id && lhs.state == rhs.state && lhs.ts == rhs.ts
    }
}

struct SessionInfo {
    let sessionId: String
    let shortId: String
    let cwd: String?
    var duration: String?
    var termProgram: String?
}

// MARK: - StateManager

class StateManager: ObservableObject {
    @Published var currentState: LightState = .idle
    @Published var activeSessions: [SessionState] = []

    var onSessionCompleted: ((SessionInfo) -> Void)?
    var onWaitingForInput: ((SessionInfo) -> Void)?
    var onAnySessionChange: ((SessionInfo) -> Void)?

    private let stateDir: String
    private var eventStream: FSEventStreamRef?
    private var previousAggregate: LightState = .idle
    private var previousStates: [String: LightState] = [:]
    private var sessionStartTimes: [String: Date] = [:]
    private var lastKnownSession: SessionState?
    private let staleThreshold: TimeInterval = 300
    private let yellowDebounceDelay: TimeInterval = 0.6
    private var yellowDebounceWorkItem: DispatchWorkItem?
    private let fm = FileManager.default

    init() {
        let home = fm.homeDirectoryForCurrentUser.path
        stateDir = "\(home)/.claude/cc-status-light"
        try? fm.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
    }

    deinit {
        stopWatching()
    }

    // MARK: - FSEvents

    func startWatching() {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let paths = [stateDir] as CFArray

        eventStream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { (_, clientCallBackInfo, _, _, _, _) in
                guard let info = clientCallBackInfo else { return }
                let manager = Unmanaged<StateManager>.fromOpaque(info).takeUnretainedValue()
                manager.refresh()
            },
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.25,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
        )

        if let stream = eventStream {
            FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
            FSEventStreamStart(stream)
        }
        refresh()
    }

    func stopWatching() {
        guard let stream = eventStream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        eventStream = nil
    }

    // MARK: - State aggregation

    func refresh() {
        // Always run on main to avoid thread-safety issues with previousStates
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.refresh() }
            return
        }

        guard let files = try? fm.contentsOfDirectory(atPath: stateDir) else {
            currentState = .idle
            return
        }

        let now = Date()
        var sessions: [SessionState] = []

        for file in files where file.hasSuffix(".json") {
            let path = "\(stateDir)/\(file)"
            guard let data = fm.contents(atPath: path),
                  let session = try? JSONDecoder().decode(SessionState.self, from: data) else { continue }

            let ts = Date(timeIntervalSince1970: Double(session.ts))
            if now.timeIntervalSince(ts) > staleThreshold {
                try? fm.removeItem(atPath: path)
                continue
            }
            sessions.append(session)
        }

        // Update per-session state tracking
        for session in sessions {
            let sid = session.session_id
            guard !sid.isEmpty else { continue }
            // Record start time when session first appears
            if previousStates[sid] == nil {
                sessionStartTimes[sid] = Date()
            }
            // Fire onAnySessionChange for every state transition
            let prev = previousStates[sid]
            if prev != session.state {
                onAnySessionChange?(SessionInfo(
                    sessionId: sid,
                    shortId: session.shortId,
                    cwd: session.cwd,
                    termProgram: session.term_program
                ))
            }
            previousStates[sid] = session.state
        }
        let activeIds = Set(sessions.map(\.session_id))
        previousStates = previousStates.filter { activeIds.contains($0.key) }
        sessionStartTimes = sessionStartTimes.filter { activeIds.contains($0.key) }

        // Aggregate: yellow > red > green
        let agg: LightState
        if sessions.contains(where: { $0.state == .waiting }) {
            agg = .waiting
        } else if sessions.contains(where: { $0.state == .busy }) {
            agg = .busy
        } else {
            agg = .idle
        }

        activeSessions = sessions.sorted { $0.state.priority > $1.state.priority }

        // Fire completion only when ALL sessions are done (aggregate → idle).
        // When sessions are removed via deletion (idle hook), sessions.first is nil,
        // so we track the last known session to still fire the notification.
        if previousAggregate != .idle && agg == .idle {
            let last = sessions.first ?? lastKnownSession
            let dur = last.flatMap { formatDuration(from: sessionStartTimes[$0.session_id]) }
            onSessionCompleted?(SessionInfo(
                sessionId: last?.session_id ?? "",
                shortId: last?.shortId ?? "",
                cwd: last?.cwd,
                duration: dur,
                termProgram: last?.term_program
            ))
        }

        if let s = sessions.first {
            lastKnownSession = s
        }

        // Debounce yellow: auto-approved tools (Bash, Edit, etc.) resolve in
        // < 500ms. Delay the waiting state so brief flashes don't trigger
        // the light, sound, or notification.
        if agg == .waiting && previousAggregate != .waiting && yellowDebounceWorkItem == nil {
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.yellowDebounceWorkItem = nil
                guard let s = self.activeSessions.first(where: { $0.state == .waiting }) else { return }
                self.currentState = .waiting
                self.previousAggregate = .waiting
                self.onWaitingForInput?(SessionInfo(
                    sessionId: s.session_id,
                    shortId: s.shortId,
                    cwd: s.cwd,
                    termProgram: s.term_program
                ))
            }
            yellowDebounceWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + yellowDebounceDelay, execute: workItem)
            return
        }

        if agg != .waiting {
            yellowDebounceWorkItem?.cancel()
            yellowDebounceWorkItem = nil
        } else {
            // Already in waiting (debounce fired or previousAggregate was already .waiting)
            return
        }

        currentState = agg
        previousAggregate = agg
    }

    private func formatDuration(from start: Date?) -> String? {
        guard let start else { return nil }
        let seconds = Int(Date().timeIntervalSince(start))
        if seconds < 60 { return "\(seconds)s" }
        let m = seconds / 60
        let s = seconds % 60
        if seconds < 3600 { return s > 0 ? "\(m)m\(s)s" : "\(m)m" }
        let h = m / 60
        let rm = m % 60
        return rm > 0 ? "\(h)h\(rm)m" : "\(h)h"
    }
}
