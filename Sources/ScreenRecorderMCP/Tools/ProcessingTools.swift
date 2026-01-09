import Foundation
import AVFoundation
import CoreImage
import AppKit

// MARK: - Extract Frame Tool

struct ExtractFrameTool: MCPTool {
    let definition = MCPToolDefinition(
        name: "extract_frame",
        description: "Extract a single frame from a recording as an image. Useful for verifying what was recorded.",
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "recording_path": .object([
                    "type": "string",
                    "description": "Path to the recording file"
                ]),
                "timestamp": .object([
                    "type": "number",
                    "description": "Timestamp in seconds (default: 0 for first frame, -1 for last frame)"
                ]),
                "timestamp_percent": .object([
                    "type": "number",
                    "description": "Timestamp as percentage of duration (0-100)"
                ]),
                "output_path": .object([
                    "type": "string",
                    "description": "Where to save the frame (default: .screen-recordings/frames/)"
                ]),
                "format": .object([
                    "type": "string",
                    "enum": .array(["png", "jpg"]),
                    "default": "png",
                    "description": "Output image format"
                ]),
                "scale": .object([
                    "type": "number",
                    "default": 1.0,
                    "description": "Scale factor (e.g., 0.5 for half size)"
                ])
            ]),
            "required": .array(["recording_path"])
        ])
    )

    func execute(arguments: JSONValue) async throws -> MCPToolResult {
        guard let pathString = arguments["recording_path"]?.stringValue else {
            return .error("Missing required parameter: recording_path")
        }

        let path = (pathString as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: path)

        // Check file exists
        guard FileManager.default.fileExists(atPath: path) else {
            return .error("File not found: \(path)")
        }

        // Parse parameters
        let timestamp = arguments["timestamp"]?.doubleValue
        let timestampPercent = arguments["timestamp_percent"]?.doubleValue
        let outputPathString = arguments["output_path"]?.stringValue
        let format = arguments["format"]?.stringValue ?? "png"
        let scale = arguments["scale"]?.doubleValue ?? 1.0

        // Create asset and image generator
        let asset = AVAsset(url: url)
        let duration = CMTimeGetSeconds(asset.duration)

        guard duration > 0 else {
            return .error("Invalid video duration")
        }

        // Calculate target time
        var targetSeconds: Double
        if let percent = timestampPercent {
            targetSeconds = (percent / 100.0) * duration
        } else if let ts = timestamp {
            if ts < 0 {
                // Negative means from end
                targetSeconds = duration + ts
            } else {
                targetSeconds = ts
            }
        } else {
            targetSeconds = 0  // Default to first frame
        }

        // Clamp to valid range
        targetSeconds = max(0, min(duration - 0.01, targetSeconds))

        let targetTime = CMTime(seconds: targetSeconds, preferredTimescale: 600)

        // Create image generator
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        imageGenerator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)

        // Apply scale if needed
        if scale != 1.0 {
            if let videoTrack = asset.tracks(withMediaType: .video).first {
                let naturalSize = videoTrack.naturalSize
                let scaledSize = CGSize(
                    width: naturalSize.width * scale,
                    height: naturalSize.height * scale
                )
                imageGenerator.maximumSize = scaledSize
            }
        }

        // Generate image
        let cgImage: CGImage
        let actualTime: CMTime
        do {
            (cgImage, actualTime) = try await imageGenerator.image(at: targetTime)
        } catch {
            return .error("Failed to extract frame: \(error.localizedDescription)")
        }

        // Create NSImage from CGImage
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))

        // Determine output path
        let outputURL: URL
        if let outputPathStr = outputPathString {
            outputURL = URL(fileURLWithPath: (outputPathStr as NSString).expandingTildeInPath)
        } else {
            // Use .screen-recordings/frames in current working directory
            let framesDir = RecordingConfig.defaultFramesDirectory
            try? FileManager.default.createDirectory(at: framesDir, withIntermediateDirectories: true)
            let filename = "frame_\(UUID().uuidString.prefix(8)).\(format)"
            outputURL = framesDir.appendingPathComponent(filename)
        }

        // Save image
        let imageData: Data
        if format == "jpg" || format == "jpeg" {
            guard let data = nsImage.jpegData(compressionQuality: 0.9) else {
                return .error("Failed to encode JPEG")
            }
            imageData = data
        } else {
            guard let data = nsImage.pngData() else {
                return .error("Failed to encode PNG")
            }
            imageData = data
        }

        do {
            try imageData.write(to: outputURL)
        } catch {
            return .error("Failed to save image: \(error.localizedDescription)")
        }

        // Build result
        return .json(.object([
            "output_path": .string(outputURL.path),
            "timestamp": .double(CMTimeGetSeconds(actualTime)),
            "width": .int(cgImage.width),
            "height": .int(cgImage.height),
            "format": .string(format)
        ]))
    }
}

// MARK: - NSImage Extensions

extension NSImage {
    func pngData() -> Data? {
        guard let tiffData = tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }

    func jpegData(compressionQuality: CGFloat) -> Data? {
        guard let tiffData = tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: compressionQuality])
    }
}
