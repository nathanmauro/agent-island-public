# Changelog

## 0.1.0-preview.1 — 2026-10-02

First public source preview.

- Native menu-bar pill, grouped agent board, question/error cards, and quiet completion counts.
- Reads Herdr, Claude Code registry sessions (including Remote Control), and Codex Desktop rollouts without hooks or agent configuration changes.
- Per-agent navigation, custom row names, stale-activity indicators, and named accessibility controls.
- Failed navigation preserves the island's local unread state. Delayed clicks and popup retries retain the selected result and cannot acknowledge newer work.
- Per-user install/uninstall scripts, isolated fixture tests, and synthetic demo scenes.
- Upstream license texts included in packaged local apps; installer handles XML-special characters in home-folder paths.

This is a build-from-source preview, with no signed/notarized binary download or automatic updater. macOS 14 is the deployment target; CI runs on macOS 26 and local checks also run on macOS 27. Older systems, Intel hardware, all live agent deep links, and multi-monitor popup placement are not fully verified. See README for the current limitations.
