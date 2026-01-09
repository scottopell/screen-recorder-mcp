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

        // Create active recording first (needed as delegate)
        // We'll set the stream after creation
        let activeRecording = ActiveRecording(
            session: session,
            stream: nil,  // Set below
            writer: writer,
            config: config
        )

        // Create the stream with activeRecording as delegate to receive unexpected stop notifications
        let stream = SCStream(filter: filter, configuration: streamConfig, delegate: activeRecording)

        // Set the stream on activeRecording
        activeRecording.setStream(stream)

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

        // Check if stream was stopped externally (e.g., by another process's ScreenCaptureKit operations)
        let externalStop = activeRecording.checkExternalStop()
        var streamStopError: Error?

        if externalStop.stopped {
            // Stream was already stopped externally - log but continue to finalize
            FileHandle.standardError.write(Data("Info: Stream was stopped externally, proceeding with finalization\n".utf8))
            streamStopError = externalStop.error
        } else {
            // Try to stop the stream normally
            do {
                try await activeRecording.stream.stopCapture()
            } catch {
                // Stream may have been stopped by OS-level interference from another process
                // Log the error but continue to finalize - we want to save what we captured
                FileHandle.standardError.write(Data("Warning: stopCapture() failed: \(error.localizedDescription). Attempting to finalize recording anyway.\n".utf8))
                streamStopError = error
            }
        }

        // Always attempt to finalize the writer to save captured frames
        // This is critical - even if stopCapture failed, we may have captured valuable frames
        do {
            _ = try await activeRecording.writer.finalize()
        } catch {
            // If finalization fails, try incremental manifest as last resort
            FileHandle.standardError.write(Data("Warning: finalize() failed: \(error.localizedDescription). Attempting incremental manifest save.\n".utf8))
            await activeRecording.writer.writeIncrementalManifest()
        }

        // Update session with final frame count
        let frameCount = await activeRecording.writer.currentFrameCount
        activeRecording.session.setFrameCount(frameCount)

        // Mark session status based on whether there were issues
        if let error = streamStopError {
            // Recording completed but with issues - mark as completed with a warning
            // The frames are still saved, just note the abnormal termination
            activeRecording.session.completeWithWarning("Stream stopped abnormally: \(error.localizedDescription)")
        } else {
            activeRecording.session.complete()
        }

        // Remove from active recordings
        activeRecordings.removeValue(forKey: targetId)

        return activeRecording.session
    }
}

// MARK: - Active Recording

private class ActiveRecording: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let session: RecordingSession
    private(set) var stream: SCStream!
    let writer: SparseFrameWriter
    let config: RecordingConfig

    /// Flag indicating the stream was stopped externally (not by us calling stopCapture)
    private(set) var wasStoppedExternally = false
    private(set) var externalStopError: Error?
    private let lock = NSLock()

    init(session: RecordingSession, stream: SCStream?, writer: SparseFrameWriter, config: RecordingConfig) {
        self.session = session
        self.stream = stream
        self.writer = writer
        self.config = config
    }

    func setStream(_ stream: SCStream) {
        self.stream = stream
    }

    // MARK: - SCStreamDelegate

    /// Called when the stream stops unexpectedly (e.g., due to external interference)
    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        lock.lock()
        defer { lock.unlock() }

        wasStoppedExternally = true
        externalStopError = error

        // Log the unexpected stop
        FileHandle.standardError.write(Data("Warning: SCStream stopped unexpectedly: \(error.localizedDescription)\n".utf8))

        // Trigger incremental manifest save to preserve what we have
        Task {
            await writer.writeIncrementalManifest()
        }
    }

    /// Check if stream was stopped externally
    func checkExternalStop() -> (stopped: Bool, error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        return (wasStoppedExternally, externalStopError)
    }

    // MARK: - SCStreamOutput

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
