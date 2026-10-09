// CodeNotch 1.20.0 / 6e8b0f8 (MIT): CodexActivityMonitor, CodexStore/Thread/Cache, AgentSession.
// Quota scheduling only; no session UI, logs, history persistence, hooks, or commands.
// All startup is gated by enabled monitoring AND selected Codex in UsageMonitorStore.
import SQLite3
import AppKit
import Combine
import Darwin
import Foundation

/// The small, stable part of a Codex rollout that is useful for activity.
///
/// `item_completed` is intentionally ignored: commands and other child items
/// emit it too. A turn is complete only after Codex writes `task_complete`.
struct CodexRolloutActivity {
    enum State: Equatable {
        case busy
        case success
    }

    /// One window into the end of the rollout. Rollouts run to hundreds of
    /// megabytes, so the file is walked backwards in slices rather than read
    /// whole — the same `tail` trick the Claude and Antigravity readers use.
    private static let windowBytes: UInt64 = 256 * 1024
    /// How far back a lifecycle event may be before the search gives up. A
    /// mid-turn rollout keeps its `task_started` arbitrarily far behind the
    /// writes streaming in — walking to it would read the whole file on every
    /// tick. A fresh file with no lifecycle event in its last megabyte is a
    /// turn in progress in every realistic case, and the caller maps a miss
    /// to `.busy` — the same answer the full scan would give.
    private static let maxWindows = 4

    static func state(from url: URL) -> State? {
        guard let handle = SQLiteStore.regularFile(url) else { return nil }
        defer { try? handle.close() }
        guard var windowEnd = try? handle.seekToEnd() else { return nil }

        // The newest lifecycle event wins, so windows are scanned newest
        // first and the first match is the answer. A window's first line is
        // cut in half by the read; the fragment is carried into the earlier
        // window, where the rest of it lives, rather than parsed half a line.
        var carried = Data()
        var windows = 0
        while windowEnd > 0, windows < maxWindows {
            windows += 1
            let windowStart = windowEnd > windowBytes ? windowEnd - windowBytes : 0
            guard (try? handle.seek(toOffset: windowStart)) != nil else { return nil }

            // `read(upToCount:)` may legally deliver fewer bytes than asked
            // for, and a window that came back short would silently lose the
            // lines its tail never reached — and join `carried` to a stretch
            // of file it does not follow. Read until the window is filled.
            // An error still fails the scan; hitting EOF early means the
            // file shrank between the seek and the read (rotation), and what
            // arrived is still contiguous with `windowStart`.
            var window = Data()
            window.reserveCapacity(Int(windowEnd - windowStart))
            while window.count < Int(windowEnd - windowStart) {
                guard let chunk = try? handle.read(
                    upToCount: Int(windowEnd - windowStart) - window.count
                ) else { return nil }
                if chunk.isEmpty { break }
                window.append(chunk)
            }
            // `carried` continues the line this window's start cut — but only
            // when the read reached `windowEnd`, where the fragment begins. A
            // short window ends somewhere else entirely, and joining the two
            // would fabricate a line out of unrelated bytes.
            if window.count == Int(windowEnd - windowStart) {
                window.append(carried)
            }

            // A window that opens on a newline was not cut mid-line: its first
            // line is whole, and the earlier window's last line is the one
            // missing its newline. Carrying anything back would glue the two.
            let startsOnALineBreak = window.first == UInt8(ascii: "\n")
            var lines = window.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
            carried = windowStart > 0 && !startsOnALineBreak && !lines.isEmpty
                ? Data(lines.removeFirst()) : Data()

            for line in lines.reversed() {
                guard let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      record["type"] as? String == "event_msg",
                      let payload = record["payload"] as? [String: Any],
                      let type = payload["type"] as? String else { continue }

                switch type {
                case "task_started":
                    return .busy
                case "task_complete":
                    return .success
                case "turn_aborted":
                    // An aborted turn is not a successful completion. Returning
                    // nil lets the activity monitor drop it without announcing.
                    return nil
                default:
                    continue
                }
            }
            windowEnd = windowStart
        }
        return nil
    }
}

/// Reports whether Codex is mid-turn.
///
/// Codex does not publish a live status field, but its rollout includes
/// lifecycle events. `task_started` and `task_complete` are used when present;
/// the file's recent modification time remains the activity fallback.
///
/// **That is a heuristic, and it is labelled as one.** It cannot tell a turn
/// that is thinking from one that finished a second ago, so it errs short: the
/// ring stops spinning `staleAfter` seconds after the last write rather than
/// claiming activity it cannot see. A stale rollout is deliberately not
/// converted into `.success` or `.idle`, because inactivity is not evidence
/// that a Codex turn completed — a long-running command can be quiet too.
/// If Codex grows a real status field this should be replaced by it.
@MainActor
final class CodexActivityMonitor {
    private(set) var sessions: [AgentSession] = []
    var onBusyChange: (Bool) -> Void = { _ in }

