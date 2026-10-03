#!/bin/sh
# Package Sources/ into .build/AgentIsland.app.
#
# SIGN_IDENTITY selects the codesign identity. It defaults to "-", an ad-hoc
# signature, which is right for a build that never leaves this machine. TCC
# keys the Ghostty Automation grant to the signer, and an ad-hoc identity is the
# binary's own hash, so every rebuild asks for that grant again. Set
# SIGN_IDENTITY to the common name of a stable self-signed code-signing
# certificate to keep the grant across rebuilds.
set -eu

sign_identity="${SIGN_IDENTITY:--}"

swift build -c release
bundle=".build/AgentIsland.app"
/bin/rm -rf "$bundle"
/bin/mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
/bin/cp config/Info.plist "$bundle/Contents/Info.plist"
/bin/cp config/AppIcon.icns "$bundle/Contents/Resources/AppIcon.icns"
/bin/cp .build/release/AgentIsland "$bundle/Contents/MacOS/AgentIsland"
/bin/cp -R .build/release/AgentIsland_IslandCore.bundle "$bundle/Contents/Resources/"
/bin/mkdir -p "$bundle/Contents/Resources/Licenses"
/bin/cp LICENSE NOTICE LICENSES/Bantay-TUI.txt "$bundle/Contents/Resources/Licenses/"
/bin/chmod 755 "$bundle/Contents/MacOS/AgentIsland"
/usr/bin/codesign --force --deep --sign "$sign_identity" "$bundle"
/usr/bin/printf 'Built %s\n' "$bundle"
