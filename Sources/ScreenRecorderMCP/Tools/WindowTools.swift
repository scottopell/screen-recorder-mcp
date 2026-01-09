import Foundation
import ScreenCaptureKit
import AppKit

// MARK: - List Displays Tool

struct ListDisplaysTool: MCPTool {
    let definition = MCPToolDefinition(
        name: "list_displays",
        description: "List all available displays/monitors for recording",
        inputSchema: .object([
            "type": "object",
            "properties": .object([:]),
            "required": .array([])
        ])
    )

    func execute(arguments: JSONValue) async throws -> MCPToolResult {
        do {
            let content = try await SCShareableContent.current

            let displays: [JSONValue] = content.displays.map { display in
                .object([
                    "id": .int(Int(display.displayID)),
                    "width": .int(display.width),
                    "height": .int(display.height),
                    "frame": .object([
                        "x": .int(Int(display.frame.origin.x)),
                        "y": .int(Int(display.frame.origin.y)),
                        "width": .int(Int(display.frame.size.width)),
                        "height": .int(Int(display.frame.size.height))
                    ])
                ])
            }

            return .json(.object([
                "displays": .array(displays),
                "count": .int(displays.count)
            ]))
        } catch {
            return .error("Failed to enumerate displays: \(error.localizedDescription). Make sure screen recording permission is granted.")
        }
    }
}

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

                // Skip windows without titles (usually utility windows)
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

// MARK: - List Apps Tool

struct ListAppsTool: MCPTool {
    let definition = MCPToolDefinition(
        name: "list_apps",
        description: "List running applications that can be recorded",
        inputSchema: .object([
            "type": "object",
            "properties": .object([:]),
            "required": .array([])
        ])
    )

    func execute(arguments: JSONValue) async throws -> MCPToolResult {
        do {
            let content = try await SCShareableContent.current

            // Group windows by application
            var appWindows: [String: Int] = [:]
            for window in content.windows where window.isOnScreen {
                let bundleId = window.owningApplication?.bundleIdentifier ?? "unknown"
                appWindows[bundleId, default: 0] += 1
            }

            let apps: [JSONValue] = content.applications.compactMap { app in
                let windowCount = appWindows[app.bundleIdentifier] ?? 0

                // Only include apps with visible windows
                guard windowCount > 0 else { return nil }

                return .object([
                    "name": .string(app.applicationName),
                    "bundle_id": .string(app.bundleIdentifier),
                    "pid": .int(Int(app.processID)),
                    "window_count": .int(windowCount)
                ])
            }

            return .json(.object([
                "apps": .array(apps),
                "count": .int(apps.count)
            ]))
        } catch {
            return .error("Failed to enumerate applications: \(error.localizedDescription). Make sure screen recording permission is granted.")
        }
    }
}

// MARK: - Launch App Tool

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

        // Launch the app
        let workspace = NSWorkspace.shared
        var launchedApp: NSRunningApplication?

        if let bundleId = bundleId {
            // Launch by bundle ID
            if let appURL = workspace.urlForApplication(withBundleIdentifier: bundleId) {
                let config = NSWorkspace.OpenConfiguration()
                config.createsNewApplicationInstance = newInstance
                config.activates = true

                do {
                    launchedApp = try await workspace.openApplication(at: appURL, configuration: config)
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
            var newWindow: JSONValue?

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
                                newWindow = .object([
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
                                ])
                                break
                            }
                        }
                    }

                    if newWindow != nil {
                        break
                    }
                } catch {
                    // Continue waiting
                }

                try await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }

            if let window = newWindow {
                return .json(.object([
                    "status": .string("launched"),
                    "window": window
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
}

// MARK: - Focus Window Tool

struct FocusWindowTool: MCPTool {
    let definition = MCPToolDefinition(
        name: "focus_window",
        description: "Bring a window to the front and activate its application",
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "window_id": .object([
                    "type": "integer",
                    "description": "Window ID to focus (from list_windows or launch_app)"
                ]),
                "bundle_id": .object([
                    "type": "string",
                    "description": "Bundle ID of app to activate (focuses most recent window)"
                ])
            ]),
            "required": .array([])
        ])
    )

    func execute(arguments: JSONValue) async throws -> MCPToolResult {
        let windowId = arguments["window_id"]?.intValue
        let bundleId = arguments["bundle_id"]?.stringValue

        guard windowId != nil || bundleId != nil else {
            return .error("Must provide either 'window_id' or 'bundle_id'")
        }

        if let bundleId = bundleId {
            // Activate app by bundle ID
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            if let app = apps.first {
                app.activate(options: [.activateIgnoringOtherApps])
                return .json(.object([
                    "status": .string("focused"),
                    "app_name": .string(app.localizedName ?? ""),
                    "bundle_id": .string(bundleId)
                ]))
            } else {
                return .error("No running application found with bundle ID '\(bundleId)'")
            }
        }

        if let windowId = windowId {
            // Find the window and activate its app
            do {
                let content = try await SCShareableContent.current
                if let window = content.windows.first(where: { $0.windowID == UInt32(windowId) }),
                   let bundleId = window.owningApplication?.bundleIdentifier {
                    let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
                    if let app = apps.first {
                        app.activate(options: [.activateIgnoringOtherApps])
                        return .json(.object([
                            "status": .string("focused"),
                            "window_id": .int(windowId),
                            "app_name": .string(window.owningApplication?.applicationName ?? ""),
                            "bundle_id": .string(bundleId)
                        ]))
                    }
                }
                return .error("Window not found or cannot be focused")
            } catch {
                return .error("Failed to find window: \(error.localizedDescription)")
            }
        }

        return .error("No valid target specified")
    }
}

