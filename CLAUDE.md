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
# Manual recording flow
1. check_permissions          → verify screen recording permission
2. launch_terminal(bundle_id: "org.alacritty")  → get window_id + session_name
3. start_recording(window_id: <id>)
4. send_terminal_input(text: "echo hello\n", session_name: "mcp-xxxxxxxx")
5. stop_recording()
6. extract_frame(recording_path, timestamp: -1)  → verify frame
7. render_recording(recording_path, output_format: "mp4")  → convert to video

# Scripted demo flow (eliminates LLM API latency)
1. launch_terminal(bundle_id: "org.alacritty")  → get window_id + session_name
2. run_demo_script(window_id, session_name, commands: [...])  → records with precise timing
3. render_recording(recording_path, output_format: "mp4")  → convert to video

# Example run_demo_script commands array:
# [
#   { "text": "ls -la" },           ← Enter auto-appended
#   { "delay_ms": 500 },            ← wait 500ms
#   { "text": "echo 'Hello'" },
#   { "delay_ms": 1500 },           ← longer delay for viewer
#   { "text": "date" },
#   { "delay_ms": 1000 }
# ]
# NOTE: Must include at least one delay_ms command or request is rejected
```

## Project Structure

```
Sources/ScreenRecorderMCP/
├── main.swift              # Entry point, registers 10 tools
├── MCPServer.swift         # JSON-RPC server over stdio
├── Models/
│   ├── JSONRPCTypes.swift  # JSON-RPC 2.0 message types
│   ├── MCPTypes.swift      # MCP protocol types
│   ├── RecordingConfig.swift   # Window recording config
│   ├── RecordingSession.swift  # Session state management
│   └── TerminalSessionStore.swift  # Terminal session → window_id mapping
├── Recording/
│   ├── ScreenRecorder.swift    # ScreenCaptureKit wrapper (window-only)
│   └── SparseFrameWriter.swift # PNG frame + JSON manifest writer
├── Tools/
│   ├── PermissionTools.swift   # check_permissions
│   ├── WindowTools.swift       # list_windows, launch_terminal, send_terminal_input, kill_terminal
│   ├── RecordingTools.swift    # start_recording, stop_recording
│   ├── DemoTools.swift         # run_demo_script (scripted demos with precise timing)
│   ├── ProcessingTools.swift   # extract_frame
│   └── RenderingTools.swift    # render_recording (sparse → video)
└── Utils/
    └── Permissions.swift       # Permission helper functions
```

## Key Patterns

- **Window-only recording**: Simplified to only record specific windows (no screen/region/app modes)
- **Sparse frame format**: Records PNG frames + JSON manifest (lossless, only when content changes)
- **tmux-based input**: Uses `tmux send-keys` for headless terminal input (no window focus required)
- **Vanilla shell environment**: Creates tmux sessions with `tmux -f /dev/null` and `/bin/zsh --no-rcs -o nobanghist` for consistent, predictable behavior
- **Actor isolation**: `ScreenRecorder`, `SparseFrameWriter`, and `SessionManager` are actors for thread safety
- **MCP tool protocol**: Each tool implements `MCPTool` with `definition` and `execute()`
- **NSApplication required**: CLI must init NSApplication to connect to window server

## Output Format (Sparse Frames)

Recordings produce a directory with PNG frames and JSON manifest:
```
.screen-recordings/recording_2026-01-09_15-19-42Z/
├── manifest.json        # Frame timing + metadata
└── frames/
    ├── frame_0000.png
    ├── frame_0001.png
    └── ...
```

Use `render_recording` to convert to mp4/webm/gif (requires ffmpeg).

## Output Locations

- Recordings: `.screen-recordings/<recording_name>/`

## 10 Tools

1. `check_permissions` - Pre-flight permission check
2. `list_windows` - Debug/fallback window enumeration
3. `launch_terminal` - Launch terminal in tmux session, return window_id + session_name
4. `send_terminal_input` - Send text via tmux send-keys (headless, no focus needed)
5. `kill_terminal` - Kill a terminal session by terminating its tmux session
6. `start_recording` - Record a window by ID (outputs sparse PNG frames)
7. `stop_recording` - Finalize recording, write manifest.json
8. `run_demo_script` - Execute scripted demos with precise timing (eliminates API latency)
9. `extract_frame` - Get frame at timestamp (returns PNG path directly)
10. `render_recording` - Convert sparse recording to mp4/webm/gif via ffmpeg

## Common Issues

1. **Permission denied**: Grant Screen Recording permission in System Settings
2. **Window not found**: Window may have closed; use `list_windows` to verify
3. **tmux session not found**: Terminal may have closed; launch a new one with `launch_terminal`
4. **tmux not installed**: Install with `brew install tmux`
5. **ffmpeg not found**: render_recording requires ffmpeg; install with `brew install ffmpeg`
