import Foundation
import CoreMedia
import CoreVideo
import AppKit

/// Writes frames as individual PNG files with a JSON manifest
/// Optimized for sparse frame delivery from ScreenCaptureKit
actor SparseFrameWriter {
    private let outputDirectory: URL
    private let framesDirectory: URL
    private var frameIndex: Int = 0
    private var frames: [FrameEntry] = []
    private var lastTimestamp: CMTime?
    private var metadata: RecordingMetadata
    private var isFinalized = false

    struct FrameEntry: Codable {
        let index: Int
        let timestamp: Double
        var duration: Double
        let file: String
    }

    struct RecordingMetadata: Codable {
        let created_at: String
        let session_id: String
        let window_id: Int
        let window_title: String
        var width: Int
        var height: Int
        var total_duration: Double
        var frame_count: Int
        let scale_factor: Double  // Display scale factor (2.0 for retina)
    }

    struct Manifest: Codable {
        let version: String
        let metadata: RecordingMetadata
        let frames: [FrameEntry]
    }

    init(outputDirectory: URL, sessionId: String, windowId: Int, windowTitle: String, scaleFactor: Double = 1.0) throws {
        self.outputDirectory = outputDirectory
        self.framesDirectory = outputDirectory.appendingPathComponent("frames")

        // Create directories
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: framesDirectory, withIntermediateDirectories: true)

        // Initialize metadata
        let dateFormatter = ISO8601DateFormatter()
        self.metadata = RecordingMetadata(
            created_at: dateFormatter.string(from: Date()),
            session_id: sessionId,
            window_id: windowId,
            window_title: windowTitle,
            width: 0,
            height: 0,
            total_duration: 0,
            frame_count: 0,
            scale_factor: scaleFactor
        )
    }

    /// Append a frame to the recording
    func appendFrame(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        guard !isFinalized else { return }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        // Update metadata dimensions on first frame
        if frameIndex == 0 {
            metadata.width = width
            metadata.height = height
        }

        // Calculate duration of previous frame
        if let lastTime = lastTimestamp, !frames.isEmpty {
            let duration = CMTimeGetSeconds(presentationTime) - CMTimeGetSeconds(lastTime)
            frames[frames.count - 1].duration = duration
        }

        // Generate filename
        let filename = String(format: "frame_%04d.png", frameIndex)
        let framePath = framesDirectory.appendingPathComponent(filename)

        // Write PNG (fast compression for real-time capture)
        if let pngData = createPNGData(from: pixelBuffer) {
            do {
                try pngData.write(to: framePath)

                // Add frame entry
                let entry = FrameEntry(
                    index: frameIndex,
                    timestamp: CMTimeGetSeconds(presentationTime),
                    duration: 0, // Will be calculated when next frame arrives or on finalize
                    file: "frames/\(filename)"
                )
                frames.append(entry)

                lastTimestamp = presentationTime
                frameIndex += 1
            } catch {
                // Log error but continue - don't crash recording
                FileHandle.standardError.write(Data("Warning: Failed to write frame \(frameIndex): \(error)\n".utf8))
            }
        }
    }

    /// Finalize the recording and write the manifest
    func finalize(defaultLastFrameDuration: Double = 1.0) throws -> URL {
        guard !isFinalized else {
            return outputDirectory.appendingPathComponent("manifest.json")
        }

        isFinalized = true

        // Set duration of last frame
        if !frames.isEmpty {
            frames[frames.count - 1].duration = defaultLastFrameDuration
        }

        // Calculate total duration
        let totalDuration = frames.reduce(0) { $0 + $1.duration }

        // Update metadata
        metadata.total_duration = totalDuration
        metadata.frame_count = frames.count

        // Create manifest
        let manifest = Manifest(
            version: "1.0",
            metadata: metadata,
            frames: frames
        )

        // Write manifest
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestData = try encoder.encode(manifest)

        let manifestPath = outputDirectory.appendingPathComponent("manifest.json")
        try manifestData.write(to: manifestPath)

        return manifestPath
    }

    /// Get the output directory path
    var outputPath: URL {
        return outputDirectory
    }

    /// Get current frame count
    var currentFrameCount: Int {
        return frameIndex
    }

    // MARK: - Private Helpers

    private func createPNGData(from pixelBuffer: CVPixelBuffer) -> Data? {
        // Lock the pixel buffer
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return nil
        }

        // Create CGImage from pixel buffer (BGRA format)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            return nil
        }

        guard let cgImage = context.makeImage() else {
            return nil
        }

        // Create NSBitmapImageRep for PNG encoding
        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)

        // Use fast PNG compression (no compression filter for speed)
        return bitmapRep.representation(
            using: .png,
            properties: [.compressionFactor: 0.0] // 0.0 = fastest (no filtering)
        )
    }
}
