import Foundation

// MARK: - Start Recording Tool

struct StartRecordingTool: MCPTool {
    let definition = MCPToolDefinition(
        name: "start_recording",
        description: "Start recording a specific window. Outputs sparse PNG frames with JSON manifest. Use render_recording to convert to video.",
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "window_id": .object([
                    "type": "integer",
                    "description": "Window ID to record (from list_windows or launch_terminal)"
                ]),
                "output_path": .object([
                    "type": "string",
                    "description": "Output directory path (default: .screen-recordings/)"
                ]),
                "fps": .object([
                    "type": "integer",
                    "default": 30,
                    "minimum": 1,
                    "maximum": 120,
                    "description": "Maximum frames per second (actual rate depends on content changes)"
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
            return .error("Missing required 'window_id' parameter. Use list_windows or launch_terminal to get a window ID.")
        }

        // Parse optional parameters
        let outputPath = arguments["output_path"]?.stringValue.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        let fps = arguments["fps"]?.intValue ?? 30
        let captureCursor = arguments["capture_cursor"]?.boolValue ?? true
        let maxDuration = arguments["max_duration"]?.intValue.map { TimeInterval($0) }
        let sessionName = arguments["session_name"]?.stringValue

        // Create configuration
        let config = RecordingConfig(
            windowID: UInt32(windowID),
            outputDirectory: outputPath,
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
        description: "Stop an active recording and finalize the sparse frame archive",
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

            // Calculate total directory size
            let totalSize = calculateDirectorySize(at: session.outputPath)

            return .json(.object([
                "session_id": .string(session.id),
                "status": .string("completed"),
                "output_path": .string(session.outputPath.path),
                "manifest_path": .string(session.outputPath.appendingPathComponent("manifest.json").path),
                "duration": .double(session.duration),
                "frame_count": .int(session.frameCount),
                "total_size": .int(Int(totalSize)),
                "message": .string("Recording completed successfully. Use render_recording to convert to video.")
            ]))
        } catch {
            return .error("Failed to stop recording: \(error.localizedDescription)")
        }
    }

    private func calculateDirectorySize(at url: URL) -> Int64 {
        var totalSize: Int64 = 0
        let fileManager = FileManager.default

        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }

        for case let fileURL as URL in enumerator {
            if let fileSize = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                totalSize += Int64(fileSize)
            }
        }

        return totalSize
    }
}
