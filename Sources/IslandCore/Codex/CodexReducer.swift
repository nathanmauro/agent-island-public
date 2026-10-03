import Foundation

/// Folds rollout lines into per-thread state (turn_id pairing, exact and _async waiting, errors)
/// and maps thread state to board rows. Pure: every time comes from records or the `now` argument.
public struct CodexReducer: Sendable {
    static let fallbackQuestion = "Codex is waiting for your answer"

    public private(set) var threads: [String: ThreadState] = [:]
    private var threadIDByPath: [String: String] = [:]

    public init() {}

    /// Applies `lines` (in file order) to the thread that owns `file` and returns every thread,
    /// sorted by thread id. The thread id is the session_meta id, or the file-name UUID when the
    /// lines carry no session_meta; it stays fixed per file until resetFile/removeFile.
    public mutating func ingest(lines: [Data], file: CodexRolloutFile) -> [ThreadState] {
        let records = lines.compactMap(CodexRolloutParser.parse(line:))
        if !records.isEmpty, let threadID = resolveThreadID(for: file, records: records) {
            var state = threads[threadID] ?? ThreadState(threadID: threadID)
            for record in records {
                Self.apply(record, to: &state)
            }
            threads[threadID] = state
        }
        return threads.values.sorted { $0.threadID < $1.threadID }
    }

    /// Forget the file's thread before a cold-start re-scan (truncated or replaced file).
    public mutating func resetFile(_ file: CodexRolloutFile) {
        forget(file)
    }

    /// Forget the file's thread for good (file deleted or older than the recent window).
    public mutating func removeFile(_ file: CodexRolloutFile) {
        forget(file)
    }

    /// error > waiting(exact) > working|stale(open turn; stale when !codexRunning) > waiting(_async, unseen, <12 h)
    /// > doneUnseen > idle. Hidden threads (CodexThreadFilter) produce no row.
    public static func rows(threads: [ThreadState], seen: CodexSeenStore, titles: [String: String], showExec: Bool,
                            codexRunning: Bool, now: Date) -> [AgentRow] {
        threads.sorted { $0.threadID < $1.threadID }.compactMap { thread -> AgentRow? in
            guard CodexThreadFilter.isVisible(thread.meta, showExec: showExec), let meta = thread.meta else {
                return nil
            }
            let fallbackSince = thread.lastEventAt ?? meta.startedAt ?? now
            let completionUnseen = seen.isUnseen(
                threadID: thread.threadID,
                turnID: thread.lastCompletedTurnID,
                completedAt: thread.lastCompletedAt,
                now: now
            )
            let state: DisplayState
            let detail: Detail?
            let since: Date
            let status: String
            // A failed turn (lastErrorTurnID set by .taskFailed) is a closed turn, same as a
            // completion: it clears to idle once seen (row click/jump, the
            // first-launch baseline, or the 12 h expiry — all keyed on lastCompletedTurnID like
            // any other completion). A standalone event_msg error/stream_error (never observed in
            // real data; lastErrorTurnID nil) has no turn id to mark seen, so it keeps the
            // original behavior: it stays until the next task_started, regardless of seen or of
            // whether some unrelated turn happens to be open or already-seen-completed.
            // Fix round 1 (Task 10 review): this used to gate on `openTurnID != nil`, which does
            // not identify a standalone error (turnAborted and "no turn ever started" both leave
            // openTurnID nil too), silencing it whenever nothing else was open or unseen.
            if let error = thread.lastError, thread.lastErrorTurnID == nil || completionUnseen {
                state = .error
                detail = Detail(question: error, kind: .error)
                since = thread.lastErrorAt ?? fallbackSince
                status = "error"
            } else if let callID = thread.openUserInputCalls.keys.sorted().first,
                      let question = thread.openUserInputCalls[callID] {
                state = .waiting
                detail = Detail(question: question.question, options: question.options, kind: .question)
                since = fallbackSince
                status = CodexRolloutParser.userInputToolName
            } else if thread.openTurnID != nil {
                state = codexRunning ? .working : .stale
                detail = nil
                since = fallbackSince
                status = "task_started"
            } else if let question = thread.asyncQuestionInLastCompletedTurn, completionUnseen {
                state = .waiting
                detail = Detail(question: question.question, options: question.options, kind: .question)
                since = thread.lastCompletedAt ?? fallbackSince
                status = CodexRolloutParser.asyncUserInputToolName
            } else if completionUnseen {
                state = .doneUnseen
                detail = thread.lastAgentMessage.map { Detail(question: $0, kind: .recap) }
                since = thread.lastCompletedAt ?? fallbackSince
                status = "task_complete"
            } else {
                state = .idle
                detail = nil
                since = thread.lastCompletedAt ?? fallbackSince
                status = "idle"
            }
            let folder = meta.cwd.flatMap(Self.folderName)
            let title = titles[thread.threadID] ?? titles[meta.id] ?? folder ?? "Codex thread"
            return AgentRow(
                id: RowID(source: .codexDesktop, key: thread.threadID),
                title: title,
                subtitle: folder ?? "",
                state: state,
                since: since,
                detail: detail,
                jump: .codexThread(id: meta.id),
                cwd: meta.cwd,
                processIDs: [],
                sourceStatus: status,
                acknowledgmentID: completionUnseen && (state == .doneUnseen
                    || (state == .error && thread.lastErrorTurnID != nil)
                    || (state == .waiting && thread.openUserInputCalls.isEmpty && thread.openTurnID == nil))
                    ? thread.lastCompletedTurnID : nil
            )
        }
    }

