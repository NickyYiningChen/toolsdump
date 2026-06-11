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

    var shortId: String { String(session_id.prefix(8)) }

    static func == (lhs: SessionState, rhs: SessionState) -> Bool {
        lhs.session_id == rhs.session_id && lhs.state == rhs.state && lhs.ts == rhs.ts
    }
}

struct SessionInfo {
    let sessionId: String
    let shortId: String
    let cwd: String?
}

// MARK: - StateManager

class StateManager: ObservableObject {
    @Published var currentState: LightState = .idle
    @Published var activeSessions: [SessionState] = []

    var onSessionCompleted: ((SessionInfo) -> Void)?

    private let stateDir: String
    private var eventStream: FSEventStreamRef?
    private var previousAggregate: LightState = .idle
    private var previousStates: [String: LightState] = [:]
    private let staleThreshold: TimeInterval = 300
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
            previousStates[sid] = session.state
        }
        let activeIds = Set(sessions.map(\.session_id))
        previousStates = previousStates.filter { activeIds.contains($0.key) }

        // Aggregate: yellow > red > green
        let agg: LightState
        if sessions.contains(where: { $0.state == .waiting }) {
            agg = .waiting
        } else if sessions.contains(where: { $0.state == .busy }) {
            agg = .busy
        } else {
            agg = .idle
        }

        currentState = agg
        activeSessions = sessions.sorted { $0.state.priority > $1.state.priority }

        // Fire completion only when ALL sessions are done (aggregate → idle)
        if previousAggregate != .idle && agg == .idle, let last = sessions.first {
            onSessionCompleted?(SessionInfo(
                sessionId: last.session_id,
                shortId: last.shortId,
                cwd: last.cwd
            ))
        }
        previousAggregate = agg
    }
}
