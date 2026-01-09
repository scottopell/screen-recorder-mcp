import Foundation
import AppKit

// MARK: - Main Entry Point

// Check macOS version
guard #available(macOS 12.3, *) else {
    FileHandle.standardError.write(Data("Error: screen-recorder-mcp requires macOS 12.3 or later\n".utf8))
    exit(1)
}

// Initialize NSApplication to connect to window server
// This is required for ScreenCaptureKit to work properly
let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // Don't show in dock

// Register all tools (10 focused tools for terminal recording)
let tools: [any MCPTool] = [
    // Permission check
    CheckPermissionsTool(),

    // Window/terminal management
    ListWindowsTool(),
    LaunchTerminalTool(),
    SendTerminalInputTool(),
    KillTerminalTool(),

    // Recording control
    StartRecordingTool(),
    StopRecordingTool(),
    RunDemoScriptTool(),

    // Post-processing
    ExtractFrameTool(),
    RenderRecordingTool()
]

// Create server
let server = MCPServer(tools: tools)

// Run MCP transport on a background thread while NSApp runs on main
Task { @MainActor in
    let transport = MCPStdioTransport(server: server)
    await transport.run()
    NSApp.terminate(nil)
}

// Run the application event loop (required for window server connection)
app.run()