    private let stateStore: URL
    private let desktopStore: URL
    private let profile: CodexProfile
    private let interval: TimeInterval
    /// How long after the last write a turn is still considered in flight.
    private let staleAfter: TimeInterval
    private var timer: Timer?

    init(
        profile: CodexProfile = .default(),
        stateStore: URL? = nil,
        desktopStore: URL? = nil,
        interval: TimeInterval = 2,
        staleAfter: TimeInterval = 8
    ) {
        self.profile = profile
        self.stateStore = stateStore ?? profile.stateURL
        self.desktopStore = desktopStore ?? profile.desktopStoreURL
        self.interval = interval
        self.staleAfter = staleAfter
    }

    func start() {
        rescan()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.rescan() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        sessions = []
        entered = [:]
    }

    private let storeCache = CodexStoreCache()

    /// When each row entered the state it is in, by session id. See `settled`.
    private var entered: [String: (state: AgentSession.State, at: Date)] = [:]

    private func rescan() {
        let read = Self.read(stateStore: stateStore, desktopStore: desktopStore,
                             staleAfter: staleAfter, profile: profile, cache: storeCache)
        let found = Self.settled(read, entered: &entered)
        guard found != sessions else { return }
        let wasBusy = sessions.contains { $0.state == .busy }
        sessions = found
        let busy = found.contains { $0.state == .busy }
        if busy != wasBusy { onBusyChange(busy) }
    }

    /// Every Codex conversation working right now, each under its own name.
    ///
    /// This used to be one row at most, called "Codex": the newest rollout or
    /// the newest desktop thread, whichever moved last. Two conversations
    /// running at once drew as one, and nothing on the notch said which
    /// request was being worked on — while the Claude rows beside it named
    /// every session. Codex does name its conversations; the name is in the
    /// same `threads` row the rollout path was already being read from.
    static func read(stateStore: URL, desktopStore: URL,
                     staleAfter: TimeInterval, now: Date = Date(),
                     profile: CodexProfile = .default(),
                     cache: CodexStoreCache = CodexStoreCache(),
                     openRollouts: Set<String>? = nil) -> [AgentSession] {
        var found: [AgentSession] = []
        // Every thread id that is part of a conversation drawn below, so the
        // desktop app's copy of the same conversation is not drawn again.
        var drawn: Set<String> = []

        // "Codex" is two programs that record their work in different places:
        // the CLI and the VS Code extension append to a rollout, and the
        // desktop app writes to its own catalogue.
        let openRollouts = openRollouts ?? CodexOpenRollouts.paths(
            under: profile.configDirectory.appendingPathComponent("sessions")
        )
        for conversation in liveConversations(cache.recentThreads(in: stateStore),
                                              staleAfter: staleAfter, now: now, cache: cache,
                                              openRollouts: openRollouts) {
            let root = conversation.root
            // The id the single row always had, so a conversation that is not
            // a sub-agent's keeps it and nothing keyed on it moves.
            let handle = root.rollout?.lastPathComponent ?? root.id
            guard let session = session(id: "\(profile.id).\(handle)",
                                        name: root.label(fallback: profile.displayName),
                                        modified: conversation.at, state: conversation.state,
                                        staleAfter: staleAfter, now: now,
                                        allowStale: conversation.isOpen)
            else { continue }
            found.append(session)
            drawn.formUnion(conversation.members)
        }

        if let desktop = cache.newestDesktopThread(in: desktopStore),
           desktop.threadID.isEmpty || !drawn.contains(desktop.threadID),
           let session = session(id: "\(profile.id).desktop", name: desktop.title,
                                 modified: desktop.updatedAt, state: .busy,
                                 staleAfter: staleAfter, now: now) {
            found.append(session)
        }

        // Newest first, with the id breaking ties so two ticks that read the
        // same thing cannot draw the rows in a different order.
        return found.sorted { $0.since == $1.since ? $0.id < $1.id : $0.since > $1.since }
    }

    /// One working conversation: the thread it started from, when any of it
    /// last moved, what it is doing, and every thread id that is part of it.
    struct Conversation {
        let root: CodexThread
        let at: Date
        let state: AgentSession.State
        let members: Set<String>
        let isOpen: Bool
    }

