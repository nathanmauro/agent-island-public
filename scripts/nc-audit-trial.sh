#!/bin/sh
# Trial-period Notification Center audit loop (agent-island spec 12.4 and 12.5 #12).
# Runs nc-agent-audit.py every INTERVAL seconds with --log, so records dismissed before the next run
# are still counted (the log unions them by uuid). Run it in a spare terminal pane and stop it with
# Ctrl-C. It installs nothing: criterion 8 allows one app and one LaunchAgent.
#
# usage: scripts/nc-audit-trial.sh --since 'YYYY-MM-DD HH:MM' [--interval SECONDS] [--log FILE] [--once]
#   --interval defaults to 600; --log defaults to ~/.local/state/agent-island/nc-audit.jsonl;
#   --once runs a single audit and exits with the audit's exit status.
# During the trial any agent record (from any agent app) is a finding: the loop prints it loudly.
set -eu

repo=$(cd "$(dirname "$0")/.." && pwd)
since=
interval=600
log="$HOME/.local/state/agent-island/nc-audit.jsonl"
once=0

usage() {
    echo "usage: scripts/nc-audit-trial.sh --since 'YYYY-MM-DD HH:MM' [--interval SECONDS] [--log FILE] [--once]" >&2
    exit 64
}

while [ $# -gt 0 ]; do
    case "$1" in
        --since) [ $# -ge 2 ] || usage; since=$2; shift 2 ;;
        --interval) [ $# -ge 2 ] || usage; interval=$2; shift 2 ;;
        --log) [ $# -ge 2 ] || usage; log=$2; shift 2 ;;
        --once) once=1; shift ;;
        *) usage ;;
    esac
done
[ -n "$since" ] || usage
case "$interval" in ''|*[!0-9]*) usage ;; esac

mkdir -p "$(dirname "$log")"
while :; do
    stamp=$(date '+%Y-%m-%d %H:%M:%S')
    status=0
    output=$(python3 "$repo/scripts/nc-agent-audit.py" --since "$since" --log "$log" 2>&1) || status=$?
    case "$status" in
        0) echo "$stamp clean ($(printf '%s\n' "$output" | tail -n 1))" ;;
        1) echo "$stamp AGENT RECORDS FOUND"; printf '%s\n' "$output" ;;
        2) echo "$stamp no usernoted database" ;;
        3) echo "$stamp usernoted database unreadable (grant Full Disk Access to this terminal)" ;;
        *) echo "$stamp audit failed (exit $status)"; printf '%s\n' "$output" ;;
    esac
    if [ "$once" -eq 1 ]; then exit "$status"; fi
    sleep "$interval"
done
