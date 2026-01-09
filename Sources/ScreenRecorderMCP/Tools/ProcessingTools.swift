import Foundation
import AppKit

// MARK: - Extract Frame Tool

struct ExtractFrameTool: MCPTool {
    let definition = MCPToolDefinition(
        name: "extract_frame",
        description: "Extract a frame from a sparse recording. Returns the path to the PNG frame at the requested timestamp.",
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "recording_path": .object([
                    "type": "string",
                    "description": "Path to the recording directory or manifest.json"
                ]),
                "timestamp": .object([
                    "type": "number",
                    "description": "Timestamp in seconds (default: 0 for first frame, -1 for last frame)"
                ]),
                "timestamp_percent": .object([
                    "type": "number",
                    "description": "Timestamp as percentage of duration (0-100)"
                ]),
                "frame_index": .object([
                    "type": "integer",
                    "description": "Direct frame index (0-based). Overrides timestamp if provided."
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

        // Resolve recording directory and manifest
        let (recordingDir, manifest) = try resolveRecording(at: url)

        guard !manifest.frames.isEmpty else {
            return .error("Recording has no frames")
        }

        // Parse parameters
        let timestamp = arguments["timestamp"]?.doubleValue
        let timestampPercent = arguments["timestamp_percent"]?.doubleValue
        let frameIndex = arguments["frame_index"]?.intValue

        // Find the target frame
        let targetFrame: SparseFrame

        if let index = frameIndex {
            // Direct frame index
            guard index >= 0 && index < manifest.frames.count else {
                return .error("Frame index \(index) out of range (0-\(manifest.frames.count - 1))")
            }
            targetFrame = manifest.frames[index]
        } else {
            // Calculate target time
            let duration = manifest.metadata.total_duration
            var targetSeconds: Double

            if let percent = timestampPercent {
                targetSeconds = (percent / 100.0) * duration
            } else if let ts = timestamp {
                if ts < 0 {
                    // Negative means from end (-1 = last frame)
                    targetSeconds = duration + ts
                } else {
                    targetSeconds = ts
                }
            } else {
                targetSeconds = 0  // Default to first frame
            }

            // Clamp to valid range
            targetSeconds = max(0, min(duration, targetSeconds))

            // Find frame at timestamp
            targetFrame = findFrameAt(timestamp: targetSeconds, in: manifest.frames)
        }

        // Build full path to frame
        let framePath = recordingDir.appendingPathComponent(targetFrame.file)

        guard FileManager.default.fileExists(atPath: framePath.path) else {
            return .error("Frame file not found: \(framePath.path)")
        }

        // Get image dimensions
        var width = manifest.metadata.width
        var height = manifest.metadata.height

        // Try to get actual dimensions from image
        if let image = NSImage(contentsOf: framePath) {
            width = Int(image.size.width)
            height = Int(image.size.height)
        }

        return .json(.object([
            "output_path": .string(framePath.path),
            "timestamp": .double(targetFrame.timestamp),
            "duration": .double(targetFrame.duration),
            "frame_index": .int(targetFrame.index),
            "width": .int(width),
            "height": .int(height),
            "format": .string("png")
        ]))
    }

    // MARK: - Private Helpers

    private func resolveRecording(at path: URL) throws -> (URL, SparseManifest) {
        let fileManager = FileManager.default
        var isDir: ObjCBool = false

        guard fileManager.fileExists(atPath: path.path, isDirectory: &isDir) else {
            throw ExtractError.recordingNotFound(path.path)
        }

        let manifestPath: URL
        let recordingDir: URL

        if isDir.boolValue {
            recordingDir = path
            manifestPath = path.appendingPathComponent("manifest.json")
        } else if path.lastPathComponent == "manifest.json" {
            manifestPath = path
            recordingDir = path.deletingLastPathComponent()
        } else {
            throw ExtractError.invalidRecordingPath(path.path)
        }

        guard fileManager.fileExists(atPath: manifestPath.path) else {
            throw ExtractError.manifestNotFound(manifestPath.path)
        }

        let data = try Data(contentsOf: manifestPath)
        let manifest = try JSONDecoder().decode(SparseManifest.self, from: data)

        return (recordingDir, manifest)
    }

    private func findFrameAt(timestamp: Double, in frames: [SparseFrame]) -> SparseFrame {
        // Find the frame that contains the given timestamp
        var currentTime: Double = 0

        for frame in frames {
            let frameEnd = currentTime + frame.duration
            if timestamp >= currentTime && timestamp < frameEnd {
                return frame
            }
            currentTime = frameEnd
        }

        // Return last frame if timestamp is at or beyond the end
        return frames.last!
    }
}

// MARK: - Error Types

enum ExtractError: Error, LocalizedError {
    case recordingNotFound(String)
    case manifestNotFound(String)
    case invalidRecordingPath(String)

    var errorDescription: String? {
        switch self {
        case .recordingNotFound(let path):
            return "Recording not found at: \(path)"
        case .manifestNotFound(let path):
            return "Manifest not found at: \(path)"
        case .invalidRecordingPath(let path):
            return "Invalid recording path: \(path). Expected directory or manifest.json"
        }
    }
}
