#!/bin/sh
# Install Agent Island for the current user.
#
#   scripts/install.sh                      build the app, copy it to ~/Applications,
#                                           install and (re)load the LaunchAgent
#   scripts/install.sh --render-plist PATH  only write the rendered LaunchAgent plist
#                                           to PATH, then exit (no build, copy or launchctl)
#
# One app, one LaunchAgent (com.nathan.agent-island). This script installs no hooks
# and never reads or writes any agent's configuration.
set -eu

label="com.nathan.agent-island"
repo_root=$(cd "$(dirname "$0")/.." && pwd)
template="$repo_root/config/$label.plist"
# The packaging tests point AGENT_ISLAND_BUILD_SCRIPT at a stub so they never rebuild the real bundle.
build_script=${AGENT_ISLAND_BUILD_SCRIPT:-"$repo_root/scripts/build-app.sh"}

usage() {
    echo "usage: scripts/install.sh [--render-plist PATH]" >&2
    exit 64
}

# launchd needs absolute paths. Let the plist serializer escape special path characters.
render_plist() {
    destination=$1
    cp "$template" "$destination"
    plutil -replace ProgramArguments -array "$destination"
    plutil -insert ProgramArguments.0 -string "$HOME/Applications/AgentIsland.app/Contents/MacOS/AgentIsland" "$destination"
    plutil -replace StandardErrorPath -string "$HOME/.local/state/agent-island/stderr.log" "$destination"
    plutil -lint -s "$destination"
}

if [ "$#" -gt 0 ]; then
    case "$1" in
        --render-plist)
            [ "$#" -eq 2 ] || usage
            render_plist "$2"
            exit 0
            ;;
        *)
            usage
            ;;
    esac
fi

app_source="$repo_root/.build/AgentIsland.app"
app_destination="$HOME/Applications/AgentIsland.app"
log_directory="$HOME/.local/state/agent-island"
agents_directory="$HOME/Library/LaunchAgents"
plist="$agents_directory/$label.plist"
domain="gui/$(id -u)"

cd "$repo_root"
/bin/sh "$build_script"

# Validate the rendered plist before stopping or replacing an existing installation.
rendered_plist=$(mktemp "$repo_root/.build/launchagent.XXXXXX")
trap 'rm -f "$rendered_plist"' EXIT
render_plist "$rendered_plist"

mkdir -p "$HOME/Applications" "$agents_directory"
# launchd will not create the StandardErrorPath directory.
mkdir -p "$log_directory"

# Stop the running copy before its bundle is replaced; ignore "not loaded".
launchctl bootout "$domain/$label" 2>/dev/null || true
waited=0
while launchctl print "$domain/$label" >/dev/null 2>&1; do
    [ "$waited" -lt 50 ] || break
    sleep 0.1
    waited=$((waited + 1))
done

rm -rf "$app_destination"
ditto "$app_source" "$app_destination"
cp "$rendered_plist" "$plist"

launchctl bootstrap "$domain" "$plist"
launchctl kickstart -k "$domain/$label"
printf 'Installed %s and loaded %s\n' "$app_destination" "$label"
