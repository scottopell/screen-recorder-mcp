import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia

// MARK: - Screen Recorder

actor ScreenRecorder {
    static let shared = ScreenRecorder()

    private var activeRecordings: [String: ActiveRecording] = [:]

    private init() {}

    // MARK: - Start Recording

    func startRecording(config: RecordingConfig) async throws -> RecordingSession {
        // Get shareable content
        let content = try await SCShareableContent.current

        // Create content filter based on mode
        let filter = try createContentFilter(config: config, content: content)

        // Create stream configuration
        let streamConfig = createStreamConfiguration(config: config, content: content)

        // Create recording session
        let session = await SessionManager.shared.createSession(config: config)

        // Ensure output directory exists
        try FileManager.default.createDirectory(
            at: config.outputDirectory,
            withIntermediateDirectories: true
        )

        // Create the stream
        let stream = SCStream(filter: filter, configuration: streamConfig, delegate: nil)

        // Create output writer
        let writer = try OutputWriter(session: session, config: config)

        // Create active recording
        let activeRecording = ActiveRecording(
            session: session,
            stream: stream,
            writer: writer,
            config: config
        )

        // Store active recording
        activeRecordings[session.id] = activeRecording

        // Set up stream output
        try stream.addStreamOutput(activeRecording, type: .screen, sampleHandlerQueue: .global(qos: .userInitiated))

        // Start capture
        try await stream.startCapture()

        // Start max duration timer if configured
        if let maxDuration = config.maxDuration {
            Task {
                try await Task.sleep(nanoseconds: UInt64(maxDuration * 1_000_000_000))
                if let recording = self.activeRecordings[session.id], recording.session.isActive {
                    _ = try? await self.stopRecording(sessionId: session.id)
                }
            }
        }

        return session
    }

    // MARK: - Stop Recording

    func stopRecording(sessionId: String? = nil) async throws -> RecordingSession {
        let targetId: String
        if let id = sessionId {
            targetId = id
        } else if let activeSession = await SessionManager.shared.getActiveSession() {
            targetId = activeSession.id
        } else {
            throw RecordingError.noActiveRecording
        }

        guard let activeRecording = activeRecordings[targetId] else {
            throw RecordingError.sessionNotFound(targetId)
        }

        // Stop the stream
        try await activeRecording.stream.stopCapture()

        // Finalize the writer
        await activeRecording.writer.finalize()

        // Mark session as complete
        activeRecording.session.complete()

        // Remove from active recordings
        activeRecordings.removeValue(forKey: targetId)

        return activeRecording.session
    }

    // MARK: - Pause/Resume Recording

    func pauseRecording(sessionId: String? = nil) async throws -> RecordingSession {
        let targetId = try await resolveSessionId(sessionId)

        guard let activeRecording = activeRecordings[targetId] else {
            throw RecordingError.sessionNotFound(targetId)
        }

        activeRecording.session.pause()
        activeRecording.isPaused = true

        return activeRecording.session
    }

    func resumeRecording(sessionId: String? = nil) async throws -> RecordingSession {
        let targetId = try await resolveSessionId(sessionId)

        guard let activeRecording = activeRecordings[targetId] else {
            throw RecordingError.sessionNotFound(targetId)
        }

        activeRecording.session.resume()
        activeRecording.isPaused = false

        return activeRecording.session
    }

    // MARK: - Cancel Recording

    func cancelRecording(sessionId: String? = nil) async throws {
        let targetId = try await resolveSessionId(sessionId)

        guard let activeRecording = activeRecordings[targetId] else {
            throw RecordingError.sessionNotFound(targetId)
        }

        // Stop the stream
        try await activeRecording.stream.stopCapture()

        // Cancel the writer (don't finalize)
        await activeRecording.writer.cancel()

        // Mark session as cancelled
        activeRecording.session.cancel()

        // Remove the partial file
        try? FileManager.default.removeItem(at: activeRecording.session.outputPath)

        // Remove from active recordings
        activeRecordings.removeValue(forKey: targetId)
    }

    // MARK: - Helpers

    private func resolveSessionId(_ sessionId: String?) async throws -> String {
        if let id = sessionId {
            return id
        } else if let activeSession = await SessionManager.shared.getActiveSession() {
            return activeSession.id
        } else {
            throw RecordingError.noActiveRecording
        }
    }

    private func createContentFilter(config: RecordingConfig, content: SCShareableContent) throws -> SCContentFilter {
        switch config.mode {
        case .screen:
            guard let display = config.displayID.flatMap({ id in
                content.displays.first { $0.displayID == id }
            }) ?? content.displays.first else {
                throw RecordingError.noDisplayFound
            }
            return SCContentFilter(display: display, excludingWindows: [])

        case .window:
            guard let windowID = config.windowID,
                  let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw RecordingError.windowNotFound(config.windowID ?? 0)
            }
            return SCContentFilter(desktopIndependentWindow: window)

        case .app:
            guard let bundleID = config.appBundleID,
                  content.applications.contains(where: { $0.bundleIdentifier == bundleID }) else {
                throw RecordingError.appNotFound(config.appBundleID ?? "")
            }
            // Get all windows for this app
            let appWindows = content.windows.filter { $0.owningApplication?.bundleIdentifier == bundleID }
            guard let display = content.displays.first else {
                throw RecordingError.noDisplayFound
            }
            return SCContentFilter(display: display, including: appWindows)

        case .region:
            guard let display = content.displays.first else {
                throw RecordingError.noDisplayFound
            }
            // For region mode, we capture the full display and crop later
            // (ScreenCaptureKit doesn't support arbitrary regions directly)
            return SCContentFilter(display: display, excludingWindows: [])
        }
    }

    private func createStreamConfiguration(config: RecordingConfig, content: SCShareableContent) -> SCStreamConfiguration {
        let streamConfig = SCStreamConfiguration()

        // Get dimensions based on recording mode
        let width: Int
        let height: Int

        switch config.mode {
        case .window:
            // Get window dimensions
            if let windowID = config.windowID,
               let window = content.windows.first(where: { $0.windowID == windowID }) {
                width = Int(window.frame.size.width)
                height = Int(window.frame.size.height)
            } else {
                width = 1920
                height = 1080
            }

        case .screen:
            // Get display dimensions
            if let displayID = config.displayID,
               let display = content.displays.first(where: { $0.displayID == displayID }) {
                width = display.width
                height = display.height
            } else if let display = content.displays.first {
                width = display.width
                height = display.height
            } else {
                width = 1920
                height = 1080
            }

        case .app:
            // For app mode, use the primary display dimensions
            if let display = content.displays.first {
                width = display.width
                height = display.height
            } else {
                width = 1920
                height = 1080
            }

        case .region:
            if let region = config.region {
                width = region.width
                height = region.height
            } else {
                width = 1920
                height = 1080
            }
        }

        streamConfig.width = width
        streamConfig.height = height

        // Frame rate
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(config.fps))

        // Cursor
        streamConfig.showsCursor = config.captureCursor

        // Quality - pixel format
        streamConfig.pixelFormat = kCVPixelFormatType_32BGRA

        // Queue depth for smooth capture
        streamConfig.queueDepth = 5

        return streamConfig
    }
}

