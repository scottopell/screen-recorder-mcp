# Screen Recorder MCP Server

## Build Commands

```bash
# Development build (fast iteration)
./scripts/dev.sh

# Production build and install
./scripts/install.sh

# Direct build
swift build
swift build -c release
```

## Testing

After building, restart Claude Code to pick up the new binary. Then use the MCP tools directly:
- `check_permissions` - Verify screen recording permission
- `list_windows` - See available windows
- `launch_app` - Launch a new app window for recording
- `start_recording` / `stop_recording` - Record a window

## Project Structure

```
Sources/ScreenRecorderMCP/
├── main.swift              # Entry point, tool registration
├── MCPServer.swift         # JSON-RPC server over stdio
├── Models/
│   ├── JSONRPCTypes.swift  # JSON-RPC 2.0 message types
│   ├── MCPTypes.swift      # MCP protocol types
│   ├── RecordingConfig.swift   # Recording configuration
│   └── RecordingSession.swift  # Session state management
├── Recording/
│   ├── ScreenRecorder.swift    # ScreenCaptureKit wrapper
│   └── OutputWriter.swift      # AVAssetWriter encoding
├── Tools/
│   ├── PermissionTools.swift   # Permission checking/requesting
│   ├── WindowTools.swift       # Window/app enumeration & management
│   ├── RecordingTools.swift    # Start/stop/pause recording
│   ├── QueryTools.swift        # List recordings, get info
│   └── ProcessingTools.swift   # Frame extraction
└── Utils/
    └── Permissions.swift       # Permission helper functions
```

## Key Patterns

- **Actor isolation**: `ScreenRecorder` and `SessionManager` are actors for thread safety
- **MCP tool protocol**: Each tool implements `MCPTool` with `definition` and `execute()`
- **Async/await**: All ScreenCaptureKit APIs are async
- **NSApplication required**: CLI must init NSApplication to connect to window server

## Output Locations

- Recordings: `.screen-recordings/` (in cwd)
- Extracted frames: `.screen-recordings/frames/`

## Common Issues

1. **CGS_REQUIRE_INIT crash**: NSApplication must be initialized before ScreenCaptureKit APIs
2. **Permission denied**: Grant Screen Recording permission in System Settings
3. **Window not found**: Window may have closed; use `list_windows` to verify
4. **Wrong dimensions**: Check `createStreamConfiguration()` uses actual window frame
