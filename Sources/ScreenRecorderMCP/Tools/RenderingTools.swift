import Foundation

// MARK: - Render Recording Tool

struct RenderRecordingTool: MCPTool {
    let definition = MCPToolDefinition(
        name: "render_recording",
        description: "Render a sparse frame recording to video format (mp4, webm, or gif) using ffmpeg",
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "recording_path": .object([
                    "type": "string",
                    "description": "Path to the recording directory or manifest.json"
                ]),
                "output_format": .object([
                    "type": "string",
                    "enum": .array(["mp4", "webm", "gif"]),
                    "description": "Output video format"
                ]),
                "quality": .object([
                    "type": "string",
                    "enum": .array(["low", "medium", "high"]),
                    "default": "high",
                    "description": "Output quality preset"
                ]),
                "fps": .object([
                    "type": "integer",
                    "default": 30,
                    "description": "Target frame rate for output video"
                ]),
                "output_path": .object([
                    "type": "string",
                    "description": "Output file path (default: same directory as recording)"
                ])
            ]),
            "required": .array(["recording_path", "output_format"])
        ])
    )

    func execute(arguments: JSONValue) async throws -> MCPToolResult {
        guard let recordingPathStr = arguments["recording_path"]?.stringValue else {
            return .error("Missing required 'recording_path' parameter")
        }

        guard let outputFormatStr = arguments["output_format"]?.stringValue,
              let outputFormat = OutputVideoFormat(rawValue: outputFormatStr) else {
            return .error("Missing or invalid 'output_format' parameter. Must be 'mp4', 'webm', or 'gif'")
        }

        let quality = arguments["quality"]?.stringValue.flatMap { RenderQuality(rawValue: $0) } ?? .high
        let fps = arguments["fps"]?.intValue ?? 30
        let customOutputPath = arguments["output_path"]?.stringValue

        // Resolve recording directory and manifest
        let recordingPath = URL(fileURLWithPath: (recordingPathStr as NSString).expandingTildeInPath)
        let (recordingDir, manifest) = try resolveRecording(at: recordingPath)

        // Determine output path
        let outputPath: URL
        if let custom = customOutputPath {
            outputPath = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        } else {
            let baseName = recordingDir.lastPathComponent
            outputPath = recordingDir.appendingPathComponent("\(baseName).\(outputFormat.rawValue)")
        }

        // Check ffmpeg is available
        guard FileManager.default.fileExists(atPath: "/opt/homebrew/bin/ffmpeg") ||
              FileManager.default.fileExists(atPath: "/usr/local/bin/ffmpeg") ||
              FileManager.default.fileExists(atPath: "/usr/bin/ffmpeg") else {
            return .error("ffmpeg not found. Install with: brew install ffmpeg")
        }

        // Create concat demuxer file
        let concatFile = try createConcatFile(manifest: manifest, recordingDir: recordingDir)
        defer { try? FileManager.default.removeItem(at: concatFile) }

        // Build ffmpeg command
        let ffmpegArgs = buildFFmpegArgs(
            concatFile: concatFile,
            outputPath: outputPath,
            format: outputFormat,
            quality: quality,
            fps: fps,
            recordingDir: recordingDir
        )

        // Execute ffmpeg
        let result = try runFFmpeg(arguments: ffmpegArgs)

        if result.exitCode != 0 {
            return .error("ffmpeg failed with exit code \(result.exitCode): \(result.stderr)")
        }

        // Get output file size
        let fileSize: Int64
        if let attrs = try? FileManager.default.attributesOfItem(atPath: outputPath.path),
           let size = attrs[.size] as? Int64 {
            fileSize = size
        } else {
            fileSize = 0
        }

        return .json(.object([
            "status": .string("completed"),
            "output_path": .string(outputPath.path),
            "format": .string(outputFormat.rawValue),
            "file_size": .int(Int(fileSize)),
            "frame_count": .int(manifest.frames.count),
            "duration": .double(manifest.metadata.total_duration),
            "message": .string("Video rendered successfully")
        ]))
    }

    // MARK: - Private Helpers

    private func resolveRecording(at path: URL) throws -> (URL, SparseManifest) {
        let fileManager = FileManager.default
        var isDir: ObjCBool = false

        guard fileManager.fileExists(atPath: path.path, isDirectory: &isDir) else {
            throw RenderError.recordingNotFound(path.path)
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
            throw RenderError.invalidRecordingPath(path.path)
        }

        guard fileManager.fileExists(atPath: manifestPath.path) else {
            throw RenderError.manifestNotFound(manifestPath.path)
        }

        let data = try Data(contentsOf: manifestPath)
        let manifest = try JSONDecoder().decode(SparseManifest.self, from: data)

        return (recordingDir, manifest)
    }

    private func createConcatFile(manifest: SparseManifest, recordingDir: URL) throws -> URL {
        var lines = ["ffconcat version 1.0"]

        for frame in manifest.frames {
            let framePath = recordingDir.appendingPathComponent(frame.file).path
            lines.append("file '\(framePath)'")
            lines.append("duration \(frame.duration)")
        }

        // Add last frame again without duration (ffmpeg requirement)
        if let lastFrame = manifest.frames.last {
            let framePath = recordingDir.appendingPathComponent(lastFrame.file).path
            lines.append("file '\(framePath)'")
        }

        let concatContent = lines.joined(separator: "\n")
        let concatFile = recordingDir.appendingPathComponent("_concat.txt")
        try concatContent.write(to: concatFile, atomically: true, encoding: .utf8)

        return concatFile
    }

    private func buildFFmpegArgs(
        concatFile: URL,
        outputPath: URL,
        format: OutputVideoFormat,
        quality: RenderQuality,
        fps: Int,
        recordingDir: URL
    ) -> [String] {
        var args = [
            "-y",  // Overwrite output
            "-f", "concat",
            "-safe", "0",
            "-i", concatFile.path
        ]

        // No scaling - output at native resolution for maximum quality
        // Retina recordings will be 2x visual size but pixel-perfect crisp

        switch format {
        case .mp4:
            args += [
                "-c:v", "libx264",
                "-pix_fmt", "yuv420p",
                "-crf", quality.h264CRF,
                "-preset", "medium"
            ]

        case .webm:
            args += [
                "-c:v", "libvpx-vp9",
                "-crf", quality.vp9CRF,
                "-b:v", "0"
            ]

        case .gif:
            // GIF requires palette generation for quality
            let palettePath = recordingDir.appendingPathComponent("_palette.png").path
            args = [
                "-y",
                "-f", "concat",
                "-safe", "0",
                "-i", concatFile.path,
                "-vf", "fps=\(min(fps, 15)),palettegen=stats_mode=diff",
                palettePath
            ]
            // Will need two-pass for GIF, handled separately
        }

        args.append(outputPath.path)
        return args
    }

    private func runFFmpeg(arguments: [String]) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        // Find ffmpeg
        let ffmpegPath: String
        if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/ffmpeg") {
            ffmpegPath = "/opt/homebrew/bin/ffmpeg"
        } else if FileManager.default.fileExists(atPath: "/usr/local/bin/ffmpeg") {
            ffmpegPath = "/usr/local/bin/ffmpeg"
        } else {
            ffmpegPath = "/usr/bin/ffmpeg"
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        return (
            process.terminationStatus,
            String(data: stdoutData, encoding: .utf8) ?? "",
            String(data: stderrData, encoding: .utf8) ?? ""
        )
    }
}

