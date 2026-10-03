#!/bin/sh
# Sample one process's CPU and open-file count (agent-island spec 12.3 step 4 and the 12.5 #12 trial).
#
# usage: scripts/soak-sample.sh [--live] PID [SECONDS] [INTERVAL]
#   SECONDS defaults to 600 (the 10-minute fd window) and INTERVAL to 5.
# Prints "<epoch> cpu=<ps %cpu> fds=<lsof count> sockets=<unix sockets> other=<fds - sockets>"
# per sample, then
#   "soak-sample: samples=N avg_cpu=X fd_min=A fd_max=B other_min=C other_max=D verdict=PASS|FAIL|LIVE".
# Exit 0 when avg_cpu < 1.0 and fd_max - fd_min <= 2; 1 when either bound is broken;
# 2 on a usage error or when the process is not running.
#
# --live (the 24 h trial against real agents): the island holds one Herdr status-stream socket per
# Herdr pane (shells included, up to 64) plus the event stream and in-flight requests, so `fds` and
# `sockets` follow the pane count and CPU follows agent activity. The idle bounds above do not apply:
# the run prints verdict=LIVE and exits 0. Judge the samples instead: `other` stays flat, and
# `sockets` tracks the Herdr pane count; a leak is a steady climb in `other`, or in `sockets` while the
# pane count holds.
#
# 24 h trial:
#   scripts/soak-sample.sh --live "$(pgrep -x AgentIsland)" 86400 60 | tee -a ~/.local/state/agent-island/soak.log
set -eu

usage() {
    echo "usage: scripts/soak-sample.sh [--live] PID [SECONDS] [INTERVAL]" >&2
    exit 2
}

live=0
if [ "${1:-}" = --live ]; then
    live=1
    shift
fi
[ $# -ge 1 ] && [ $# -le 3 ] || usage
pid=$1
seconds=${2:-600}
interval=${3:-5}
case "$pid" in ''|*[!0-9]*) usage ;; esac
case "$seconds" in ''|*[!0-9]*) usage ;; esac
case "$interval" in ''|*[!0-9]*) usage ;; esac
[ "$interval" -ge 1 ] || usage

samples=$((seconds / interval + 1))
# A soak needs at least 2 samples to report a min/max fd spread (fix round 1, checklist accuracy).
[ "$samples" -ge 2 ] || usage
count=0
cpu_sum=0
fd_min=
fd_max=
other_min=
other_max=
while [ "$count" -lt "$samples" ]; do
    if [ "$count" -gt 0 ]; then sleep "$interval"; fi
    cpu=$(LC_ALL=C /bin/ps -o %cpu= -p "$pid" 2>/dev/null | tr -d ' ')
    if [ -z "$cpu" ]; then
        echo "soak-sample: process $pid is not running (relaunched? see ~/.local/state/agent-island/stderr.log, then restart with the new pid)" >&2
        exit 2
    fi
    # A running process has already been confirmed by the ps check above, so lsof reporting
    # zero matches (exit 1) is itself a failure worth stopping for, not a legitimate fds=0
    # (checklist accuracy, fix round 1): silently swallowing lsof's exit status would let a
    # broken sampler read as a healthy PASS. The assignment sits in the `if` condition itself
    # (not a bare `x=$(cmd)`) so `set -e` does not abort the script before this is checked.
    if lsof_out=$(/usr/sbin/lsof -n -P -p "$pid" 2>/dev/null); then
        lsof_status=0
    else
        lsof_status=$?
    fi
    if [ "$lsof_status" -ne 0 ]; then
        echo "soak-sample: lsof failed for pid $pid (exit $lsof_status)" >&2
        exit 2
    fi
    fds=$(printf '%s\n' "$lsof_out" | awk 'NR > 1' | wc -l | tr -d ' ')
    # lsof's TYPE column (5th): the island's only sockets are Unix-domain connections to Herdr.
    sockets=$(printf '%s\n' "$lsof_out" | awk 'NR > 1 && $5 == "unix"' | wc -l | tr -d ' ')
    other=$((fds - sockets))
    echo "$(date +%s) cpu=$cpu fds=$fds sockets=$sockets other=$other"
    cpu_sum=$(awk -v a="$cpu_sum" -v b="$cpu" 'BEGIN { printf "%.4f", a + b }')
    if [ -z "$fd_min" ] || [ "$fds" -lt "$fd_min" ]; then fd_min=$fds; fi
    if [ -z "$fd_max" ] || [ "$fds" -gt "$fd_max" ]; then fd_max=$fds; fi
    if [ -z "$other_min" ] || [ "$other" -lt "$other_min" ]; then other_min=$other; fi
    if [ -z "$other_max" ] || [ "$other" -gt "$other_max" ]; then other_max=$other; fi
    count=$((count + 1))
done
avg=$(awk -v s="$cpu_sum" -v n="$count" 'BEGIN { printf "%.2f", s / n }')
if [ "$live" -eq 1 ]; then
    verdict=LIVE
else
    verdict=$(awk -v a="$avg" -v lo="$fd_min" -v hi="$fd_max" 'BEGIN { if (a < 1.0 && hi - lo <= 2) print "PASS"; else print "FAIL" }')
fi
echo "soak-sample: samples=$count avg_cpu=$avg fd_min=$fd_min fd_max=$fd_max other_min=$other_min other_max=$other_max verdict=$verdict"
[ "$verdict" != FAIL ]