// MARK: - Active Recording

private class ActiveRecording: NSObject, SCStreamOutput, @unchecked Sendable {
    let session: RecordingSession
    let stream: SCStream
    let writer: OutputWriter
    let config: RecordingConfig
    var isPaused: Bool = false

    init(session: RecordingSession, stream: SCStream, writer: OutputWriter, config: RecordingConfig) {
        self.session = session
        self.stream = stream
        self.writer = writer
        self.config = config
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !isPaused else { return }

        switch type {
        case .screen:
            Task {
                await writer.appendVideoSample(sampleBuffer)
            }
        case .audio, .microphone:
            Task {
                await writer.appendAudioSample(sampleBuffer)
            }
        @unknown default:
            break
        }
    }
}

// MARK: - Recording Errors

enum RecordingError: Error, LocalizedError {
    case noActiveRecording
    case sessionNotFound(String)
    case noDisplayFound
    case windowNotFound(UInt32)
    case appNotFound(String)
    case writerSetupFailed(String)
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .noActiveRecording:
            return "No active recording session"
        case .sessionNotFound(let id):
            return "Recording session not found: \(id)"
        case .noDisplayFound:
            return "No display found for recording"
        case .windowNotFound(let id):
            return "Window not found with ID: \(id)"
        case .appNotFound(let name):
            return "Application not found: \(name)"
        case .writerSetupFailed(let reason):
            return "Failed to setup video writer: \(reason)"
        case .permissionDenied:
            return "Screen recording permission denied"
        }
    }
}
