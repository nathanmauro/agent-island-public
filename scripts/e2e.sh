#!/bin/sh
# Scripted end-to-end run (agent-island spec 12.3): build the app bundle, then drive it with island-e2e
# against a fake Herdr server and temporary registry, rollout and state directories.
#
# usage: scripts/e2e.sh [--soak-seconds N] [--steps 1,2,...]
#   Arguments pass through to island-e2e. A later --soak-seconds overrides the 600 s default
#   (the spec's 10-minute fd window). CI runs scripts/e2e.sh --soak-seconds 30.
# Step 4 moves the real pointer (only when the terminal has Accessibility); do not touch the mouse meanwhile.
set -eu
cd "$(dirname "$0")/.."
./scripts/build-app.sh
exec swift run island-e2e --app .build/AgentIsland.app --soak-seconds 600 "$@"
