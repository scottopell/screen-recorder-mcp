# Screen Recorder MCP Server

A focused macOS window recording solution for LLM agents via the Model Context Protocol (MCP). Record terminal sessions headlessly - no window focus required.

## Requirements

- macOS 13.0 or later
- Screen Recording permission (System Settings > Privacy & Security > Screen Recording)

## Installation

```bash
# Development
./scripts/dev.sh

# Production
./scripts/install.sh
```

## Tools (7)

| Tool | Description |
|------|-------------|
| `check_permissions` | Verify screen recording permission |
| `list_windows` | List windows (debugging) |
| `launch_app` | Launch terminal, get window_id + tty |
| `type_text` | Send text to TTY (headless) |
| `start_recording` | Record a window (works in background) |
| `stop_recording` | Stop and finalize |
| `extract_frame` | Extract frame for verification |

## Headless Recording

The key feature: record terminal sessions without requiring window focus.

1. `launch_app` returns both `window_id` and `tty` path
2. `start_recording` captures the window even when it's in the background
3. `type_text` writes directly to the TTY - no focus needed

```
1. launch_app(bundle_id: "org.alacritty")
   → {window_id: 123, tty: "/dev/ttys005"}

2. start_recording(window_id: 123)
   → recording starts (works even if window is hidden)

3. type_text(text: "echo hello\n", tty: "/dev/ttys005")
   → text appears in terminal (no focus required)

4. stop_recording()
   → .screen-recordings/recording_<timestamp>.mov

5. extract_frame(recording_path, timestamp: -1)
   → .screen-recordings/frames/frame_<id>.png
```

## Output

```
.screen-recordings/
├── recording_2026-01-09_04-12-34Z.mov
└── frames/
    └── frame_77FC955B.png
```

## License

MIT
