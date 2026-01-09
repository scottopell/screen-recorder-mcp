import Foundation

// MARK: - Recording Status

enum RecordingStatus: String, Codable, Sendable {
    case recording
    case paused
    case completed
    case failed
    case cancelled
}

// MARK: - Recording Session

final class RecordingSession: @unchecked Sendable {
    let id: String
    let config: RecordingConfig
    let outputPath: URL
    let startedAt: Date

    private(set) var status: RecordingStatus
    private(set) var pausedAt: Date?
    private(set) var completedAt: Date?
    private(set) var totalPausedDuration: TimeInterval = 0
    private(set) var error: String?

    private let lock = NSLock()

    init(config: RecordingConfig) {
        self.id = UUID().uuidString
        self.config = config
        self.outputPath = config.generateOutputPath()
        self.startedAt = Date()
        self.status = .recording
    }

    var duration: TimeInterval {
        lock.lock()
        defer { lock.unlock() }

        let endTime = completedAt ?? Date()
        let totalTime = endTime.timeIntervalSince(startedAt)
        return totalTime - totalPausedDuration
    }

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return status == .recording || status == .paused
    }

    func pause() {
        lock.lock()
        defer { lock.unlock() }

        guard status == .recording else { return }
        status = .paused
        pausedAt = Date()
    }

    func resume() {
        lock.lock()
        defer { lock.unlock() }

        guard status == .paused, let pauseStart = pausedAt else { return }
        totalPausedDuration += Date().timeIntervalSince(pauseStart)
        pausedAt = nil
        status = .recording
    }

    func complete() {
        lock.lock()
        defer { lock.unlock() }

        // Account for any current pause
        if status == .paused, let pauseStart = pausedAt {
            totalPausedDuration += Date().timeIntervalSince(pauseStart)
        }

        status = .completed
        completedAt = Date()
    }

    func fail(with error: String) {
        lock.lock()
        defer { lock.unlock() }

        self.error = error
        status = .failed
        completedAt = Date()
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }

        status = .cancelled
        completedAt = Date()
    }

    func toJSON() -> JSONValue {
        lock.lock()
        defer { lock.unlock() }

        var dict: [String: JSONValue] = [
            "session_id": .string(id),
            "status": .string(status.rawValue),
            "started_at": .string(ISO8601DateFormatter().string(from: startedAt)),
            "output_path": .string(outputPath.path),
            "duration": .double(duration),
            "mode": .string(config.mode.rawValue)
        ]

        if let name = config.sessionName {
            dict["session_name"] = .string(name)
        }

        if let completed = completedAt {
            dict["completed_at"] = .string(ISO8601DateFormatter().string(from: completed))
        }

        if let err = error {
            dict["error"] = .string(err)
        }

        return .object(dict)
    }
}

// MARK: - Session Manager

actor SessionManager {
    static let shared = SessionManager()

    private var sessions: [String: RecordingSession] = [:]

    private init() {}

    func createSession(config: RecordingConfig) -> RecordingSession {
        let session = RecordingSession(config: config)
        sessions[session.id] = session
        return session
    }

    func getSession(_ id: String) -> RecordingSession? {
        sessions[id]
    }

    func getActiveSession() -> RecordingSession? {
        sessions.values.first { $0.isActive }
    }

    func getAllActiveSessions() -> [RecordingSession] {
        sessions.values.filter { $0.isActive }
    }

    func getAllSessions() -> [RecordingSession] {
        Array(sessions.values)
    }

    func removeSession(_ id: String) {
        sessions.removeValue(forKey: id)
    }

    func cleanup(olderThan date: Date = Date().addingTimeInterval(-86400)) {
        // Remove completed sessions older than 24 hours by default
        for (id, session) in sessions {
            if !session.isActive, let completed = session.completedAt, completed < date {
                sessions.removeValue(forKey: id)
            }
        }
    }
}