    /// Every conversation with a rollout written inside the window, each once.
    ///
    /// A sub-agent is folded into the conversation that spawned it rather than
    /// drawn as a row of its own. Codex can run half a dozen for one request,
    /// each with a rollout, and a row per helper would bury the one thing the
    /// person asked for — while the parent, waiting on them, may write nothing
    /// at all for minutes. So the work is credited to the root, under the
    /// root's name, for as long as any of it is moving.
    static func liveConversations(_ threads: [CodexThread],
                                  staleAfter: TimeInterval,
                                  now: Date,
                                  cache: CodexStoreCache = CodexStoreCache(),
                                  openRollouts: Set<String> = []) -> [Conversation] {
        let byID = Dictionary(threads.filter { !$0.id.isEmpty }.map { ($0.id, $0) },
                              uniquingKeysWith: { first, _ in first })

        func root(of thread: CodexThread) -> CodexThread {
            var current = thread
            var seen: Set<String> = [thread.key]
            while let parent = current.parentID, let next = byID[parent],
                  seen.insert(next.key).inserted {
                current = next
            }
            return current
        }

        var newest: [String: Date] = [:]
        var roots: [String: CodexThread] = [:]
        var members: [String: Set<String>] = [:]
        var busyRoots: Set<String> = []
        var openRoots: Set<String> = []
        let rollouts = Set(threads.compactMap { $0.rollout?.path })
        for thread in threads {
            guard let rollout = thread.rollout,
                  let modified = (try? FileManager.default
                      .attributesOfItem(atPath: rollout.path))?[.modificationDate] as? Date
            else { continue }
            let activity = cache.rolloutState(of: rollout, keeping: rollouts)
            let isRecent = now.timeIntervalSince(modified) <= staleAfter
            guard isRecent || (openRollouts.contains(rollout.path) && activity == .busy)
            else { continue }
            let root = root(of: thread)
            // A helper whose conversation cannot be found is not drawn at all.
            // Drawing it as a conversation of its own is the one wrong answer:
            // a row named after a prompt the person never wrote, announcing
            // "Complete" for a review while the real request is still working.
            guard !root.isHelper else { continue }
            roots[root.key] = root
            members[root.key, default: []].formUnion([thread.id, root.id].filter { !$0.isEmpty })
            if activity == .busy || thread.key != root.key { busyRoots.insert(root.key) }
            if openRollouts.contains(rollout.path), activity == .busy {
                openRoots.insert(root.key)
            }
            if newest[root.key].map({ $0 < modified }) ?? true { newest[root.key] = modified }
        }

        let live = Set(roots.values.compactMap { $0.rollout?.path })
        return roots.compactMap { key, root in
            guard let at = newest[key] else { return nil }
            return Conversation(root: root, at: at,
                                state: busyRoots.contains(key) ? .busy
                                    : state(of: root, staleAfter: staleAfter, now: now,
                                            cache: cache, live: live),
                                members: members[key] ?? [],
                                isOpen: openRoots.contains(key))
        }
    }

    /// The rows with `since` meaning what `AgentSession` says it means: when
    /// the row entered its current state.
    ///
    /// What `read` can see is a rollout's last write, which moves every
    /// second while a conversation works. As `since` that sorted two busy
    /// conversations by whichever wrote last, so they swapped places every
    /// few seconds, showed an elapsed time of about nothing, and made every
    /// tick look like a change. So the first sighting of a row in a state is
    /// kept until the state changes, and rows no longer present are
    /// forgotten.
    static func settled(_ sessions: [AgentSession],
                        entered: inout [String: (state: AgentSession.State, at: Date)])
    -> [AgentSession] {
        var next: [String: (state: AgentSession.State, at: Date)] = [:]
        let settled = sessions.map { session -> AgentSession in
            let held = entered[session.id]
            let at = held.flatMap { $0.state == session.state ? $0.at : nil } ?? session.since
            next[session.id] = (session.state, at)
            return AgentSession(id: session.id, name: session.name, detail: session.detail,
                                state: session.state, waitingFor: session.waitingFor,
                                since: at, processID: session.processID)
        }
        entered = next
        return settled.sorted { $0.since == $1.since ? $0.id < $1.id : $0.since > $1.since }
    }

