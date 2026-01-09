# Screen Recorder MCP Server

A macOS screen recording solution for LLM agents via the Model Context Protocol (MCP). Enables Claude and other AI agents to record screen activity, verify actions visually, and process recordings.

## Requirements

- macOS 13.0 or later
- Screen Recording permission (System Settings > Privacy & Security > Screen Recording)

## Installation

### Development

```bash
./scripts/dev.sh
```

This builds the debug binary and updates `.mcp.json` to point to it.

### Production

```bash
./scripts/install.sh
```

This builds a release binary, installs to `/usr/local/bin/`, and updates `.mcp.json`.

## Available Tools

### Permission Management
- **check_permissions** - Check if required macOS permissions are granted
- **request_permission** - Trigger permission request dialogs

### Display/Window Enumeration
- **list_displays** - List all available displays/monitors
- **list_windows** - List all visible windows available for recording
- **list_apps** - List running applications that can be recorded

### App/Window Management
- **launch_app** - Launch an application and return its window info
- **focus_window** - Bring a window to the front
- **await_window** - Wait for a window matching criteria to appear

### Recording Control
- **start_recording** - Start recording screen, window, or application
- **stop_recording** - Stop recording and finalize output file
- **pause_recording** - Pause an active recording
- **resume_recording** - Resume a paused recording
- **cancel_recording** - Cancel recording and delete partial output
- **get_recording_status** - Get status of active recording session(s)

### Query Tools
- **list_recordings** - List completed recordings in output directory
- **get_recording_info** - Get detailed metadata about a recording

### Frame Extraction
- **extract_frame** - Extract a single frame from a recording
- **extract_frames** - Extract multiple frames at regular intervals

## Usage Example: Record a Terminal Window

```
1. launch_app(bundle_id: "org.alacritty") → get window_id
2. start_recording(mode: "window", window_id: <id>, max_duration: 30)
3. [Perform actions in the terminal]
4. stop_recording()
5. extract_frame(recording_path, timestamp: -1) → verify final state
```

## Output Location

Recordings and frames are saved to `.screen-recordings/` in the current working directory:

```
.screen-recordings/
├── recording_2026-01-09_03-51-32Z.mov
└── frames/
    └── frame_ABC123.png
```

## Recording Modes

| Mode | Description |
|------|-------------|
| `screen` | Record entire display |
| `window` | Record specific window (requires `window_id`) |
| `app` | Record all windows of an app (requires `app_bundle_id`) |

## Permissions

Grant Screen Recording permission in:
**System Settings > Privacy & Security > Screen Recording**

## Architecture

Built with Swift using:
- **ScreenCaptureKit** - Modern macOS screen capture API
- **AVFoundation** - Video encoding and processing
- **MCP Protocol** - JSON-RPC over stdio

## License

MIT
