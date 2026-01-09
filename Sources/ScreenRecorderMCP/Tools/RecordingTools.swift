import Foundation

// MARK: - Start Recording Tool

struct StartRecordingTool: MCPTool {
    let definition = MCPToolDefinition(
        name: "start_recording",
        description: "Start recording a specific window",
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "window_id": .object([
                    "type": "integer",
                    "description": "Window ID to record (from list_windows or launch_app)"
                ]),
                "output_path": .object([
                    "type": "string",
                    "description": "Output directory path (default: .screen-recordings/)"
                ]),
                "filename": .object([
                    "type": "string",
                    "description": "Output filename (default: recording_<timestamp>.mov)"
                ]),
                "format": .object([
                    "type": "string",
                    "enum": .array(["mov", "mp4"]),
                    "default": "mov",
                    "description": "Output container format"
                ]),
                "codec": .object([
                    "type": "string",
                    "enum": .array(["h264", "h265", "prores"]),
                    "default": "h264",
                    "description": "Video codec"
                ]),
                "quality": .object([
                    "type": "string",
                    "enum": .array(["dev", "prod"]),
                    "default": "dev",
                    "description": "Recording quality preset. 'dev' (default) is good for dev/iteration. 'prod' is for production/final recordings with maximum quality."
                ]),
                "fps": .object([
                    "type": "integer",
                    "default": 30,
                    "minimum": 1,
                    "maximum": 120,
                    "description": "Frames per second"
                ]),
                "capture_cursor": .object([
                    "type": "boolean",
                    "default": true,
                    "description": "Include mouse cursor in recording"
                ]),
                "max_duration": .object([
                    "type": "integer",
                    "description": "Maximum recording duration in seconds (auto-stop)"
                ]),
                "session_name": .object([
                    "type": "string",
                    "description": "Human-readable name for this recording session"
                ])
            ]),
            "required": .array(["window_id"])
        ])
    )

    func execute(arguments: JSONValue) async throws -> MCPToolResult {
        // Require window_id
        guard let windowID = arguments["window_id"]?.intValue else {
            return .error("Missing required 'window_id' parameter. Use list_windows or launch_app to get a window ID.")
        }

        // Parse optional parameters
        let outputPath = arguments["output_path"]?.stringValue.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        let filename = arguments["filename"]?.stringValue

        let format = arguments["format"]?.stringValue.flatMap { OutputFormat(rawValue: $0) } ?? .mov
        let codec = arguments["codec"]?.stringValue.flatMap { VideoCodec(rawValue: $0) } ?? .h264
        let quality = arguments["quality"]?.stringValue.flatMap { QualityPreset(rawValue: $0) } ?? .dev
        let fps = arguments["fps"]?.intValue ?? 30

        let captureCursor = arguments["capture_cursor"]?.boolValue ?? true
        let maxDuration = arguments["max_duration"]?.intValue.map { TimeInterval($0) }
        let sessionName = arguments["session_name"]?.stringValue

        // Create configuration (window mode only)
        let config = RecordingConfig(
            windowID: UInt32(windowID),
            outputDirectory: outputPath,
            filename: filename,
            format: format,
            codec: codec,
            quality: quality,
            fps: fps,
            captureCursor: captureCursor,
            maxDuration: maxDuration,
            sessionName: sessionName
        )

        // Start recording
        do {
            let session = try await ScreenRecorder.shared.startRecording(config: config)

            return .json(.object([
                "session_id": .string(session.id),
                "status": .string("recording"),
                "output_path": .string(session.outputPath.path),
                "started_at": .string(ISO8601DateFormatter().string(from: session.startedAt)),
                "window_id": .int(windowID),
                "message": .string("Recording started successfully")
            ]))
        } catch {
            return .error("Failed to start recording: \(error.localizedDescription)")
        }
    }
}

// MARK: - Stop Recording Tool

struct StopRecordingTool: MCPTool {
    let definition = MCPToolDefinition(
        name: "stop_recording",
        description: "Stop an active recording and finalize the output file",
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "session_id": .object([
                    "type": "string",
                    "description": "Session ID from start_recording (optional if only one active)"
                ])
            ]),
            "required": .array([])
        ])
    )

    func execute(arguments: JSONValue) async throws -> MCPToolResult {
        let sessionId = arguments["session_id"]?.stringValue

        do {
            let session = try await ScreenRecorder.shared.stopRecording(sessionId: sessionId)

            // Get file size
            let fileSize: Int64
            if let attrs = try? FileManager.default.attributesOfItem(atPath: session.outputPath.path),
               let size = attrs[.size] as? Int64 {
                fileSize = size
            } else {
                fileSize = 0
            }

            return .json(.object([
                "session_id": .string(session.id),
                "status": .string("completed"),
                "output_path": .string(session.outputPath.path),
                "duration": .double(session.duration),
                "file_size": .int(Int(fileSize)),
                "message": .string("Recording completed successfully")
            ]))
        } catch {
            return .error("Failed to stop recording: \(error.localizedDescription)")
        }
    }
}