    /// The file name is the anchor of thread identity: it wins whenever it embeds a UUID. Only
    /// when the file name carries none do we fall back to the first session_meta id in the batch.
    /// Fix round 1, Finding 1: a forked subagent's rollout has two session_meta lines (the child's
    /// own, then the parent's, with a different id); trusting "the first meta in the batch" over
    /// the file name let the parent's meta silently take over the child's thread. The file name
    /// (which Codex names for the thread that owns the file) is the more robust anchor — it also
    /// protects against a batch whose first usable meta belongs to a different id for any other
    /// reason (for example a partial read that lands past a size cap).
    private mutating func resolveThreadID(for file: CodexRolloutFile, records: [CodexRolloutRecord]) -> String? {
        if let known = threadIDByPath[file.path] {
            return known
        }
        let threadID: String?
        if let fromFileName = file.threadIDFromFileName {
            threadID = fromFileName
        } else {
            threadID = records.lazy.compactMap { record -> String? in
                if case .sessionMeta(let meta) = record { return meta.id }
                return nil
            }.first
        }
        guard let threadID else { return nil }
        threadIDByPath[file.path] = threadID
        return threadID
    }

    private mutating func forget(_ file: CodexRolloutFile) {
        guard let threadID = threadIDByPath.removeValue(forKey: file.path) else { return }
        if !threadIDByPath.values.contains(threadID) {
            threads.removeValue(forKey: threadID)
        }
    }

    static func apply(_ record: CodexRolloutRecord, to state: inout ThreadState) {
        switch record {
        case .sessionMeta(let meta):
            // Fix round 1, Finding 1: apply a session_meta only when it belongs to this thread.
            // A forked subagent's file carries the child's own meta first, then the parent's
            // (with a different id, since forked_from_id points at the parent); the parent's
            // meta must never overwrite the child thread's.
            guard meta.id == state.threadID else { return }
            state.meta = meta
            touch(&state, meta.startedAt)
        case .taskStarted(let turnID, let at):
            // A later task_started supersedes the previous completion (it counts as seen),
            // any _async question, any open call and any error.
            state.openTurnID = turnID
            state.openUserInputCalls = [:]
            state.asyncQuestionInLastCompletedTurn = nil
            state.lastCompletedTurnID = nil
            state.lastCompletedAt = nil
            state.lastAgentMessage = nil
            state.lastError = nil
            state.lastErrorAt = nil
            state.lastErrorTurnID = nil
            touch(&state, at)
        case .taskComplete(let turnID, let message, let at):
            guard state.openTurnID == turnID else { return }   // mismatched turn_id: ignored
            state.openTurnID = nil
            state.openUserInputCalls = [:]
            state.lastCompletedTurnID = turnID
            state.lastCompletedAt = at ?? state.lastEventAt
            state.lastAgentMessage = message
            touch(&state, at)
        case .taskFailed(let turnID, let at, let message):
            guard state.openTurnID == turnID else { return }   // mismatched turn_id: ignored, same as taskComplete
            state.openTurnID = nil
            state.openUserInputCalls = [:]
            // A failed turn is a closed turn: lastCompletedTurnID/lastCompletedAt double as "the
            // last closed turn" so seen (markSeen/isUnseen) covers a failure exactly like a
            // completion. lastErrorTurnID marks this as a closed-turn error (not a standalone
            // one), which is what the rows() gate above keys on.
            state.lastCompletedTurnID = turnID
            state.lastCompletedAt = at ?? state.lastEventAt
            state.lastError = message
            state.lastErrorAt = at ?? state.lastEventAt
            state.lastErrorTurnID = turnID
            touch(&state, at)
        case .turnAborted(let turnID, _, let at):
            guard turnID == nil || turnID == state.openTurnID else { return }
            state.openTurnID = nil
            state.openUserInputCalls = [:]
            state.asyncQuestionInLastCompletedTurn = nil
            touch(&state, at)
        case .functionCall(let name, let callID, let arguments, let at):
            let question = CodexRolloutParser.question(fromArguments: arguments)
                ?? CodexQuestion(question: fallbackQuestion, options: [])
            if name == CodexRolloutParser.userInputToolName {
                state.openUserInputCalls[callID] = question
            } else if name == CodexRolloutParser.asyncUserInputToolName {
                state.asyncQuestionInLastCompletedTurn = question
            }
            touch(&state, at)
        case .functionCallOutput(let callID, let at):
            if state.openUserInputCalls.removeValue(forKey: callID) != nil {
                touch(&state, at)
            }
        case .error(let message, let at):
            // Standalone event_msg error/stream_error: not tied to any turn, so it is never
            // seen-gated (lastErrorTurnID nil) — it stays visible until the next task_started.
            state.lastError = message
            state.lastErrorAt = at ?? state.lastEventAt
            state.lastErrorTurnID = nil
            touch(&state, at)
        }
    }

    private static func touch(_ state: inout ThreadState, _ at: Date?) {
        guard let at else { return }
        if let current = state.lastEventAt, current > at { return }
        state.lastEventAt = at
    }

    static func folderName(_ cwd: String) -> String? {
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty || name == "/" ? nil : name
    }
}
