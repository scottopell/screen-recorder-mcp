#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

echo "Building screen-recorder-mcp (debug)..."
swift build

BINARY="$PROJECT_DIR/.build/debug/screen-recorder-mcp"

echo "Updating .mcp.json to use debug binary..."

MCP_JSON="$PROJECT_DIR/.mcp.json"

if [ -f "$MCP_JSON" ]; then
    if command -v jq &> /dev/null; then
        jq --arg cmd "$BINARY" '.mcpServers["screen-recorder"] = {"command": $cmd}' "$MCP_JSON" > "$MCP_JSON.tmp" && mv "$MCP_JSON.tmp" "$MCP_JSON"
    else
        python3 -c "
import json
with open('$MCP_JSON', 'r') as f:
    data = json.load(f)
if 'mcpServers' not in data:
    data['mcpServers'] = {}
data['mcpServers']['screen-recorder'] = {'command': '$BINARY'}
with open('$MCP_JSON', 'w') as f:
    json.dump(data, f, indent=2)
"
    fi
else
    cat > "$MCP_JSON" << EOF
{
  "mcpServers": {
    "screen-recorder": {
      "command": "$BINARY"
    }
  }
}
EOF
fi

echo ""
echo "Build complete!"
echo "  Binary: $BINARY"
echo "  Config: $MCP_JSON"
