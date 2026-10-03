#!/bin/sh
# Remove Agent Island: unload the LaunchAgent, then delete its plist and the app.
#
#   scripts/uninstall.sh            keep logs, the Codex seen store and session names
#   scripts/uninstall.sh --purge    also delete the island's own state files and preferences
#   scripts/uninstall.sh --dry-run  print what would run, change nothing
#
# --purge deletes only files this app writes. It never deletes the state directory
# itself, which also holds research notes and audit logs that are not the app's.
set -eu

label="com.nathan.agent-island"
purge=0
dry_run=0
for argument in "$@"; do
    case "$argument" in
        --purge) purge=1 ;;
        --dry-run) dry_run=1 ;;
        *)
            echo "usage: scripts/uninstall.sh [--purge] [--dry-run]" >&2
            exit 64
            ;;
    esac
done

run() {
    if [ "$dry_run" -eq 1 ]; then
        printf '%s\n' "$*"
    else
        "$@"
    fi
}

domain="gui/$(id -u)"
state_directory="$HOME/.local/state/agent-island"
support_directory="$HOME/Library/Application Support/AgentIsland"

if [ "$dry_run" -eq 1 ]; then
    printf '%s\n' "launchctl bootout $domain/$label"
else
    launchctl bootout "$domain/$label" 2>/dev/null || true
fi
run rm -f "$HOME/Library/LaunchAgents/$label.plist"
run rm -rf "$HOME/Applications/AgentIsland.app"

if [ "$purge" -eq 1 ]; then
    run rm -rf "$support_directory"
    for file in "$state_directory"/transitions.jsonl "$state_directory"/transitions.*.jsonl "$state_directory"/stderr.log; do
        if [ -e "$file" ] || [ "$dry_run" -eq 1 ]; then
            run rm -f "$file"
        fi
    done
    if [ "$dry_run" -eq 1 ]; then
        printf '%s\n' "defaults delete $label"
    else
        defaults delete "$label" 2>/dev/null || true
    fi
fi
