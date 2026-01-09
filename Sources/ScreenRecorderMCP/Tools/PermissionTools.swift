import Foundation

// MARK: - Check Permissions Tool

struct CheckPermissionsTool: MCPTool {
    let definition = MCPToolDefinition(
        name: "check_permissions",
        description: "Check if required macOS permissions are granted for screen recording",
        inputSchema: .object([
            "type": "object",
            "properties": .object([:]),
            "required": .array([])
        ])
    )

    func execute(arguments: JSONValue) async throws -> MCPToolResult {
        let checker = PermissionChecker.shared
        let state = await checker.checkAllPermissions()

        var result: [String: JSONValue] = [
            "screen_recording": .string(state.screenRecording.rawValue),
            "microphone": .string(state.microphone.rawValue)
        ]

        // Determine if any permissions are missing
        let allGranted = state.screenRecording == .granted

        if !allGranted {
            result["instructions"] = .string(checker.getPermissionInstructions())
        }

        result["all_required_granted"] = .bool(allGranted)

        return .json(.object(result))
    }
}

// MARK: - Request Permission Tool

struct RequestPermissionTool: MCPTool {
    let definition = MCPToolDefinition(
        name: "request_permission",
        description: "Trigger permission request dialogs for screen recording or microphone",
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "permission": .object([
                    "type": "string",
                    "enum": .array(["screen_recording", "microphone"]),
                    "description": "Which permission to request"
                ])
            ]),
            "required": .array(["permission"])
        ])
    )

    func execute(arguments: JSONValue) async throws -> MCPToolResult {
        guard let permission = arguments["permission"]?.stringValue else {
            return .error("Missing required parameter: permission")
        }

        let checker = PermissionChecker.shared

        switch permission {
        case "screen_recording":
            let granted = await checker.requestScreenRecordingPermission()
            return .json(.object([
                "permission": "screen_recording",
                "granted": .bool(granted),
                "message": .string(granted
                    ? "Screen recording permission granted"
                    : "Screen recording permission not granted. Please enable it in System Preferences > Privacy & Security > Screen Recording")
            ]))

        case "microphone":
            let granted = await checker.requestMicrophonePermission()
            return .json(.object([
                "permission": "microphone",
                "granted": .bool(granted),
                "message": .string(granted
                    ? "Microphone permission granted"
                    : "Microphone permission not granted. Please enable it in System Preferences > Privacy & Security > Microphone")
            ]))

        default:
            return .error("Invalid permission type: \(permission). Must be 'screen_recording' or 'microphone'")
        }
    }
}
