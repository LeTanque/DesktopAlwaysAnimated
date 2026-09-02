#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
binary_path="$project_dir/build/NativeAerialLooper.app/Contents/MacOS/NativeAerialLooper"
agent_dir="$HOME/Library/LaunchAgents"
agent_path="$agent_dir/local.letanque.desktopalwaysanimated.plist"
label="local.letanque.desktopalwaysanimated"
user_id="$(id -u)"

if [[ ! -x "$binary_path" ]]; then
  echo "Build the app first with ./build.sh" >&2
  exit 1
fi

mkdir -p "$agent_dir"
launchctl bootout "gui/$user_id" "$agent_path" 2>/dev/null || true
rm -f "$agent_path"

plutil -create xml1 "$agent_path"
plutil -insert Label -string "$label" "$agent_path"
plutil -insert ProgramArguments -json "[\"$binary_path\"]" "$agent_path"
plutil -insert RunAtLoad -bool true "$agent_path"
plutil -insert KeepAlive -bool false "$agent_path"
plutil -insert ProcessType -string Interactive "$agent_path"
plutil -lint "$agent_path"
launchctl bootstrap "gui/$user_id" "$agent_path"

echo "Launch at login installed: $label"