    /// The conversation's own answer when its root is writing, and busy when
    /// only its helpers are.
    ///
    /// Never a helper's answer. A sub-agent finishing writes `task_complete`
    /// into *its* rollout while the request it was helping with is still
    /// under way, and reading that as the conversation's state would announce
    /// "Complete" for work that is not.
    ///
    /// A stale rollout is not parsed at all — the parse is the expensive part,
    /// and a file that has stopped moving has nothing current to say.
    static func state(of root: CodexThread, staleAfter: TimeInterval, now: Date,
                      cache: CodexStoreCache, live: Set<String>) -> AgentSession.State {
        guard let rollout = root.rollout,
              let modified = (try? FileManager.default
                  .attributesOfItem(atPath: rollout.path))?[.modificationDate] as? Date,
              now.timeIntervalSince(modified) <= staleAfter
        else { return .busy }
        switch cache.rolloutState(of: rollout, keeping: live) {
        case .success: return .success
        case .busy, .none: return .busy
        }
    }

    /// Only work recorded within the window counts. Anything older is a
    /// finished turn, and reporting it as work in progress would be a guess
    /// dressed as a fact.
    static func session(
        id: String, name: String, modified: Date,
        state: AgentSession.State = .busy,
        staleAfter: TimeInterval, now: Date,
        allowStale: Bool = false
    ) -> AgentSession? {
        guard allowStale || now.timeIntervalSince(modified) <= staleAfter else { return nil }

        return AgentSession(
            id: id,
            name: name,
            detail: state == .success ? "Complete" : "Working",
            state: state,
            waitingFor: nil,
            since: modified
        )
    }
}

enum CodexOpenRollouts {
    static func paths(under root: URL, pids suppliedPIDs: [pid_t]? = nil) -> Set<String> {
        let pids: [pid_t]
        if let suppliedPIDs {
            pids = suppliedPIDs
        } else {
            var count = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
            guard count > 0 else { return [] }
            var listed = [pid_t](repeating: 0,
                                 count: Int(count) / MemoryLayout<pid_t>.stride + 16)
            count = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &listed,
                                  Int32(listed.count * MemoryLayout<pid_t>.stride))
            guard count > 0 else { return [] }
            pids = listed.prefix(Int(count) / MemoryLayout<pid_t>.stride).filter(isCodex)
        }

        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        var resolvedPrefix = prefix
        if let resolved = realpath(root.path, nil) {
            let path = String(cString: resolved)
            free(resolved)
            resolvedPrefix = path.hasSuffix("/") ? path : path + "/"
        }
        var found: Set<String> = []
        for pid in pids where pid > 0 {
            let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard size > 0 else { continue }
            var fds = [proc_fdinfo](repeating: proc_fdinfo(),
                                    count: Int(size) / MemoryLayout<proc_fdinfo>.stride + 8)
            let read = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds,
                                    Int32(fds.count * MemoryLayout<proc_fdinfo>.stride))
            guard read > 0 else { continue }
            for fd in fds.prefix(Int(read) / MemoryLayout<proc_fdinfo>.stride)
                where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
                var info = vnode_fdinfowithpath()
                let infoSize = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
                guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO,
                                     &info, infoSize) == infoSize else { continue }
                let path = withUnsafePointer(to: &info.pvip.vip_path) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                        String(cString: $0)
                    }
                }
                guard path.hasSuffix(".jsonl") else { continue }
                if path.hasPrefix(prefix) {
                    found.insert(path)
                } else if path.hasPrefix(resolvedPrefix) {
                    found.insert(prefix + path.dropFirst(resolvedPrefix.count))
                }
            }
        }
        return found
    }

    private static func isCodex(_ pid: pid_t) -> Bool {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info,
                           Int32(MemoryLayout<proc_bsdinfo>.size))
                == Int32(MemoryLayout<proc_bsdinfo>.size)
        else { return false }
        return withUnsafePointer(to: &info.pbi_comm) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) {
                String(cString: $0) == "codex"
            }
        }
    }
}

/// Shared access to Codex's local state.
enum CodexStore {
    static var stateURL: URL {
        CodexProfile.default().stateURL
    }

    /// The desktop app's own thread catalogue.
    ///
    /// Codex's *rollouts* are written by the CLI and by the VS Code extension.
    /// The desktop app — ChatGPT.app, which is what most people mean by "Codex"
    /// now — writes none of them; it keeps its threads here instead, with
    /// `source_kind = 'chatgpt'`. Watching only the rollouts meant the notch
    /// could never see the desktop app working at all.
    static var desktopStoreURL: URL {
        CodexProfile.default().desktopStoreURL
    }

