# Architecture

Agent Island is one LSUIElement process started by one LaunchAgent (`com.nathan.agent-island`, `KeepAlive` with `SuccessfulExit` false: restarted after a crash, not after a clean Quit). It reads three agent sources, merges them into one row list, decides when to interrupt, and draws a pill, a board and a peek card. Every decision lives in pure code that the test runner exercises against fixtures and fakes. The app target only does AppKit, SwiftUI and OS calls.

This document describes the public preview. Integration formats and live navigation behavior can change with upstream tools; see the README for tested platforms and limitations.

## Targets

| Target | Role | Imports |
|---|---|---|
| `IslandCore` | Model, reducers, parsers, interrupt policy, jump planner and execution rules, observability records, and the kept Moonglade geometry, formatters and utilities | Foundation only; no AppKit or SwiftUI |
| `IslandIO` | Herdr socket client and feed, Claude registry feed, Codex Desktop feed, FSEvents wrapper, off-main action runner, transition log, state dump | Foundation, Darwin, CoreServices; no AppKit or SwiftUI |
| `AgentIsland` | The app: composition root, panels and SwiftUI views, NSWorkspace, AppleScript, NSSound | Everything |
| `IslandTestSupport` | Fakes shared by the tests and the end-to-end driver: `FakeHerdrServer`, `FakeSessionFeed`, `ManualWallClock`, `FileAccessSpy`, `RolloutLine` | |
| `IslandTests` (`island-tests`) | Custom executable test runner (not XCTest) | |
| `IslandE2E` (`island-e2e`) | Scripted end-to-end driver against the built app bundle | |

## Data flow

```
Herdr socket ──────────► HerdrFeed ─────────┐
Claude registry (*.json) ► ClaudeRegistryFeed ┼─► StateStore ─► InterruptPolicy ─► PeekCoordinator ─► PeekController (card, pointer display)
Codex rollouts ─────────► CodexDesktopFeed ──┘       │                                   └─► ChimePlayer (one chime, only with a card)
                                                     ├─► pill + board (NotchPanelController, primary display)
                                                     ├─► TransitionLog (JSONL) and StateDump (tests)
                                                     └─► focus(row) ─► JumpPlanner ─► JumpPerforming (live or dry-run)
```

## Feeds

Every source implements `SessionFeed`: `start(_:)` publishes the feed's full row set on every change, `observeHealth(_:)` reports `online`, `inactive`, `offline`, `disabled` or `degraded` (online with live rows, but a feature is unavailable: a warning glyph without dimming), `jump(_:)` acknowledges the captured row only after successful navigation and only if its opaque `acknowledgmentID` still matches the current result, and `loadDetail(for:)` fetches hover detail lazily. Each feed owns a pure reducer in IslandCore and does its I/O in IslandIO. Two small optional protocols in IslandCore let a feed opt into extra observability without changing `SessionFeed` itself: `FeedDiagnosticsReporting` (a message unrelated to health — today Herdr's pane-stream-cap notice) and `FeedIOErrorCounting` (I/O errors a feed would otherwise swallow — the Codex feed's seen-store, cold-scan, tail-read and session-index failures, and the Claude registry feed's per-file read and decode failures). `StateStore` casts its feeds to these when wiring observability, the same pattern as `HerdrFocusReporting`. `feedIOErrorCounts` omits a feed that never opts in (Herdr today) rather than reporting it as zero, so an absent key always means "not tracked", never "no errors".

