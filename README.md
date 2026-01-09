# Screen Recorder MCP Server

A macOS window recording solution for LLM agents via the Model Context Protocol (MCP). Record terminal sessions headlessly - no window focus required.

## Demo: Claude Code Using Screen Recorder

This demo shows Claude Code using the screen-recorder MCP tools to create a recording. The "controller" session asks Claude to record a simple demo, and the "output" is what Claude produced.

### Controller (Claude receives the task)

https://github.com/user-attachments/assets/placeholder-upload-demo-controller-mp4

<details>
<summary>Can't see the video? Click to download</summary>

[Download demo-controller.mp4](assets/demo-controller.mp4) (323 KB)
</details>

### Output (Recording created by Claude)

https://github.com/user-attachments/assets/placeholder-upload-demo-output-mp4

<details>
<summary>Can't see the video? Click to download</summary>

[Download demo-output.mp4](assets/demo-output.mp4) (18 KB)
</details>

*Claude used `launch_terminal`, `run_demo_script`, and `render_recording` to produce this output autonomously.*

## Requirements

- macOS 13.0 or later
- Screen Recording permission (System Settings > Privacy & Security > Screen Recording)
- tmux (`brew install tmux`)
- ffmpeg (`brew install ffmpeg`) - for rendering videos

## Installation

```bash
# Development
./scripts/dev.sh

# Production
./scripts/install.sh
```

## Tools (10)

| Tool | Description |
|------|-------------|
| `check_permissions` | Verify screen recording permission |
| `list_windows` | List available windows (debugging) |
| `launch_terminal` | Launch terminal in tmux session, returns window_id + session_name |
| `send_terminal_input` | Send text to terminal via tmux (headless, no focus needed) |
| `kill_terminal` | Kill a terminal session |
| `start_recording` | Start recording a window (sparse PNG frames) |
| `stop_recording` | Stop and finalize recording |
| `run_demo_script` | Execute scripted demo with precise timing (eliminates API latency) |
| `extract_frame` | Extract frame at timestamp for verification |
| `render_recording` | Convert sparse recording to mp4/webm/gif |

## Key Features

### Headless Recording
Record terminal sessions without requiring window focus. The terminal runs in a tmux session, allowing input via `send_terminal_input` while recording captures the window in the background.

### Sparse Frame Format
Recordings are stored as PNG frames + JSON manifest, capturing only when content changes. This is lossless and efficient. Use `render_recording` to convert to video.

### Scripted Demos with Precise Timing
The `run_demo_script` tool executes commands with exact timing, eliminating LLM API latency from recordings. A 6-command demo takes ~7 seconds instead of 55+ seconds.

## Usage

### Manual Recording Flow

```
1. launch_terminal(bundle_id: "org.alacritty")
   → { window_id: 123, session_name: "mcp-abc123" }

2. start_recording(window_id: 123)

3. send_terminal_input(text: "echo hello", session_name: "mcp-abc123")
   → text appears in terminal (no focus required)

4. stop_recording()
   → .screen-recordings/recording_<timestamp>/

5. render_recording(recording_path, output_format: "mp4")
   → .screen-recordings/recording_<timestamp>/recording.mp4
```

### Scripted Demo Flow (Recommended)

```
1. launch_terminal(bundle_id: "org.alacritty")
   → { window_id: 123, session_name: "mcp-abc123" }

2. run_demo_script(
     session_name: "mcp-abc123",
     commands: [
       { "text": "echo 'Step 1'" },
       { "delay_ms": 1000 },
       { "text": "echo 'Step 2'" },
       { "delay_ms": 1000 },
       { "text": "echo 'Done!'" },
       { "delay_ms": 500 }
     ]
   )
   → { recording_path: "...", duration: 3.5 }

3. render_recording(recording_path, output_format: "gif")
```

## Output Format

```
.screen-recordings/
└── recording_2026-01-09_15-19-42Z/
    ├── manifest.json        # Frame timing + metadata + demo_script
    └── frames/
        ├── frame_0000.png
        ├── frame_0001.png
        └── ...
```

## License

MIT