    /// The most recently touched desktop thread: when, what it is called, and
    /// its id — which the desktop app shares with the `threads` table when the
    /// same conversation is also open in the CLI or VS Code, so the activity
    /// monitor can tell one conversation from two.
    static func newestDesktopThread(in url: URL)
    -> (title: String, updatedAt: Date, threadID: String)? {
        guard let db = SQLiteStore.open(url) else { return nil }
        defer { sqlite3_close(db) }

        let rows = SQLiteStore.rows(
            in: db,
            sql: """
            SELECT source_updated_at, '', thread_id
            FROM local_thread_catalog ORDER BY source_updated_at DESC LIMIT 1
            """,
            columns: 3
        )
        guard let row = rows.first, let seconds = Double(row[0]) else { return nil }
        // Seconds since the epoch, with a fractional part — not the
        // milliseconds the `threads` table next door uses.
        let title = row[1].isEmpty ? "Codex" : row[1]
        return (title, Date(timeIntervalSince1970: seconds), row[2])
    }

    /// The rollout of the most recently touched thread.
    static func newestRollout(in store: URL) -> URL? {
        guard let db = SQLiteStore.open(store) else { return nil }
        defer { sqlite3_close(db) }

        let paths = SQLiteStore.rows(
            in: db,
            sql: "SELECT rollout_path FROM threads WHERE archived = 0 ORDER BY updated_at_ms DESC LIMIT 8"
        )
        return paths
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The most recently touched threads, with what it takes to name them —
    /// plus every ancestor of a sub-agent among them, so a helper's work can be
    /// credited to the conversation that started it.
    ///
    /// Columns are asked for only when the table has them. `name` is recent,
    /// a store written by an older Codex does not have it, and a query naming a
    /// missing column fails outright — which would cost even the rollout path
    /// this monitor has always worked from.
    static func recentThreads(in store: URL, limit: Int = 24) -> [CodexThread] {
        guard let db = SQLiteStore.open(store) else { return [] }
        defer { sqlite3_close(db) }

        let present = Set(SQLiteStore.rows(
            in: db, sql: "SELECT name FROM pragma_table_info('threads')"))
        guard present.contains("rollout_path") else { return [] }
        func column(_ name: String) -> String { present.contains(name) ? name : "NULL" }

        // The scheduler only needs lifecycle and parent relationships, not titles/prompts/cwd.
        // `source` is plain text for a conversation ("vscode", "exec") and JSON
        // for a sub-agent, and `json_extract` on the plain kind is an error
        // rather than a NULL. Without an `id` a parent could never be matched,
        // so it is not worth reading.
        let parent = present.contains("source") && present.contains("id")
            ? "CASE WHEN json_valid(source) THEN json_extract(source, '$.subagent.thread_spawn.parent_thread_id') END"
            : "NULL"
        // Any sub-agent at all, whether or not `source` says whose it is. A
        // guardian — the helper auto-review runs to vet each action — is
        // recorded as `{"subagent":{"other":"guardian"}}`, with no parent, and
        // taking it for a conversation drew a row of its own that chimed
        // "Complete" after every review while the real request was mid-turn.
        let helper = present.contains("source")
            ? "CASE WHEN json_valid(source) THEN json_extract(source, '$.subagent') IS NOT NULL ELSE 0 END"
            : "0"
        let select = """
            SELECT \(column("id")), rollout_path, NULL, NULL, NULL, \
            \(parent), \(helper) FROM threads
            """
        let active = present.contains("archived") ? "WHERE archived = 0" : ""
        let order = present.contains("updated_at_ms") ? "updated_at_ms" : "rowid"

        var threads = SQLiteStore
            .rows(in: db, sql: "\(select) \(active) ORDER BY \(order) DESC LIMIT \(limit)",
                  columns: 7)
            .map(CodexThread.init(row:))
            .map(\.withParentFromRollout)

        // A sub-agent's parent is usually busy too, waiting on it, but it need
        // not be recent enough to have made the page above. Walk up and fetch
        // what is missing — a few levels at most; Codex nests helpers shallowly.
        guard present.contains("id") else { return threads }
        var known = Set(threads.map(\.id))
        for _ in 0..<4 {
            let missing = Set(threads.compactMap(\.parentID))
                .subtracting(known)
                .filter(CodexThread.isPlainID)
            guard !missing.isEmpty else { break }
            let list = missing.sorted().map { "'\($0)'" }.joined(separator: ",")
            let found = SQLiteStore
                .rows(in: db, sql: "\(select) WHERE id IN (\(list))", columns: 7)
                .map(CodexThread.init(row:))
                .map(\.withParentFromRollout)
            guard !found.isEmpty else { break }
            threads += found
            known.formUnion(found.map(\.id))
        }
        return threads
    }
}

/// One row of Codex's `threads` table — as much of it as naming a session takes.
struct CodexThread: Equatable {
    /// Empty on a store too old to have the column.
    let id: String
    let rollout: URL?
    /// Codex's own short name for the conversation — "Fix the flaky login
    /// test" — written a moment after the first turn. Nil until then, and nil
    /// for every thread `codex exec` starts, which Codex never names.
    let name: String?
    /// The opening of the first message: what is left to go on without a name.
    let preview: String?
    let cwd: String?
    /// The thread that spawned this one, when this one is a sub-agent.
    let parentID: String?
    /// Whether this thread is a sub-agent — a helper working *for* a
    /// conversation — even when nothing says which conversation.
    let isHelper: Bool

