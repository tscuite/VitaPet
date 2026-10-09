// CodeNotch 1.20.0 / 6e8b0f8 SQLiteStore (MIT), with VitaPet bounded/nonblocking IO gates.
import Foundation
import SQLite3
import Darwin

/// Read-only access to another app's SQLite store.
///
/// Both Cursor and Codex keep their state this way, and both run it in WAL mode,
/// which makes opening it more delicate than it looks:
///
/// - `immutable=1` tells SQLite to ignore the write-ahead log entirely, so a
///   running app's most recent writes are invisible. That is how a live agent
///   looks idle and a rotated token looks current.
/// - `mode=ro` sees the log, but needs the `-shm` sidecar to do it — and that
///   file exists only *while the owning app is running*. Once it has quit and
///   checkpointed, a read-only open fails outright with "unable to open
///   database file".
///
/// So: `mode=ro` first, `immutable=1` second. The fallback is only ever reached
/// when there is no write-ahead log left to miss, which is exactly when ignoring
/// it costs nothing.
enum SQLiteStore {
    static func regularFile(_ url: URL) -> FileHandle? {
        let fd = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            close(fd); return nil
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    static func open(_ url: URL) -> OpaquePointer? {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        let hasWAL = FileManager.default.fileExists(atPath: url.path + "-wal")
        for query in hasWAL ? ["mode=ro"] : ["mode=ro", "immutable=1"] {
            var db: OpaquePointer?
            if sqlite3_open_v2("\(url.absoluteString)?\(query)", &db,
                               SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
               let db {
                sqlite3_busy_timeout(db, 200)
                sqlite3_limit(db, SQLITE_LIMIT_LENGTH, Int32(UsageCredentials.maxBytes))
                sqlite3_progress_handler(db, 100_000, { _ in 1 }, nil)
                return db
            }
            sqlite3_close(db)
        }
        return nil
    }

    /// Every column of every row, as text. Needed where one row carries more
    /// than one fact — a thread's title *and* when it was last touched — and
    /// two queries would be two chances for them to disagree.
    static func rows(in db: OpaquePointer?, sql: String, columns: Int) -> [[String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        var out: [[String]] = []
        while out.count < 256 && sqlite3_step(statement) == SQLITE_ROW {
            var row: [String] = []
            for index in 0..<Int32(columns) {
                row.append(sqlite3_column_text(statement, index).map { String(cString: $0) } ?? "")
            }
            out.append(row)
        }
        return out
    }

    /// First column of every row, as text.
    static func rows(in db: OpaquePointer?, sql: String, bind: String? = nil) -> [String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        if let bind {
            sqlite3_bind_text(statement, 1, bind, -1,
                              unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        var out: [String] = []
        while out.count < 256 && sqlite3_step(statement) == SQLITE_ROW {
            if let raw = sqlite3_column_text(statement, 0) { out.append(String(cString: raw)) }
        }
        return out
    }
}
