import Foundation
import ScreenCaptureKit
import AppKit

// MARK: - List Windows Tool

struct ListWindowsTool: MCPTool {
    let definition = MCPToolDefinition(
        name: "list_windows",
        description: "List all visible windows available for recording",
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "app_name": .object([
                    "type": "string",
                    "description": "Filter to specific application name"
                ]),
                "include_minimized": .object([
                    "type": "boolean",
                    "default": false,
                    "description": "Include minimized windows"
                ])
            ]),
            "required": .array([])
        ])
    )

    func execute(arguments: JSONValue) async throws -> MCPToolResult {
        let appNameFilter = arguments["app_name"]?.stringValue
        let includeMinimized = arguments["include_minimized"]?.boolValue ?? false

        do {
            let content = try await SCShareableContent.current

            var windows: [JSONValue] = []

            for window in content.windows {
                // Filter by app name if specified
                if let filter = appNameFilter {
                    let appName = window.owningApplication?.applicationName ?? ""
                    if !appName.localizedCaseInsensitiveContains(filter) {
                        continue
                    }
                }

                // Skip off-screen windows unless including minimized
                if !includeMinimized && !window.isOnScreen {
                    continue
                }

                let title = window.title ?? ""

                let windowInfo: [String: JSONValue] = [
                    "id": .int(Int(window.windowID)),
                    "title": .string(title),
                    "app_name": .string(window.owningApplication?.applicationName ?? "Unknown"),
                    "bundle_id": .string(window.owningApplication?.bundleIdentifier ?? ""),
                    "frame": .object([
                        "x": .int(Int(window.frame.origin.x)),
                        "y": .int(Int(window.frame.origin.y)),
                        "width": .int(Int(window.frame.size.width)),
                        "height": .int(Int(window.frame.size.height))
                    ]),
                    "is_on_screen": .bool(window.isOnScreen),
                    "window_layer": .int(Int(window.windowLayer))
                ]

                windows.append(.object(windowInfo))
            }

            // Sort by window layer (frontmost first)
            windows.sort { w1, w2 in
                let layer1 = w1["window_layer"]?.intValue ?? 0
                let layer2 = w2["window_layer"]?.intValue ?? 0
                return layer1 < layer2
            }

            return .json(.object([
                "windows": .array(windows),
                "count": .int(windows.count)
            ]))
        } catch {
            return .error("Failed to enumerate windows: \(error.localizedDescription). Make sure screen recording permission is granted.")
        }
    }
}

// MARK: - Launch Terminal Tool (with tmux for headless input)

