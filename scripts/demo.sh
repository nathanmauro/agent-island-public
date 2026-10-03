#!/bin/sh
# Synthetic demo for README screenshots: build the app bundle, then hold it on screen with island-e2e's demo
# scenario (fake Herdr panes, one Codex Desktop thread, one Claude registry session; every name is invented).
# The app reads only temp directories and a fake Herdr socket, runs muted with dry-run jumps, and is stopped
# when the hold ends. About 12 s after launch the infra pane blocks and its card peeks for 8 s.
#
# usage: scripts/demo.sh [SECONDS] [--display-mode primary|allDisplays]
#   SECONDS defaults to 60. Capture frames from another shell while it holds.
set -eu
cd "$(dirname "$0")/.."
seconds="${1:-60}"
if [ "$#" -gt 0 ]; then shift; fi
./scripts/build-app.sh
exec swift run island-e2e --app .build/AgentIsland.app --demo "$seconds" "$@"
