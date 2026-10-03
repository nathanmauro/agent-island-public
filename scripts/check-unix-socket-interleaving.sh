#!/bin/sh
# Manual interleaving check for Sources/IslandIO/Herdr/UnixSocket.swift (not built by SwiftPM, not
# part of island-tests). Compiles UnixSocket.swift with scripts/unix-socket-interleaving-check.swift,
# which forces the three close()/writeAll() interleavings described at the top of that file, and
# exits non-zero if any case fails. Rerun it after any change to UnixSocket's locking.
#
# Usage: scripts/check-unix-socket-interleaving.sh [<git revision>]
#   Without a revision it checks the working tree. With one it checks that revision's
#   UnixSocket.swift: 14e710a fails case 1 (write after close) and 50f5151 fails case 3
#   (shutdown after the writer closed the descriptor).
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/unix-socket-check.XXXXXX")
trap 'rm -rf "$work"' EXIT

if [ $# -ge 1 ]; then
    git -C "$root" show "$1:Sources/IslandIO/Herdr/UnixSocket.swift" > "$work/UnixSocket.swift"
else
    cp "$root/Sources/IslandIO/Herdr/UnixSocket.swift" "$work/UnixSocket.swift"
fi
cp "$root/scripts/unix-socket-interleaving-check.swift" "$work/main.swift"
swiftc -swift-version 5 -o "$work/check" "$work/main.swift" "$work/UnixSocket.swift"
"$work/check"
