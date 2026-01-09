import Foundation

// MARK: - Run Demo Script Tool

struct RunDemoScriptTool: MCPTool {
    let definition = MCPToolDefinition(
        name: "run_demo_script",
        description: "Execute a scripted terminal demo with precise timing. Starts recording, runs commands with specified delays, then stops recording. Eliminates LLM API latency from recordings.",
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "window_id": .object([
                    "type": "integer",
                    "description": "Window ID to record (from launch_terminal)"
                ]),
                "session_name": .object([
                    "type": "string",
                    "description": "tmux session name from launch_terminal"
                ]),
                "commands": .object([
                    "type": "array",
                    "description": "Array of commands to execute. Each item is either { \"text\": \"command\" } to run a command (Enter auto-appended), or { \"delay_ms\": milliseconds } to wait. MUST include delay_ms commands between text commands for proper pacing.",
                    "items": .object([
                        "type": "object",
                        "properties": .object([
                            "text": .object([
                                "type": "string",
                                "description": "Command text to send. Enter is automatically appended."
                            ]),
                            "delay_ms": .object([
                                "type": "integer",
                                "description": "Delay in milliseconds to wait before next command"
                            ])
                        ])
                    ])
                ])
            ]),
            "required": .array(["session_name", "commands"])
        ])
    )

    func execute(arguments: JSONValue) async throws -> MCPToolResult {
        // Extract session_name (required)
        guard let sessionName = arguments["session_name"]?.stringValue else {
            return .error("Missing required 'session_name' parameter")
        }

        // Get window_id - either from args or lookup from session store
        let windowID: UInt32
        if let providedWindowId = arguments["window_id"]?.intValue {
            windowID = UInt32(providedWindowId)
        } else if let session = await TerminalSessionStore.shared.lookup(sessionName: sessionName) {
            windowID = session.windowId
        } else {
            return .error("Missing 'window_id' and session '\(sessionName)' not found in store. Provide window_id or use a session from launch_terminal.")
        }

        // Extract commands array
        guard let commandsArray = arguments["commands"]?.arrayValue, !commandsArray.isEmpty else {
            return .error("Missing or empty 'commands' array")
        }

        // Parse commands - supports { "text": "..." } and { "delay_ms": ms }
        enum DemoCommand {
            case text(String)
            case delay(Int)
        }

        var commands: [DemoCommand] = []
        var hasDelay = false
        for (index, cmd) in commandsArray.enumerated() {
            if let text = cmd["text"]?.stringValue {
                commands.append(.text(text))
            } else if let delayMs = cmd["delay_ms"]?.intValue {
                commands.append(.delay(delayMs))
                hasDelay = true
            } else {
                return .error("Command at index \(index) must have either 'text' or 'delay_ms' field")
            }
        }

        // Require at least one delay for proper pacing
        if !hasDelay {
            return .error("Commands must include at least one { \"delay_ms\": N } for proper pacing. Add delays between commands based on expected execution time.")
        }

        // Verify tmux session exists
        if let error = verifyTmuxSession(sessionName) {
            return .error(error)
        }

        // Start recording
        let config = RecordingConfig(
            windowID: windowID,
            outputDirectory: nil,
            fps: 30,
            captureCursor: true,
            maxDuration: nil,
            sessionName: "demo"
        )

        let session: RecordingSession
        do {
            session = try await ScreenRecorder.shared.startRecording(config: config)
        } catch {
            return .error("Failed to start recording: \(error.localizedDescription)")
        }

        // Execute commands, ensuring we stop recording even on error
        var commandsExecuted = 0
        var executionError: String?

        do {
            // Small initial delay to capture clean starting frame
            try await Task.sleep(nanoseconds: 200_000_000) // 200ms

            for (index, command) in commands.enumerated() {
                switch command {
                case .text(let text):
                    // Send command via tmux (auto-append Enter)
                    if let error = sendTerminalCommand(text: text, sessionName: sessionName) {
                        executionError = "Command \(index) failed: \(error)"
                        break
                    }
                    commandsExecuted += 1

                case .delay(let ms):
                    try await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
                }
            }
        } catch {
            executionError = "Execution interrupted: \(error.localizedDescription)"
        }

        // Stop recording
        let completedSession: RecordingSession
        do {
            completedSession = try await ScreenRecorder.shared.stopRecording(sessionId: session.id)
        } catch {
            return .error("Failed to stop recording: \(error.localizedDescription). Commands executed: \(commandsExecuted)")
        }

        // Save demo script to manifest
        saveDemoScriptToManifest(
            outputPath: completedSession.outputPath,
            commands: commandsArray
        )

        // Build response
        var response: [String: JSONValue] = [
            "status": .string(executionError == nil ? "completed" : "partial"),
            "recording_path": .string(completedSession.outputPath.path),
            "manifest_path": .string(completedSession.outputPath.appendingPathComponent("manifest.json").path),
            "duration": .double(completedSession.duration),
            "frame_count": .int(completedSession.frameCount),
            "commands_executed": .int(commandsExecuted)
        ]

        if let error = executionError {
            response["error"] = .string(error)
            response["message"] = .string("Demo partially completed. Recording saved.")
        } else {
            response["message"] = .string("Demo completed successfully. Use render_recording to convert to video.")
        }

        return .json(.object(response))
    }

    // MARK: - Private Helpers

    private func verifyTmuxSession(_ sessionName: String) -> String? {
        let checkProcess = Process()
        checkProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        checkProcess.arguments = ["tmux", "-L", "mcp", "has-session", "-t", sessionName]

        do {
            try checkProcess.run()
            checkProcess.waitUntilExit()
            if checkProcess.terminationStatus != 0 {
                return "tmux session '\(sessionName)' not found"
            }
        } catch {
            return "Failed to check tmux session: \(error.localizedDescription)"
        }

        return nil
    }

    /// Send a command to terminal, automatically appending Enter
    private func sendTerminalCommand(text: String, sessionName: String) -> String? {
        // Send the text using tmux send-keys -l (literal mode)
        if !text.isEmpty {
            let sendKeys = Process()
            sendKeys.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            sendKeys.arguments = ["tmux", "-L", "mcp", "send-keys", "-l", "-t", sessionName, text]

            do {
                try sendKeys.run()
                sendKeys.waitUntilExit()
                if sendKeys.terminationStatus != 0 {
                    return "tmux send-keys failed"
                }
            } catch {
                return "Failed to send keys: \(error.localizedDescription)"
            }
        }

        // Auto-append Enter
        let enterProcess = Process()
        enterProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        enterProcess.arguments = ["tmux", "-L", "mcp", "send-keys", "-t", sessionName, "Enter"]

        do {
            try enterProcess.run()
            enterProcess.waitUntilExit()
        } catch {
            return "Failed to send Enter key: \(error.localizedDescription)"
        }

        return nil
    }

    /// Save demo script commands to manifest.json
    private func saveDemoScriptToManifest(outputPath: URL, commands: [JSONValue]) {
        let manifestPath = outputPath.appendingPathComponent("manifest.json")

        do {
            // Read existing manifest
            let data = try Data(contentsOf: manifestPath)
            guard var manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }

            // Convert JSONValue commands to serializable format
            let scriptCommands: [[String: Any]] = commands.compactMap { cmd in
                if let text = cmd["text"]?.stringValue {
                    return ["text": text]
                } else if let delayMs = cmd["delay_ms"]?.intValue {
                    return ["delay_ms": delayMs]
                }
                return nil
            }

            // Add demo_script field
            manifest["demo_script"] = scriptCommands

            // Write back
            let updatedData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            try updatedData.write(to: manifestPath)
        } catch {
            // Non-fatal - just log and continue
            FileHandle.standardError.write(Data("Warning: Failed to save demo script to manifest: \(error)\n".utf8))
        }
    }
}