// MARK: - Supporting Types

enum OutputVideoFormat: String {
    case mp4
    case webm
    case gif
}

enum RenderQuality: String {
    case low
    case medium
    case high

    var h264CRF: String {
        switch self {
        case .low: return "28"
        case .medium: return "23"
        case .high: return "18"
        }
    }

    var vp9CRF: String {
        switch self {
        case .low: return "40"
        case .medium: return "33"
        case .high: return "25"
        }
    }
}

enum RenderError: Error, LocalizedError {
    case recordingNotFound(String)
    case manifestNotFound(String)
    case invalidRecordingPath(String)
    case ffmpegFailed(String)

    var errorDescription: String? {
        switch self {
        case .recordingNotFound(let path):
            return "Recording not found at: \(path)"
        case .manifestNotFound(let path):
            return "Manifest not found at: \(path)"
        case .invalidRecordingPath(let path):
            return "Invalid recording path: \(path). Expected directory or manifest.json"
        case .ffmpegFailed(let reason):
            return "ffmpeg failed: \(reason)"
        }
    }
}

// MARK: - Manifest Decoding

struct SparseManifest: Codable {
    let version: String
    let metadata: SparseMetadata
    let frames: [SparseFrame]
}

struct SparseMetadata: Codable {
    let created_at: String
    let session_id: String
    let window_id: Int
    let window_title: String
    let width: Int
    let height: Int
    let total_duration: Double
    let frame_count: Int
}

struct SparseFrame: Codable {
    let index: Int
    let timestamp: Double
    let duration: Double
    let file: String
}
