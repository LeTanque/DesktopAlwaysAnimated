#!/bin/zsh
set -euo pipefail

agent_path="$HOME/Library/LaunchAgents/local.letanque.desktopalwaysanimated.plist"
launchctl bootout "gui/$(id -u)" "$agent_path" 2>/dev/null || true
rm -f "$agent_path"
echo "Launch at login removed."