struct LaunchTerminalTool: MCPTool {
    let definition = MCPToolDefinition(
        name: "launch_terminal",
        description: "Launch a terminal application in a tmux session for headless recording. Returns window_id for recording and session_name for sending input.",
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "bundle_id": .object([
                    "type": "string",
                    "description": "Terminal bundle ID (e.g., 'org.alacritty', 'com.apple.Terminal')"
                ]),
                "app_name": .object([
                    "type": "string",
                    "description": "Terminal name (e.g., 'Alacritty', 'Terminal'). Used if bundle_id not provided."
                ]),
                "wait_for_window": .object([
                    "type": "boolean",
                    "default": true,
                    "description": "Wait for window to appear and return its info"
                ]),
                "timeout": .object([
                    "type": "number",
                    "default": 5.0,
                    "description": "Timeout in seconds when waiting for window"
                ])
            ]),
            "required": .array([])
        ])
    )

    func execute(arguments: JSONValue) async throws -> MCPToolResult {
        let bundleId = arguments["bundle_id"]?.stringValue
        let appName = arguments["app_name"]?.stringValue
        let waitForWindow = arguments["wait_for_window"]?.boolValue ?? true
        let timeout = arguments["timeout"]?.doubleValue ?? 5.0

        guard bundleId != nil || appName != nil else {
            return .error("Must provide either 'bundle_id' or 'app_name'")
        }

        // Generate unique tmux session name and use dedicated socket for isolation
        let sessionName = "mcp-\(UUID().uuidString.prefix(8).lowercased())"
        let socketName = "mcp"  // Dedicated socket for MCP sessions

        // Create detached tmux session with vanilla shell (no user config)
        // -L mcp: Use dedicated socket to isolate from user's tmux server
        // -f /dev/null: Empty tmux config (no user tmux.conf)
        // /bin/zsh --no-rcs: Vanilla zsh without user's .zshrc
        let tmuxCreate = Process()
        tmuxCreate.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        tmuxCreate.arguments = ["tmux", "-L", socketName, "-f", "/dev/null", "new-session", "-d", "-s", sessionName, "/bin/zsh", "--no-rcs"]

        do {
            try tmuxCreate.run()
            tmuxCreate.waitUntilExit()
            if tmuxCreate.terminationStatus != 0 {
                return .error("Failed to create tmux session")
            }
        } catch {
            return .error("Failed to create tmux session: \(error.localizedDescription)")
        }

        // Get existing windows before launch to detect new ones
        let existingWindowIds: Set<UInt32>
        if waitForWindow {
            do {
                let content = try await SCShareableContent.current
                existingWindowIds = Set(content.windows.map { $0.windowID })
            } catch {
                existingWindowIds = []
            }
        } else {
            existingWindowIds = []
        }

        // Launch terminal attached to tmux session (using same dedicated socket)
        let terminalApp = appName ?? "Alacritty"
        let launchProcess = Process()
        launchProcess.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        launchProcess.arguments = ["-na", terminalApp, "--args", "-e", "tmux", "-L", socketName, "attach-session", "-t", sessionName]

        do {
            try launchProcess.run()
            launchProcess.waitUntilExit()
            if launchProcess.terminationStatus != 0 {
                // Clean up tmux session on failure
                _ = try? runCommand("/usr/bin/env", arguments: ["tmux", "-L", "mcp", "kill-session", "-t", sessionName])
                return .error("Failed to launch \(terminalApp)")
            }
        } catch {
            _ = try? runCommand("/usr/bin/env", arguments: ["tmux", "-L", "mcp", "kill-session", "-t", sessionName])
            return .error("Failed to launch \(terminalApp): \(error.localizedDescription)")
        }

        // Wait for new window to appear
        if waitForWindow {
            let startTime = Date()
            var windowInfo: [String: JSONValue]?

            while Date().timeIntervalSince(startTime) < timeout {
                do {
                    let content = try await SCShareableContent.current

                    for window in content.windows {
                        if !existingWindowIds.contains(window.windowID) && window.isOnScreen {
                            let windowAppName = window.owningApplication?.applicationName ?? ""

                            if windowAppName.localizedCaseInsensitiveContains(terminalApp) {
                                windowInfo = [
                                    "window_id": .int(Int(window.windowID)),
                                    "title": .string(window.title ?? ""),
                                    "app_name": .string(windowAppName),
                                    "bundle_id": .string(window.owningApplication?.bundleIdentifier ?? ""),
                                    "pid": .int(Int(window.owningApplication?.processID ?? 0)),
                                    "frame": .object([
                                        "x": .int(Int(window.frame.origin.x)),
                                        "y": .int(Int(window.frame.origin.y)),
                                        "width": .int(Int(window.frame.size.width)),
                                        "height": .int(Int(window.frame.size.height))
                                    ]),
                                    "session_name": .string(sessionName)
                                ]
                                break
                            }
                        }
                    }

                    if windowInfo != nil {
                        break
                    }
                } catch {
                    // Continue waiting
                }

                try await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }

            if let info = windowInfo {
                return .json(.object([
                    "status": .string("launched"),
                    "window": .object(info)
                ]))
            } else {
                return .json(.object([
                    "status": .string("launched"),
                    "session_name": .string(sessionName),
                    "message": .string("App launched but no new window detected within timeout")
                ]))
            }
        } else {
            return .json(.object([
                "status": .string("launched"),
                "session_name": .string(sessionName),
                "message": .string("App launch initiated")
            ]))
        }
    }

    private func runCommand(_ path: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// MARK: - Send Terminal Input Tool (headless via tmux)

struct SendTerminalInputTool: MCPTool {
    let definition = MCPToolDefinition(
        name: "send_terminal_input",
        description: "Send text input to a terminal session headlessly via tmux. Does not require window focus.",
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "text": .object([
                    "type": "string",
                    "description": "The text to send. Use \\n for Enter/Return key."
                ]),
                "session_name": .object([
                    "type": "string",
                    "description": "tmux session name from launch_terminal."
                ])
            ]),
            "required": .array(["text", "session_name"])
        ])
    )

    func execute(arguments: JSONValue) async throws -> MCPToolResult {
        guard let text = arguments["text"]?.stringValue else {
            return .error("Missing required parameter: text")
        }
        guard let sessionName = arguments["session_name"]?.stringValue else {
            return .error("Missing required parameter: session_name")
        }

        // Check tmux session exists
        let checkProcess = Process()
        checkProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        checkProcess.arguments = ["tmux", "-L", "mcp", "has-session", "-t", sessionName]

        do {
            try checkProcess.run()
            checkProcess.waitUntilExit()
            if checkProcess.terminationStatus != 0 {
                return .error("tmux session '\(sessionName)' not found")
            }
        } catch {
            return .error("Failed to check tmux session: \(error.localizedDescription)")
        }

        // Handle newlines: normalize literal \\n to actual newlines
        let normalizedText = text.replacingOccurrences(of: "\\n", with: "\n")
        let parts = normalizedText.components(separatedBy: "\n")

        for (index, part) in parts.enumerated() {
            // Send the text part using tmux send-keys -l (literal mode)
            if !part.isEmpty {
                let sendKeys = Process()
                sendKeys.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                // Use -l for literal mode - sends text as-is without key name interpretation
                sendKeys.arguments = ["tmux", "-L", "mcp", "send-keys", "-l", "-t", sessionName, part]

                do {
                    try sendKeys.run()
                    sendKeys.waitUntilExit()

                    if sendKeys.terminationStatus != 0 {
                        return .error("tmux send-keys failed")
                    }
                } catch {
                    return .error("Failed to send keys: \(error.localizedDescription)")
                }
            }

            // Send Enter key after each part except the last
            if index < parts.count - 1 {
                let enterProcess = Process()
                enterProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                enterProcess.arguments = ["tmux", "-L", "mcp", "send-keys", "-t", sessionName, "Enter"]

                do {
                    try enterProcess.run()
                    enterProcess.waitUntilExit()
                } catch {
                    return .error("Failed to send Enter key: \(error.localizedDescription)")
                }
            }
        }

        return .json(.object([
            "status": .string("sent"),
            "session_name": .string(sessionName),
            "characters": .int(text.count),
            "message": .string("Text sent via tmux (headless)")
        ]))
    }
}
