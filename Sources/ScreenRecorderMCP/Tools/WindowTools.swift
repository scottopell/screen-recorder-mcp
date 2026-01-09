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

// MARK: - Launch Terminal Tool

struct LaunchAppTool: MCPTool {
    let definition = MCPToolDefinition(
        name: "launch_app",
        description: "Launch an application and return its window info once ready. Useful for launching a terminal to record.",
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "bundle_id": .object([
                    "type": "string",
                    "description": "Application bundle ID (e.g., 'org.alacritty', 'com.apple.Terminal')"
                ]),
                "app_name": .object([
                    "type": "string",
                    "description": "Application name (e.g., 'Alacritty', 'Terminal'). Used if bundle_id not provided."
                ]),
                "new_instance": .object([
                    "type": "boolean",
                    "default": true,
                    "description": "Launch a new instance/window even if app is already running"
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
        let newInstance = arguments["new_instance"]?.boolValue ?? true
        let waitForWindow = arguments["wait_for_window"]?.boolValue ?? true
        let timeout = arguments["timeout"]?.doubleValue ?? 5.0

        guard bundleId != nil || appName != nil else {
            return .error("Must provide either 'bundle_id' or 'app_name'")
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

        // Get existing TTYs before launch
        let existingTTYs = getTTYList()

        // Launch the app
        let workspace = NSWorkspace.shared
        var launchedPID: pid_t?

        if let bundleId = bundleId {
            // Launch by bundle ID
            if let appURL = workspace.urlForApplication(withBundleIdentifier: bundleId) {
                let config = NSWorkspace.OpenConfiguration()
                config.createsNewApplicationInstance = newInstance
                config.activates = true

                do {
                    let app = try await workspace.openApplication(at: appURL, configuration: config)
                    launchedPID = app.processIdentifier
                } catch {
                    return .error("Failed to launch app with bundle ID '\(bundleId)': \(error.localizedDescription)")
                }
            } else {
                return .error("No application found with bundle ID '\(bundleId)'")
            }
        } else if let appName = appName {
            // Launch by name using open command
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = newInstance ? ["-na", appName] : ["-a", appName]

            do {
                try process.run()
                process.waitUntilExit()

                if process.terminationStatus != 0 {
                    return .error("Failed to launch app '\(appName)'")
                }
            } catch {
                return .error("Failed to launch app '\(appName)': \(error.localizedDescription)")
            }
        }

        // Wait for new window to appear
        if waitForWindow {
            let startTime = Date()
            var newWindowPID: pid_t?
            var windowInfo: [String: JSONValue]?

            while Date().timeIntervalSince(startTime) < timeout {
                do {
                    let content = try await SCShareableContent.current

                    // Find new windows that weren't there before
                    for window in content.windows {
                        if !existingWindowIds.contains(window.windowID) && window.isOnScreen {
                            // Check if it matches our launched app
                            let windowBundleId = window.owningApplication?.bundleIdentifier ?? ""
                            let windowAppName = window.owningApplication?.applicationName ?? ""

                            let matches: Bool
                            if let targetBundleId = bundleId {
                                matches = windowBundleId == targetBundleId
                            } else if let targetAppName = appName {
                                matches = windowAppName.localizedCaseInsensitiveContains(targetAppName)
                            } else {
                                matches = false
                            }

                            if matches {
                                newWindowPID = window.owningApplication?.processID
                                windowInfo = [
                                    "window_id": .int(Int(window.windowID)),
                                    "title": .string(window.title ?? ""),
                                    "app_name": .string(windowAppName),
                                    "bundle_id": .string(windowBundleId),
                                    "pid": .int(Int(window.owningApplication?.processID ?? 0)),
                                    "frame": .object([
                                        "x": .int(Int(window.frame.origin.x)),
                                        "y": .int(Int(window.frame.origin.y)),
                                        "width": .int(Int(window.frame.size.width)),
                                        "height": .int(Int(window.frame.size.height))
                                    ])
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

            if var info = windowInfo, let pid = newWindowPID ?? launchedPID {
                // Try to find the TTY for this terminal
                // Wait a moment for the shell to spawn
                try await Task.sleep(nanoseconds: 500_000_000) // 500ms

                if let tty = findTTYForTerminal(pid: pid, existingTTYs: existingTTYs) {
                    info["tty"] = .string(tty)
                }

                return .json(.object([
                    "status": .string("launched"),
                    "window": .object(info)
                ]))
            } else {
                return .json(.object([
                    "status": .string("launched"),
                    "message": .string("App launched but no new window detected within timeout"),
                    "window": .null
                ]))
            }
        } else {
            return .json(.object([
                "status": .string("launched"),
                "message": .string("App launch initiated")
            ]))
        }
    }

    // Get list of current TTYs
    private func getTTYList() -> Set<String> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ls")
        process.arguments = ["/dev"]

        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                let ttys = output.components(separatedBy: .newlines)
                    .filter { $0.hasPrefix("ttys") }
                    .map { "/dev/\($0)" }
                return Set(ttys)
            }
        } catch {
            // Ignore errors
        }
        return []
    }

    // Find TTY for a terminal process
    private func findTTYForTerminal(pid: pid_t, existingTTYs: Set<String>) -> String? {
        // Method 1: Look for new TTYs that appeared after launch
        let currentTTYs = getTTYList()
        let newTTYs = currentTTYs.subtracting(existingTTYs)
        if let newTTY = newTTYs.first {
            return newTTY
        }

        // Method 2: Find child shell process and get its TTY
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "pid,ppid,tty,comm", "-ax"]

        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                // Find shell processes that are children of the terminal
                for line in output.components(separatedBy: .newlines) {
                    let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                    if parts.count >= 4 {
                        let ppid = Int(parts[1]) ?? 0
                        let tty = String(parts[2])
                        let comm = String(parts[3])

                        // Check if this is a shell process with our terminal as parent
                        if ppid == Int(pid) && (comm.contains("sh") || comm.contains("zsh") || comm.contains("bash") || comm.contains("fish")) {
                            if tty != "??" && !tty.isEmpty {
                                return "/dev/\(tty)"
                            }
                        }
                    }
                }
            }
        } catch {
            // Ignore errors
        }

        return nil
    }
}

// MARK: - Type Text Tool

struct TypeTextTool: MCPTool {
    let definition = MCPToolDefinition(
        name: "type_text",
        description: "Type text into the currently focused application using simulated keystrokes. Useful for sending commands to a terminal.",
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "text": .object([
                    "type": "string",
                    "description": "The text to type. Use \\n for Enter/Return key."
                ]),
                "tty": .object([
                    "type": "string",
                    "description": "TTY device path (e.g., /dev/ttys005). Required - get this from launch_app."
                ]),
                "app_name": .object([
                    "type": "string",
                    "description": "Application name (e.g., 'Alacritty'). Required - get this from launch_app."
                ])
            ]),
            "required": .array(["text", "tty", "app_name"])
        ])
    )

    func execute(arguments: JSONValue) async throws -> MCPToolResult {
        guard let text = arguments["text"]?.stringValue else {
            return .error("Missing required parameter: text")
        }
        guard let ttyPath = arguments["tty"]?.stringValue else {
            return .error("Missing required parameter: tty")
        }
        guard let appName = arguments["app_name"]?.stringValue else {
            return .error("Missing required parameter: app_name")
        }

        // Check TTY exists
        guard FileManager.default.fileExists(atPath: ttyPath) else {
            return .error("TTY not found: \(ttyPath)")
        }

        // Convert literal \n to actual newlines for processing
        let processedText = text.replacingOccurrences(of: "\\n", with: "\n")

        // Build AppleScript to send keystrokes
        // Split by newlines and send each part with Return between
        let lines = processedText.components(separatedBy: "\n")
        var keystrokeCommands: [String] = []

        for (index, line) in lines.enumerated() {
            if !line.isEmpty {
                // Escape special characters for AppleScript
                let escaped = line.replacingOccurrences(of: "\\", with: "\\\\")
                                  .replacingOccurrences(of: "\"", with: "\\\"")
                keystrokeCommands.append("keystroke \"\(escaped)\"")
            }
            // Add Return key after each line except the last empty one
            if index < lines.count - 1 {
                keystrokeCommands.append("keystroke return")
            }
        }

        let script = """
        tell application "\(appName)" to activate
        delay 0.1
        tell application "System Events"
            tell process "\(appName)"
                \(keystrokeCommands.joined(separator: "\n                "))
            end tell
        end tell
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let pipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return .error("Failed to run AppleScript: \(error.localizedDescription)")
        }

        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorStr = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            return .error("AppleScript failed: \(errorStr)")
        }

        return .json(.object([
            "status": .string("sent"),
            "tty": .string(ttyPath),
            "characters": .int(text.count),
            "message": .string("Text sent via keystrokes (window was briefly focused)")
        ]))
    }

}