**Herdr** (`HerdrFeed`, `HerdrReducer`, `HerdrCodec`, `HerdrClient`)
- One Unix-socket connection per request, one per subscription, and never a write on a subscribed connection. Cancelling or dropping a stream closes its descriptor.
- Bootstrap: `ping` (protocol must be 22), open the global lifecycle stream, snapshot, open one status stream per pane (capped at 64), snapshot again, apply the buffered events.
- A 12 s snapshot reconcile repairs state and reopens a stream that went silent. A 30 s ping checks health. On EOF or a failed ping every stream closes and the bootstrap repeats with backoff 0.5, 1, 2 and 5 s. A protocol other than 22, or an unsupported method, disables the feed and probes again every 60 s. A server older than 0.9.1 (`HerdrServerVersion`, from the bootstrap ping) reports `degraded` instead of `online`: its `agent.focus` changes server focus but never moves the attached client's view.
- Status mapping: working → working (stale after 30 min without a status or sequence change), blocked → waiting, done → done, idle → idle, unknown → starting. Errors are narrow: a pane that exits while working or blocked, or whose agent is released while working, unless the pane closes within 1 s or you were looking at it. A turn that finishes while Ghostty is not frontmost is marked done by the island until you look at it.
- Blocked questions come from a passive detection read parsed by `DetectionTextParser`; done recaps are read only on hover.
- Detection reads belong to a particular waiting or done episode. Leaving the episode, removing or replacing the pane, or reconnecting invalidates outstanding reads and recap caches, so a delayed response cannot overwrite a later question or completion.
- Hitting the pane-stream cap (more than `maxPaneStreams` panes; those beyond it update only on the reconcile) is a diagnostic, not a health change: `observeDiagnostics(_:)` reports it once per session, and `ObservabilityWiring` logs it to the transition log as a `feed` record with `rule: "diagnostic"` — the discriminator that keeps it from being read as that feed's first health report, which also has no `from`.

**Claude registry** (`ClaudeRegistryFeed`, `ClaudeRegistryReducer`)
- Reads `<pid>.json` files only (never `*.key`), through FSEvents plus a 2 s sweep. A session is live when its pid exists and its start time matches `procStart` within 1 s.
- Only interactive sessions count; `sdk-*` entrypoints are hidden. A failed or partial read keeps the previous entry, so a file mid-rewrite never flickers.
- `busy` → working, `waiting` → waiting (question or permission), `idle` after `busy` → done until successfully selected, next busy or 12 h.
- A per-file read failure or an undecodable entry never blocks the feed — the previous decoded entry is kept and the next sweep retries — but each one increments `ioErrorCount` (`FeedIOErrorCounting`).

**Codex Desktop** (`CodexDesktopFeed`, `CodexReducer`, `CodexRolloutParser`)
- Recursive FSEvents plus a 2 s stat poll over files changed in the last 24 h, reading forward from byte offsets. A partial last line waits for its newline; a truncated or replaced file starts over.
- Cold start reads line 1 (`session_meta`, capped at 1 MB) and scans backwards in 256 KB chunks to the last turn boundary, so a 200 MB rollout costs a few reads.
- Subagent, guardian and (unless enabled) exec threads are hidden. An open `request_user_input` call is waiting; a turn in progress is working (stale when Codex is not running); an unseen finished turn is done; error events are errors. Activating Codex does not acknowledge any thread: only explicit row selection acknowledges that thread, with the existing first-launch baseline, later-turn reset and 12-hour expiry retained.
- `codex-seen.json` records the last seen turn per thread. The first launch records everything as seen; successful navigation to the captured current result, a later turn or 12 h clears its unread state.
- A seen-store save failure, a cold-scan failure, a tail-read error, or a `session_index.jsonl` read failure never blocks the feed — the old state is kept and the next poll retries — but each one increments `ioErrorCount` (`FeedIOErrorCounting`), surfaced through the state dump's `feedErrorCounts` so a trial run can see whether they are actually happening.

## StateStore

