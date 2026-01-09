import Foundation

// MARK: - Recording Configuration (Window-only, Sparse Frame Output)

struct RecordingConfig: Sendable {
    let windowID: UInt32

    let outputDirectory: URL
    let directoryName: String?
    let fps: Int

    let captureCursor: Bool
    let maxDuration: TimeInterval?
    let sessionName: String?

    init(
        windowID: UInt32,
        outputDirectory: URL? = nil,
        directoryName: String? = nil,
        fps: Int = 30,
        captureCursor: Bool = true,
        maxDuration: TimeInterval? = nil,
        sessionName: String? = nil
    ) {
        self.windowID = windowID
        self.outputDirectory = outputDirectory ?? RecordingConfig.defaultOutputDirectory
        self.directoryName = directoryName
        self.fps = max(1, min(120, fps))
        self.captureCursor = captureCursor
        self.maxDuration = maxDuration
        self.sessionName = sessionName
    }

    static var defaultOutputDirectory: URL {
        // Use .screen-recordings in current working directory
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return cwd.appendingPathComponent(".screen-recordings", isDirectory: true)
    }

    /// Generate output directory path for sparse frame recording
    func generateOutputDirectory() -> URL {
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "T", with: "_")

        let dirName = directoryName ?? "recording_\(timestamp)"

        return outputDirectory.appendingPathComponent(dirName, isDirectory: true)
    }
}
