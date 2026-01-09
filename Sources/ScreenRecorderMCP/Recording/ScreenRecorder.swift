import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia
import AppKit

// MARK: - Screen Recorder (Window-only, Sparse Frame Output)

actor ScreenRecorder {
    static let shared = ScreenRecorder()

    private var activeRecordings: [String: ActiveRecording] = [:]

    private init() {}

    // MARK: - Start Recording

    func startRecording(config: RecordingConfig) async throws -> RecordingSession {
        // Get shareable content
        let content = try await SCShareableContent.current

        // Find the window
        guard let window = content.windows.first(where: { $0.windowID == config.windowID }) else {
            throw RecordingError.windowNotFound(config.windowID)
        }

        // Create content filter for window
        let filter = SCContentFilter(desktopIndependentWindow: window)

        // Create stream configuration with retina support
        let streamConfig = SCStreamConfiguration()

        // Get display scale factor for retina support
        // Find the screen containing this window, or fall back to main screen
        let scaleFactor = NSScreen.screens.first { screen in
            screen.frame.intersects(window.frame)
        }?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0

        // Set dimensions in pixels (not points) for full retina resolution
        streamConfig.width = Int(window.frame.size.width * scaleFactor)
        streamConfig.height = Int(window.frame.size.height * scaleFactor)
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(config.fps))
        streamConfig.showsCursor = config.captureCursor
        streamConfig.pixelFormat = kCVPixelFormatType_32BGRA
        streamConfig.queueDepth = 5

        // Enable best resolution capture on macOS 14+
        if #available(macOS 14.0, *) {
            streamConfig.captureResolution = .best
        }

        // Create recording session
        let session = await SessionManager.shared.createSession(config: config)

        // Create sparse frame writer
        let writer = try SparseFrameWriter(
            outputDirectory: session.outputPath,
            sessionId: session.id,
            windowId: Int(config.windowID),
            windowTitle: window.title ?? "Unknown"
        )

        // Create the stream
        let stream = SCStream(filter: filter, configuration: streamConfig, delegate: nil)

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
        _ = try await activeRecording.writer.finalize()

        // Update session with final frame count
        let frameCount = await activeRecording.writer.currentFrameCount
        activeRecording.session.setFrameCount(frameCount)

        // Mark session as complete
        activeRecording.session.complete()

        // Remove from active recordings
        activeRecordings.removeValue(forKey: targetId)

        return activeRecording.session
    }
}

// MARK: - Active Recording

private class ActiveRecording: NSObject, SCStreamOutput, @unchecked Sendable {
    let session: RecordingSession
    let stream: SCStream
    let writer: SparseFrameWriter
    let config: RecordingConfig

    init(session: RecordingSession, stream: SCStream, writer: SparseFrameWriter, config: RecordingConfig) {
        self.session = session
        self.stream = stream
        self.writer = writer
        self.config = config
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .screen:
            // Process frame synchronously
            guard CMSampleBufferDataIsReady(sampleBuffer),
                  let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                return
            }

            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

            // Dispatch to async context to call actor method
            Task {
                await writer.appendFrame(imageBuffer, presentationTime: presentationTime)
            }

        case .audio, .microphone:
            // Audio not supported in this simplified version
            break
        @unknown default:
            break
        }
    }
}

// MARK: - Recording Errors

enum RecordingError: Error, LocalizedError {
    case noActiveRecording
    case sessionNotFound(String)
    case windowNotFound(UInt32)
    case writerSetupFailed(String)
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .noActiveRecording:
            return "No active recording session"
        case .sessionNotFound(let id):
            return "Recording session not found: \(id)"
        case .windowNotFound(let id):
            return "Window not found with ID: \(id)"
        case .writerSetupFailed(let reason):
            return "Failed to setup video writer: \(reason)"
        case .permissionDenied:
            return "Screen recording permission denied"
        }
    }
}
