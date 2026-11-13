import Foundation
import SQLite3
import ZoroCore

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// File protection class for the index file (honoured on iOS; ignored on macOS).
public enum IndexFileProtection: Sendable {
    /// Readable only while the device is unlocked (design spec default).
    case complete
    /// Stays readable while open, so an indexing pass can finish after the device locks.
    case completeUnlessOpen
}

/// Minimal wrapper over the system SQLite library. Not thread-safe: owned by one actor.
final class SQLiteConnection {
    enum Value: Equatable {
        case text(String)
        case blob(Data)
        case double(Double)
        case int(Int64)
        case null

        var string: String? { if case .text(let s) = self { s } else { nil } }
        var double: Double? {
            switch self {
            case .double(let d): d
            case .int(let i): Double(i)
            default: nil
            }
        }
        var int: Int64? {
            switch self {
            case .int(let i): i
            case .double(let d): Int64(d)
            default: nil
            }
        }
        var data: Data? { if case .blob(let d) = self { d } else { nil } }

        static func optional(_ d: Double?) -> Value { d.map(Value.double) ?? .null }
        static func optional(_ s: String?) -> Value { s.map(Value.text) ?? .null }
        static func optional(_ d: Data?) -> Value { d.map(Value.blob) ?? .null }
    }

    private var handle: OpaquePointer?

    /// `path` nil opens a private in-memory database (tests).
    init(path: String?, protection: IndexFileProtection = .complete) throws {
        var flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        if path != nil {
            // On a Mac a "complete" file cannot be opened while the screen is locked, and the
            // index is rebuilt in the background: use "until first unlock" there.
            #if !os(iOS)
            flags |= SQLITE_OPEN_FILEPROTECTION_COMPLETEUNTILFIRSTUSERAUTHENTICATION
            #else
            switch protection {
            case .complete: flags |= SQLITE_OPEN_FILEPROTECTION_COMPLETE
            case .completeUnlessOpen: flags |= SQLITE_OPEN_FILEPROTECTION_COMPLETEUNLESSOPEN
            }
            #endif
        }
        guard sqlite3_open_v2(path ?? ":memory:", &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            handle = nil
            throw ZoroError.storage(message)
        }
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    private var db: OpaquePointer {
        get throws {
            guard let handle else { throw ZoroError.storage("database is closed") }
            return handle
        }
    }

    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(try db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(error)
            throw ZoroError.storage(message)
        }
    }

    /// Runs one statement and returns all rows.
    @discardableResult
    func query(_ sql: String, _ params: [Value] = []) throws -> [[Value]] {
        var rows: [[Value]] = []
        try forEachRow(sql, params) { rows.append($0) }
        return rows
    }

    /// Streams rows without holding them all in memory (embedding scans).
    func forEachRow(_ sql: String, _ params: [Value] = [], _ body: ([Value]) throws -> Void) throws {
        let db = try db
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ZoroError.storage(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        for (i, value) in params.enumerated() {
            let index = Int32(i + 1)
            let rc: Int32
            switch value {
            case .text(let s): rc = sqlite3_bind_text(stmt, index, s, -1, SQLITE_TRANSIENT)
            case .blob(let d):
                rc = d.withUnsafeBytes { sqlite3_bind_blob(stmt, index, $0.baseAddress, Int32(d.count), SQLITE_TRANSIENT) }
            case .double(let v): rc = sqlite3_bind_double(stmt, index, v)
            case .int(let v): rc = sqlite3_bind_int64(stmt, index, v)
            case .null: rc = sqlite3_bind_null(stmt, index)
            }
            guard rc == SQLITE_OK else { throw ZoroError.storage(String(cString: sqlite3_errmsg(db))) }
        }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw ZoroError.storage(String(cString: sqlite3_errmsg(db))) }
            let columns = sqlite3_column_count(stmt)
            var row: [Value] = []
            row.reserveCapacity(Int(columns))
            for c in 0..<columns {
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: row.append(.int(sqlite3_column_int64(stmt, c)))
                case SQLITE_FLOAT: row.append(.double(sqlite3_column_double(stmt, c)))
                case SQLITE_TEXT: row.append(.text(String(cString: sqlite3_column_text(stmt, c))))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(stmt, c))
                    if let pointer = sqlite3_column_blob(stmt, c), count > 0 {
                        row.append(.blob(Data(bytes: pointer, count: count)))
                    } else {
                        row.append(.blob(Data()))
                    }
                default: row.append(.null)
                }
            }
            try body(row)
        }
    }

    var lastInsertRowID: Int64 { handle.map { sqlite3_last_insert_rowid($0) } ?? 0 }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
}
