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
            "screen_recording": .string(state.screenRecording.rawValue)
        ]

        let granted = state.screenRecording == .granted

        if !granted {
            result["instructions"] = .string(checker.getPermissionInstructions())
        }

        result["granted"] = .bool(granted)

        return .json(.object(result))
    }
}