`StateStore` (`@MainActor @Observable`) keeps each feed's rows, merges them with `RowMerger` (a Claude registry row whose pid is a Herdr pane's foreground process is dropped, and its status is kept as the Herdr row's registry shadow), sorts by severity, then recency, and publishes only when something changed. It keeps the last health per feed (offline rows stay, dimmed), persists row renames, and starts a 10 s quiet period at launch and whenever a feed comes back online. Every change reaches its observers as a `StoreChange` (previous rows, rows, policy decision, registry shadow, health changes); the policy's own heartbeat means one arrives at least every 10 s even when nothing visible changed. UI handlers capture the selected row before scheduling a task and retain it through popup retries. `focus(_:)` runs `JumpPlanner.plan` through the configured `JumpPerforming`, and acknowledges that captured row through its feed only after navigation succeeds. A navigation failure skips the island’s local acknowledgment, records `lastErrorDescription` (also part of the state dump), reports `onJumpFailure` (logged as a `jump` record), and is rethrown. A delayed success cannot acknowledge a newer result: Codex uses the completed turn ID, while Herdr and registry use monotonic episode IDs that survive reset/pruning. A missing or outdated ID grants no acknowledgment; metadata changes keep the same ID. Herdr continues to own its server-side seen semantics and actual-view detection. A successful focus clears an older error, while sequence ordering preserves any failure recorded after that focus started, including its own acknowledgment failure. `NotchWidgetView` still shows only its own generic message either way — `lastErrorDescription` is for the log and the dump, not the board.

## Interrupts

- `InterruptPolicy` (pure, injected clock) decides peeks and the chime from `(previous rows, rows, focus, now)`: only waiting and error; blocked must hold 1 s; one peek per row per episode (10 s out of waiting, or a changed question, starts a new one); chimes at least 3 s apart; a 10 s quiet period after launch, reconnect and wake; nothing for the agent you are looking at (Ghostty frontmost with that pane focused in Herdr, Codex frontmost, or Claude frontmost).
- `PeekCoordinator` keeps the `PeekQueue` (error before waiting, then newest; "+N more") and asks `PeekController` to show the card. It is the only caller of `ChimePlayer`, and only in the same call that presents a card.
- `PeekController` shows the card on the display under the pointer, keeps it 8 s or while hovered, and re-anchors after display changes. `isBoardExpanded` can briefly read `true` right after a re-anchor, because collapse goes through SwiftUI; UI state reporting treats that as an ordinary transient value, not an error, since the next state change corrects it.

## Jump

`JumpPlanner` (pure) turns a row's `JumpTarget` into `JumpAction`s. `LiveJumpPerformer` runs them in order through `JumpSequencer`: a fallback action runs only after the previous one failed and recovers that failure; every primary action runs; the first unrecovered failure is reported. Nothing blocks the main actor: Herdr `agent.focus` is async socket I/O, AppleScript and `tmux` run through `OffMainActionRunner` (a detached task), and URLs open through the async NSWorkspace API. `GhosttyRaiser` focuses the Ghostty terminal whose title starts with Herdr's window title, retrying three times 150 ms apart and then with the host-only prefix, before the planner's fallback activates Ghostty. `LiveJumpContextProvider` picks Codex.app (never ChatGPT.app, which shares its bundle id) and the running Claude.app. With `AGENT_ISLAND_JUMP_DRY_RUN=1`, `RecordingJumpPerformer` only records. The additional `AGENT_ISLAND_JUMP_TEST_CONTROL=1` requires an explicit `AGENT_ISLAND_STATE_DIR` and makes each recorded attempt wait for an owner-only outcome file under `support/jump-controls`; this lets native UI checks hold, fail and complete jumps without real navigation. Attempts are numbered from 1, outcomes are `success` or `failure`, and a missing outcome times out after 60 seconds. A failure from `perform(_:)` propagates out of `StateStore.focus` (see StateStore above) rather than being swallowed.

Popup clicks run through `PeekJumpRecovery`: one click is consumed, and a failed asynchronous jump asks for recovery through a native dialog. Retry reuses the original row ID without consuming another queued popup. Closing the dialog, a successful jump, or task cancellation ends recovery. Board clicks retain their inline error message.

