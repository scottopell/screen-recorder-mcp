import Foundation

// MARK: - Start Recording Tool

struct StartRecordingTool: MCPTool {
    let definition = MCPToolDefinition(
        name: "start_recording",
        description: "Start recording the screen, a specific window, or application",
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "mode": .object([
                    "type": "string",
                    "enum": .array(["screen", "window", "app", "region"]),
                    "description": "What to record: screen (full display), window (specific window), app (all windows of an app), or region"
                ]),
                "display_id": .object([
                    "type": "integer",
                    "description": "Display ID for screen mode (from list_displays)"
                ]),
                "window_id": .object([
                    "type": "integer",
                    "description": "Window ID for window mode (from list_windows)"
                ]),
                "app_bundle_id": .object([
                    "type": "string",
                    "description": "Application bundle ID for app mode (from list_apps)"
                ]),
                "output_path": .object([
                    "type": "string",
                    "description": "Output directory path (default: ~/Movies/ScreenRecordings/)"
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
                    "enum": .array(["low", "medium", "high", "lossless"]),
                    "default": "high",
                    "description": "Recording quality preset"
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
            "required": .array(["mode"])
        ])
    )

    func execute(arguments: JSONValue) async throws -> MCPToolResult {
        // Parse mode
        guard let modeString = arguments["mode"]?.stringValue,
              let mode = RecordingMode(rawValue: modeString) else {
            return .error("Invalid or missing 'mode' parameter. Must be one of: screen, window, app, region")
        }

        // Parse optional parameters
        let displayID = arguments["display_id"]?.intValue.map { UInt32($0) }
        let windowID = arguments["window_id"]?.intValue.map { UInt32($0) }
        let appBundleID = arguments["app_bundle_id"]?.stringValue

        let outputPath = arguments["output_path"]?.stringValue.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        let filename = arguments["filename"]?.stringValue

        let format = arguments["format"]?.stringValue.flatMap { OutputFormat(rawValue: $0) } ?? .mov
        let codec = arguments["codec"]?.stringValue.flatMap { VideoCodec(rawValue: $0) } ?? .h264
        let quality = arguments["quality"]?.stringValue.flatMap { QualityPreset(rawValue: $0) } ?? .high
        let fps = arguments["fps"]?.intValue ?? 30

        let captureCursor = arguments["capture_cursor"]?.boolValue ?? true
        let maxDuration = arguments["max_duration"]?.intValue.map { TimeInterval($0) }
        let sessionName = arguments["session_name"]?.stringValue

        // Validate mode-specific requirements
        switch mode {
        case .window:
            guard windowID != nil else {
                return .error("Window mode requires 'window_id' parameter. Use list_windows to find available windows.")
            }
        case .app:
            guard appBundleID != nil else {
                return .error("App mode requires 'app_bundle_id' parameter. Use list_apps to find available applications.")
            }
        case .screen, .region:
            break  // Display ID is optional, will use primary display
        }

        // Create configuration
        let config = RecordingConfig(
            mode: mode,
            displayID: displayID,
            windowID: windowID,
            appBundleID: appBundleID,
            region: nil,  // Region parsing would go here
            outputDirectory: outputPath,
            filename: filename,
            format: format,
            codec: codec,
            quality: quality,
            fps: fps,
            captureCursor: captureCursor,
            captureClicks: false,
            audio: .none,  // Audio config would go here
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
                "mode": .string(mode.rawValue),
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

// MARK: - Pause Recording Tool

struct PauseRecordingTool: MCPTool {
    let definition = MCPToolDefinition(
        name: "pause_recording",
        description: "Pause an active recording (can be resumed)",
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "session_id": .object([
                    "type": "string",
                    "description": "Session ID (optional if only one active)"
                ])
            ]),
            "required": .array([])
        ])
    )

    func execute(arguments: JSONValue) async throws -> MCPToolResult {
        let sessionId = arguments["session_id"]?.stringValue

        do {
            let session = try await ScreenRecorder.shared.pauseRecording(sessionId: sessionId)

            return .json(.object([
                "session_id": .string(session.id),
                "status": .string("paused"),
                "duration": .double(session.duration),
                "message": .string("Recording paused")
            ]))
        } catch {
            return .error("Failed to pause recording: \(error.localizedDescription)")
        }
    }
}

// MARK: - Resume Recording Tool

struct ResumeRecordingTool: MCPTool {
    let definition = MCPToolDefinition(
        name: "resume_recording",
        description: "Resume a paused recording",
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "session_id": .object([
                    "type": "string",
                    "description": "Session ID (optional if only one active)"
                ])
            ]),
            "required": .array([])
        ])
    )

    func execute(arguments: JSONValue) async throws -> MCPToolResult {
        let sessionId = arguments["session_id"]?.stringValue

        do {
            let session = try await ScreenRecorder.shared.resumeRecording(sessionId: sessionId)

            return .json(.object([
                "session_id": .string(session.id),
                "status": .string("recording"),
                "duration": .double(session.duration),
                "message": .string("Recording resumed")
            ]))
        } catch {
            return .error("Failed to resume recording: \(error.localizedDescription)")
        }
    }
}

// MARK: - Cancel Recording Tool

struct CancelRecordingTool: MCPTool {
    let definition = MCPToolDefinition(
        name: "cancel_recording",
        description: "Cancel recording and delete partial output",
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "session_id": .object([
                    "type": "string",
                    "description": "Session ID (optional if only one active)"
                ])
            ]),
            "required": .array([])
        ])
    )

    func execute(arguments: JSONValue) async throws -> MCPToolResult {
        let sessionId = arguments["session_id"]?.stringValue

        do {
            try await ScreenRecorder.shared.cancelRecording(sessionId: sessionId)

            return .json(.object([
                "status": .string("cancelled"),
                "message": .string("Recording cancelled and partial file deleted")
            ]))
        } catch {
            return .error("Failed to cancel recording: \(error.localizedDescription)")
        }
    }
}

// MARK: - Get Recording Status Tool

struct GetRecordingStatusTool: MCPTool {
    let definition = MCPToolDefinition(
        name: "get_recording_status",
        description: "Get status of active recording session(s)",
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "session_id": .object([
                    "type": "string",
                    "description": "Specific session (optional, returns all if omitted)"
                ])
            ]),
            "required": .array([])
        ])
    )

    func execute(arguments: JSONValue) async throws -> MCPToolResult {
        let sessionId = arguments["session_id"]?.stringValue

        if let id = sessionId {
            // Return specific session
            if let session = await SessionManager.shared.getSession(id) {
                return .json(.object([
                    "sessions": .array([session.toJSON()])
                ]))
            } else {
                return .error("Session not found: \(id)")
            }
        } else {
            // Return all active sessions
            let sessions = await SessionManager.shared.getAllActiveSessions()
            return .json(.object([
                "sessions": .array(sessions.map { $0.toJSON() }),
                "count": .int(sessions.count)
            ]))
        }
    }
}