    /// What identifies the conversation when the store has no ids.
    var key: String { id.isEmpty ? (rollout?.path ?? "") : id }

    /// This thread, with its parent read from the rollout when it is a helper
    /// the store has no parent for.
    ///
    /// Every rollout opens with a `session_meta` line, and a sub-agent's names
    /// its parent — checked on a real machine for every guardian and every
    /// spawned helper. A guardian's `threads` row does not, so the rollout is
    /// the only place that says whose review it is. Read once per change of
    /// the store, and only for those threads.
    var withParentFromRollout: CodexThread {
        guard isHelper, parentID == nil, let rollout,
              let parent = Self.parent(fromRolloutHead: rollout)
        else { return self }
        return CodexThread(id: id, rollout: rollout, name: name, preview: preview,
                           cwd: cwd, parentID: parent, isHelper: isHelper)
    }

    /// The opening line is the session's whole configuration — tens of
    /// kilobytes on this machine, never near this. A file that has no newline
    /// by here is not a rollout worth reading further.
    static let longestHead = 512 * 1024

    static func parent(fromRolloutHead url: URL) -> String? {
        guard let handle = SQLiteStore.regularFile(url) else { return nil }
        defer { try? handle.close() }

        var head = Data()
        while head.count < longestHead {
            guard let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty else { break }
            if let newline = chunk.firstIndex(of: UInt8(ascii: "\n")) {
                head.append(chunk[chunk.startIndex..<newline])
                break
            }
            head.append(chunk)
        }
        guard let object = try? JSONSerialization.jsonObject(with: head) as? [String: Any],
              object["type"] as? String == "session_meta",
              let payload = object["payload"] as? [String: Any],
              let parent = payload["parent_thread_id"] as? String,
              isPlainID(parent)
        else { return nil }
        return parent
    }

    /// What to call this conversation on the notch.
    ///
    /// Codex's own name first, because it is the one a person gave or saw.
    /// Then the first line of what was asked, which is how the desktop app
    /// titles a thread before it has a name. Then the folder, which is all a
    /// Claude session falls back to as well. Only then the provider's name,
    /// which is what every Codex row used to say — "Codex", however many
    /// conversations were running and whatever each was about.
    func label(fallback: String) -> String {
        if let name { return name }
        if let line = preview.map(Self.request(in:)).flatMap(Self.firstLine) { return line }
        if let cwd {
            let folder = (cwd as NSString).lastPathComponent
            if !folder.isEmpty, folder != "/" { return folder }
        }
        return fallback
    }

