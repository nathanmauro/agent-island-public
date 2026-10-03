# Contributing

Agent Island is an early native macOS app. Small, focused fixes and reproducible bug reports are welcome.

## Report a problem

Use the repository's Issues tab. Include your macOS and Xcode versions, agent source and version, display arrangement, expected behavior, and the smallest reproduction you can share. For navigation problems, name the terminal or desktop app involved.

Do not attach raw agent sessions, `.key` files, credentials, or unredacted transition logs. A synthetic example is best; remove private project names, prompts, paths and account information from screenshots and logs.

## Development

The Swift package has a pure `IslandCore`, Foundation-based `IslandIO`, and the AppKit/SwiftUI `AgentIsland` app. Tests use a custom runner rather than XCTest.

```sh
swift build
swift run island-tests
swift run island-tests --filter herdrReducer: --filter herdrFeed:
scripts/build-app.sh
codesign --verify --deep --strict .build/AgentIsland.app
plutil -lint config/Info.plist
for script in scripts/*.sh; do sh -n "$script"; done
git diff --check
```

Add a failing behavioral regression before changing runtime behavior. Keep clocks injected in pure logic. Treat socket payloads, registry files, rollout files, paths and identifiers as untrusted. Use argument arrays and absolute executable paths rather than shell interpolation.

Use temporary fixtures and `AGENT_ISLAND_STATE_DIR` for testing. Never rewrite an agent's configuration or install hooks. The app only owns its documented state files. Preserve upstream license notices when moving or packaging code.

For app-flow changes, also exercise the built app:

```sh
swift run island-e2e --self-check
scripts/e2e.sh --steps 1,2,3,5,7 --soak-seconds 30
```

This uses synthetic feeds and dry-run navigation. Multi-monitor pointer detection has a known local verification gap described in the README; retain the assertion and include its diagnostics when reporting a failure. Native interaction checks are still needed for changed controls. The optional step 4 moves the pointer, and step 6 inspects local notification history; neither is part of the command above.

## Pull requests

Explain the problem, the resulting behavior, what you tested and any remaining limits. Keep generated apps, build output, signing material and real session data out of commits. Update public documentation when behavior or setup changes.
