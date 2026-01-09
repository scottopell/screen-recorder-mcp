import Foundation

/// Stores terminal session metadata for cross-tool lookup
/// Populated by launch_terminal, consumed by run_demo_script
actor TerminalSessionStore {
    static let shared = TerminalSessionStore()

    private var sessions: [String: TerminalSession] = [:]

    private init() {}

    struct TerminalSession {
        let sessionName: String
        let windowId: UInt32
        let appName: String
        let bundleId: String
        let launchedAt: Date
    }

    func register(sessionName: String, windowId: UInt32, appName: String, bundleId: String) {
        sessions[sessionName] = TerminalSession(
            sessionName: sessionName,
            windowId: windowId,
            appName: appName,
            bundleId: bundleId,
            launchedAt: Date()
        )
    }

    func lookup(sessionName: String) -> TerminalSession? {
        sessions[sessionName]
    }

    func remove(sessionName: String) {
        sessions.removeValue(forKey: sessionName)
    }
}