    /// What the person asked, out of a preview that may open with context
    /// Codex added to it.
    ///
    /// Codex puts attached and mentioned files, and the in-app browser's
    /// state, *ahead* of the request — "# Files mentioned by the user:", a
    /// `<in-app-browser-context …>` block — and marks where the request itself
    /// begins with a `## My request` line. That marker is Codex's own, so it is
    /// what this goes by rather than guessing at which lines look like
    /// headings: a request that opens with a `#hashtag` is still the request.
    /// Numeric character references come through literally ("&#x20;Hi") and
    /// are decoded.
    static func request(in preview: String) -> String {
        var lines = decodingNumericReferences(preview)
            .split(whereSeparator: \.isNewline)
            .map(String.init)

        if let marker = lines.lastIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("## My request")
        }) {
            lines = Array(lines[(marker + 1)...])
        } else if let first = lines.firstIndex(where: {
                      !$0.trimmingCharacters(in: .whitespaces).isEmpty
                  }),
                  let tag = openingTag(lines[first]),
                  let close = lines[first...].firstIndex(where: {
                      $0.trimmingCharacters(in: .whitespaces).hasPrefix("</\(tag)")
                  }) {
            lines = Array(lines[(close + 1)...])
        }
        return lines.joined(separator: "\n")
    }

    /// `realtime_delegation` for a line that is `<realtime_delegation>` or
    /// `<in-app-browser-context source="…">`; nil for anything else.
    private static func openingTag(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("<"),
              let first = trimmed.dropFirst().first, first.isLetter
        else { return nil }
        let name = trimmed.dropFirst().prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        return name.isEmpty ? nil : String(name)
    }

    /// `&#x20;` and `&#32;` as the characters they stand for. Named entities
    /// are left alone: Codex was only ever seen passing the numeric ones.
    private static func decodingNumericReferences(_ text: String) -> String {
        guard text.contains("&#") else { return text }
        var out = ""
        var rest = Substring(text)
        while let start = rest.range(of: "&#") {
            out += rest[..<start.lowerBound]
            let after = rest[start.upperBound...]
            let isHex = after.first == "x" || after.first == "X"
            let digits = (isHex ? after.dropFirst() : after).prefix { $0.isHexDigit }
            let end = digits.endIndex
            if !digits.isEmpty, end < rest.endIndex, rest[end] == ";",
               let value = UInt32(digits, radix: isHex ? 16 : 10),
               let scalar = Unicode.Scalar(value) {
                out.unicodeScalars.append(scalar)
                rest = rest[rest.index(after: end)...]
            } else {
                out += "&#"
                rest = after
            }
        }
        return out + rest
    }

    /// A preview is a whole message, and a notch row is one line. Long enough
    /// to recognise a request by; the full text is one click away in Codex.
    static let longestPreview = 48

    static func firstLine(_ text: String) -> String? {
        guard let line = text.split(whereSeparator: \.isNewline)
            .lazy
            .map({ $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") })
            .first(where: { !$0.isEmpty })
        else { return nil }
        guard line.count > longestPreview else { return line }
        return line.prefix(longestPreview - 1)
            .trimmingCharacters(in: .whitespaces) + "…"
    }

    /// An id fit to put in a query: Codex's are UUIDs. The parent id comes out
    /// of JSON another program writes, so it is checked rather than trusted.
    static func isPlainID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64
            && id.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
            }
            && id.allSatisfy(\.isASCII)
    }
}

extension CodexThread {
    /// A row of the query `CodexStore.recentThreads` runs, NULLs read as "".
    init(row: [String]) {
        func text(_ index: Int) -> String? {
            let value = row[index].trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        self.init(
            id: row[0],
            rollout: text(1).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) },
            name: text(2),
            preview: text(3),
            cwd: text(4),
            parentID: text(5),
            isHelper: row.count > 6 && row[6] == "1"
        )
    }
}

/// One monitor's memory of the two Codex stores, so a tick where neither
/// database moved costs a handful of `stat`s rather than a SQLite open and
/// scan — `state_5.sqlite` alone runs to hundreds of megabytes, and the
/// monitor asks every two seconds.
///
/// Codex's writes land in the `-wal` file before the database proper — the
/// main file's mtime does not move until a checkpoint — so a database counts
/// as changed when either file's stamp does.
final class CodexStoreCache {
    private struct Stamp: Equatable {
        let modified: Date?
        let size: UInt64
    }

    private var rolloutStamp: Stamp?
    private var rollout: URL?
    private var desktopStamp: Stamp?
    private var desktop: (title: String, updatedAt: Date, threadID: String)?
    private var threadsStamp: Stamp?
    private var threads: [CodexThread] = []
    /// Each rollout's last answer from `CodexRolloutActivity.state`, by path,
    /// with the stamp it was read at.
    private var rolloutStates: [String: (stamp: Stamp, state: CodexRolloutActivity.State?)] = [:]

    /// `CodexStore.newestRollout`, or the last answer when the store has not
    /// changed. A cached path whose file has since gone away is asked for
    /// again — the next row down may still exist.
    func newestRollout(in store: URL) -> URL? {
        let stamp = Self.stamp(of: store)
        if stamp == rolloutStamp, let rollout,
           FileManager.default.fileExists(atPath: rollout.path) {
            return rollout
        }
        let found = CodexStore.newestRollout(in: store)
        rolloutStamp = stamp
        rollout = found
        return found
    }

    /// `CodexStore.newestDesktopThread`, or the last answer when the
    /// catalogue has not changed.
    func newestDesktopThread(in store: URL) -> (title: String, updatedAt: Date, threadID: String)? {
        let stamp = Self.stamp(of: store)
        if stamp == desktopStamp { return desktop }
        let found = CodexStore.newestDesktopThread(in: store)
        desktopStamp = stamp
        desktop = found
        return found
    }

