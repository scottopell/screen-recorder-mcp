#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "Building screen-recorder-mcp..."
cd "$PROJECT_DIR"
swift build -c release

INSTALL_DIR="${1:-/usr/local/bin}"
BINARY="$PROJECT_DIR/.build/release/screen-recorder-mcp"

if [ ! -f "$BINARY" ]; then
    echo "Error: Build failed or binary not found"
    exit 1
fi

echo "Installing to $INSTALL_DIR..."

if [ -w "$INSTALL_DIR" ]; then
    cp "$BINARY" "$INSTALL_DIR/"
else
    echo "Installing requires sudo access..."
    sudo cp "$BINARY" "$INSTALL_DIR/"
fi

INSTALLED_PATH="$INSTALL_DIR/screen-recorder-mcp"

echo "Updating .mcp.json..."

MCP_JSON="$PROJECT_DIR/.mcp.json"

if [ -f "$MCP_JSON" ]; then
    # File exists, check if we have jq
    if command -v jq &> /dev/null; then
        # Use jq to add/update the entry
        jq --arg cmd "$INSTALLED_PATH" '.mcpServers["screen-recorder"] = {"command": $cmd}' "$MCP_JSON" > "$MCP_JSON.tmp" && mv "$MCP_JSON.tmp" "$MCP_JSON"
    else
        # No jq, use python
        python3 -c "
import json
with open('$MCP_JSON', 'r') as f:
    data = json.load(f)
if 'mcpServers' not in data:
    data['mcpServers'] = {}
data['mcpServers']['screen-recorder'] = {'command': '$INSTALLED_PATH'}
with open('$MCP_JSON', 'w') as f:
    json.dump(data, f, indent=2)
"
    fi
else
    # Create new .mcp.json
    cat > "$MCP_JSON" << EOF
{
  "mcpServers": {
    "screen-recorder": {
      "command": "$INSTALLED_PATH"
    }
  }
}
EOF
fi

echo ""
echo "Installation complete!"
echo "  Binary: $INSTALLED_PATH"
echo "  Config: $MCP_JSON"
echo ""
echo "Note: You will need to grant Screen Recording permission in System Settings > Privacy & Security"