// MARK: - Await Window Tool

struct AwaitWindowTool: MCPTool {
    let definition = MCPToolDefinition(
        name: "await_window",
        description: "Wait for a window matching criteria to appear. Useful after launching an app.",
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "bundle_id": .object([
                    "type": "string",
                    "description": "Wait for window from app with this bundle ID"
                ]),
                "app_name": .object([
                    "type": "string",
                    "description": "Wait for window from app with this name"
                ]),
                "title_contains": .object([
                    "type": "string",
                    "description": "Wait for window with title containing this string"
                ]),
                "timeout": .object([
                    "type": "number",
                    "default": 10.0,
                    "description": "Timeout in seconds"
                ])
            ]),
            "required": .array([])
        ])
    )

    func execute(arguments: JSONValue) async throws -> MCPToolResult {
        let bundleId = arguments["bundle_id"]?.stringValue
        let appName = arguments["app_name"]?.stringValue
        let titleContains = arguments["title_contains"]?.stringValue
        let timeout = arguments["timeout"]?.doubleValue ?? 10.0

        guard bundleId != nil || appName != nil || titleContains != nil else {
            return .error("Must provide at least one of: 'bundle_id', 'app_name', 'title_contains'")
        }

        let startTime = Date()

        while Date().timeIntervalSince(startTime) < timeout {
            do {
                let content = try await SCShareableContent.current

                for window in content.windows where window.isOnScreen {
                    var matches = true

                    if let targetBundleId = bundleId {
                        matches = matches && (window.owningApplication?.bundleIdentifier == targetBundleId)
                    }

                    if let targetAppName = appName {
                        let windowAppName = window.owningApplication?.applicationName ?? ""
                        matches = matches && windowAppName.localizedCaseInsensitiveContains(targetAppName)
                    }

                    if let targetTitle = titleContains {
                        let windowTitle = window.title ?? ""
                        matches = matches && windowTitle.localizedCaseInsensitiveContains(targetTitle)
                    }

                    if matches {
                        return .json(.object([
                            "status": .string("found"),
                            "window": .object([
                                "window_id": .int(Int(window.windowID)),
                                "title": .string(window.title ?? ""),
                                "app_name": .string(window.owningApplication?.applicationName ?? ""),
                                "bundle_id": .string(window.owningApplication?.bundleIdentifier ?? ""),
                                "frame": .object([
                                    "x": .int(Int(window.frame.origin.x)),
                                    "y": .int(Int(window.frame.origin.y)),
                                    "width": .int(Int(window.frame.size.width)),
                                    "height": .int(Int(window.frame.size.height))
                                ])
                            ])
                        ]))
                    }
                }
            } catch {
                // Continue waiting
            }

            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }

        return .json(.object([
            "status": .string("timeout"),
            "message": .string("No matching window found within \(timeout) seconds")
        ]))
    }
}