## Display

`NotchPanelController` keeps the pill on the primary display (the display whose menu bar is at the origin, `CGMainDisplayID`), or on every display in the all-displays mode. The pill uses Moonglade's hanging geometry: a 23 pt pill inside the menu bar on a display without a notch, or the notch wings on a built-in display. An always-on global and local mouse-move monitor drives click-through and hover: the panel ignores mouse events except inside the current interactive region (the collapsed pill, the expanded board or the card), computed by `ClickThroughPolicy`. After wake or a screen change the panels wait 0.35 s, then `PanelAnchorPlanner` re-anchors them, collapsing the board if its display moved. The glass keeps Moonglade's `CABackdropLayer` path with the public `NSVisualEffectView` fallback.


Stale rows have their own summary segment and an expanded **Activity uncertain** section. They use a static question-mark glyph, keep readable text, and show the status episode age without implying ongoing work. Offline-feed dimming remains independent. Frozen group assignments still keep rows stable while the pointer is on the board. The jump button owns the session accessibility label; action and rename controls remain separate named children.

## Observability

- `TransitionLog` appends `TransitionRecord`s to `transitions.jsonl` from a background queue (state changes, peeks, the chime with its truncated question, suppressions with their rule, feed health changes and diagnostics, the Herdr rows' registry shadow, and jump failures). It rotates at 10 MB and keeps 3 files. A `StoreChange` with nothing to report (the heartbeat, or an identical republish) appends no line — `Tests/IslandTests/ObservabilityTests.swift`'s `testObservabilityHeartbeatsAndIdenticalRepublishesAppendNoBytes` is a permanent regression against the real `StateStore` + `WakeGuardedPolicy(InterruptPolicy())` + `TransitionLog`, not a fake.
- `StateDump`, enabled by `AGENT_ISLAND_STATE_DUMP`, atomically writes a `StateDumpSnapshot` (rows, summary, feed health, feed I/O error counts, the last jump failure's description, peek queue, chime count, planned and performed jumps, UI state) on every store, UI or peek change, debounced 50 ms, but only when the content actually changed — the heartbeat and the 0.25 s poll both ask far more often than the content changes, and comparing the built snapshot is cheap. The end-to-end run asserts against it.
- `UIStateReporter` collects the pill and card state (board expanded, click-through, display ids) from `NotchPanelController` and `PeekController`.

## Trust boundaries

- Agent state is read-only. The app writes only its own files (Application Support, `~/.local/state/agent-island`) and preferences; `scripts/install.sh` writes only the app bundle and the LaunchAgent plist.
- Herdr: only `ping`, `session.snapshot`, `events.subscribe`, `pane.process_info`, `agent.read` (detection source only, which is passive) and `agent.focus` are called. No mutating method is ever called.
- File reads are size-bounded, reject symbolic links and changing files (`SecureFileReader`), and the registry reader accepts `<pid>.json` names only.
- Subprocesses use argument arrays and executables from fixed trusted directories; AppleScript text is escaped; nothing is evaluated by a shell.
- Static guard tests scan every file under `Sources/` (comments included) and fail on Notification Center APIs, agent-config paths and Herdr mutation methods.

## Testing

- `swift run island-tests` runs every area; display names start with the area prefix (`herdrFeed:`, `registry:`, `jumpPerformer:`, `observability:` and so on), and `--filter <prefix>` selects areas.
- Pure logic is tested with injected clocks and inputs. Feeds are tested against `FakeHerdrServer` (an in-process Unix-socket server), temporary registry and rollout directories, and masked or synthetic fixtures under `Tests/Fixtures`. Descriptor-leak tests count open file descriptors around reconnect cycles.
- `HERDR_CONTRACT=1` runs read-only checks against the live Herdr server.
- `scripts/e2e.sh` launches the built app against the fakes with the state dump and dry-run jumps enabled, and samples CPU and descriptors.