    /// `CodexStore.recentThreads`, or the last answer while the store has not
    /// changed. Which threads exist changes rarely; whether one is *working*
    /// is decided from its rollout's own stamp on every tick, so holding the
    /// list costs no liveness.
    func recentThreads(in store: URL) -> [CodexThread] {
        let stamp = Self.stamp(of: store)
        if stamp == threadsStamp { return threads }
        threads = CodexStore.recentThreads(in: store)
        threadsStamp = stamp
        return threads
    }

    /// `CodexRolloutActivity.state`, parsed again only when the file has
    /// changed since the last parse.
    ///
    /// That parse walks up to a megabyte backwards and runs on the main actor.
    /// It used to happen for one rollout per tick; with a row per conversation
    /// it happens for every live one, every two seconds — measured at up to
    /// ~12 ms each on this machine — though a rollout that has not moved since
    /// the last tick cannot have a different answer in it.
    ///
    /// Entries for rollouts no longer asked about are dropped, so a long-lived
    /// app does not hold one per conversation it has ever seen.
    func rolloutState(of url: URL, keeping live: Set<String>) -> CodexRolloutActivity.State? {
        let stamp = Self.stamp(ofFile: url)
        if let held = rolloutStates[url.path], held.stamp == stamp {
            return held.state
        }
        let state = CodexRolloutActivity.state(from: url)
        rolloutStates = rolloutStates.filter { live.contains($0.key) }
        rolloutStates[url.path] = (stamp, state)
        return state
    }

    /// `(mtime, size)` of the database merged with its `-wal`, either of
    /// which moves first. A missing file contributes nothing — an absent
    /// store is also an answer worth remembering rather than re-paying for.
    private static func stamp(of url: URL) -> Stamp {
        func pair(_ url: URL) -> (Date?, UInt64) {
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            return (attributes?[.modificationDate] as? Date,
                    (attributes?[.size] as? NSNumber)?.uint64Value ?? 0)
        }
        let db = pair(url)
        let wal = pair(URL(fileURLWithPath: url.path + "-wal"))
        return Stamp(modified: [db.0, wal.0].compactMap { $0 }.max(),
                     size: db.1 + wal.1)
    }

    /// `(mtime, size)` of a plain file — a rollout, which has no `-wal`.
    private static func stamp(ofFile url: URL) -> Stamp {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return Stamp(modified: attributes?[.modificationDate] as? Date,
                     size: (attributes?[.size] as? NSNumber)?.uint64Value ?? 0)
    }
}

import Darwin
import Foundation

/// One agent session, whichever tool it belongs to.
///
/// Deliberately a *display* model rather than a mirror of any one tool's file
/// format: Claude Code publishes a session registry, Cursor keeps composer rows
/// in SQLite, and neither shape belongs in the notch. Each monitor does its own
/// parsing and hands back this.
struct AgentSession: Identifiable, Equatable {
    /// What the session is doing right now.
    enum State: Equatable {
        case busy
        case waiting
        case success
        case idle
    }

    let id: String
    /// What to call it in the tooltip.
    let name: String
    /// The quieter second line — where it is running, or what it is doing.
    let detail: String
    let state: State
    /// Set while `waiting`: what it wants from you.
    let waitingFor: String?
    /// When it entered its current state.
    let since: Date
    /// The agent's own process, when the tool publishes one.
    ///
    /// Only used to find the window it is running in — see `SessionFocus`.
    /// Nil for the tools that report activity from a database or a log file
    /// rather than from a process, and a nil here costs nothing but the ability
    /// to jump to that session.
    let processID: pid_t?

    /// Written out rather than synthesised so `processID` can default to nil:
    /// four of the five monitors have no pid to give, and a memberwise
    /// initialiser would have made every one of them say so.
    init(
        id: String,
        name: String,
        detail: String,
        state: State,
        waitingFor: String?,
        since: Date,
        processID: pid_t? = nil
    ) {
        self.id = id
        self.name = name
        self.detail = detail
        self.state = state
        self.waitingFor = waitingFor
        self.since = since
        self.processID = processID
    }
}

// Only the default account is supported by VitaPet's Codex cell. No extra profile discovery.
struct CodexProfile {
    let configDirectory: URL
    static func `default`() -> CodexProfile {
        CodexProfile(configDirectory: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"))
    }
    var id: String { "codex" }
    var displayName: String { "Codex" }
    var stateURL: URL { configDirectory.appendingPathComponent("state_5.sqlite") }
    var desktopStoreURL: URL { configDirectory.appendingPathComponent("sqlite/codex-dev.db") }
}
