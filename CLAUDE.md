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

After building, restart Claude Code to pick up the new binary. Then use the MCP tools:

```
1. check_permissions          → verify screen recording permission
2. launch_app(bundle_id: "org.alacritty")  → get window_id + tty
3. start_recording(window_id: <id>)
4. type_text(text: "echo hello\n", tty: "/dev/ttys00X")
5. stop_recording()
6. extract_frame(recording_path, timestamp: -1)  → verify
```

## Project Structure

```
Sources/ScreenRecorderMCP/
├── main.swift              # Entry point, registers 7 tools
├── MCPServer.swift         # JSON-RPC server over stdio
├── Models/
│   ├── JSONRPCTypes.swift  # JSON-RPC 2.0 message types
│   ├── MCPTypes.swift      # MCP protocol types
│   ├── RecordingConfig.swift   # Window recording config
│   └── RecordingSession.swift  # Session state management
├── Recording/
│   ├── ScreenRecorder.swift    # ScreenCaptureKit wrapper (window-only)
│   └── OutputWriter.swift      # AVAssetWriter encoding
├── Tools/
│   ├── PermissionTools.swift   # check_permissions
│   ├── WindowTools.swift       # list_windows, launch_app, type_text
│   ├── RecordingTools.swift    # start_recording, stop_recording
│   └── ProcessingTools.swift   # extract_frame
└── Utils/
    └── Permissions.swift       # Permission helper functions
```

## Key Patterns

- **Window-only recording**: Simplified to only record specific windows (no screen/region/app modes)
- **Actor isolation**: `ScreenRecorder` and `SessionManager` are actors for thread safety
- **MCP tool protocol**: Each tool implements `MCPTool` with `definition` and `execute()`
- **NSApplication required**: CLI must init NSApplication to connect to window server

## Output Locations

- Recordings: `.screen-recordings/`
- Extracted frames: `.screen-recordings/frames/`

## 7 Tools

1. `check_permissions` - Pre-flight permission check
2. `list_windows` - Debug/fallback window enumeration
3. `launch_app` - Launch terminal, return window_id + tty
4. `type_text` - Send text directly to TTY (headless, no focus needed)
5. `start_recording` - Record a window by ID (works in background)
6. `stop_recording` - Finalize recording
7. `extract_frame` - Extract frame for verification

## Common Issues

1. **Permission denied**: Grant Screen Recording permission in System Settings
2. **Window not found**: Window may have closed; use `list_windows` to verify
3. **TTY not found**: Terminal may have closed; launch a new one
