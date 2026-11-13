import Foundation
import SQLite3
import ZoroCore

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Minimal wrapper over the system SQLite library. Not thread-safe: owned by one actor.
final class SQLiteDatabase {
    private var handle: OpaquePointer?

    init(url: URL) throws {
        var flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        // Data protection for the database and its journals. iPhone: complete (unreadable while
        // locked). Mac: until first unlock, because the companion keeps working behind a locked
        // screen and a "complete" file cannot even be opened there while locked.
        #if os(iOS)
        flags |= SQLITE_OPEN_FILEPROTECTION_COMPLETE
        #else
        flags |= SQLITE_OPEN_FILEPROTECTION_COMPLETEUNTILFIRSTUSERAUTHENTICATION
        #endif
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            handle = nil
            throw ZoroError.storage(message)
        }
    }

    deinit { close() }

    func close() {
        if let handle { sqlite3_close_v2(handle) }
        handle = nil
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

    enum Value {
        case text(String)
        case blob(Data)
        case double(Double)
        case int(Int64)
        case null
    }

    /// Runs a statement; returns rows as arrays of column values.
    @discardableResult
    func query(_ sql: String, _ params: [Value] = []) throws -> [[Value]] {
        let db = try db
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ZoroError.storage(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        for (i, param) in params.enumerated() {
            let index = Int32(i + 1)
            let rc: Int32
            switch param {
            case .text(let s): rc = sqlite3_bind_text(stmt, index, s, -1, SQLITE_TRANSIENT)
            case .blob(let d):
                rc = d.withUnsafeBytes { sqlite3_bind_blob(stmt, index, $0.baseAddress, Int32(d.count), SQLITE_TRANSIENT) }
            case .double(let v): rc = sqlite3_bind_double(stmt, index, v)
            case .int(let v): rc = sqlite3_bind_int64(stmt, index, v)
            case .null: rc = sqlite3_bind_null(stmt, index)
            }
            guard rc == SQLITE_OK else { throw ZoroError.storage(String(cString: sqlite3_errmsg(db))) }
        }
        var rows: [[Value]] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw ZoroError.storage(String(cString: sqlite3_errmsg(db))) }
            var row: [Value] = []
            for c in 0..<sqlite3_column_count(stmt) {
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_TEXT: row.append(.text(String(cString: sqlite3_column_text(stmt, c))))
                case SQLITE_BLOB:
                    let n = Int(sqlite3_column_bytes(stmt, c))
                    row.append(.blob(n == 0 ? Data() : Data(bytes: sqlite3_column_blob(stmt, c), count: n)))
                case SQLITE_FLOAT: row.append(.double(sqlite3_column_double(stmt, c)))
                case SQLITE_INTEGER: row.append(.int(sqlite3_column_int64(stmt, c)))
                default: row.append(.null)
                }
            }
            rows.append(row)
        }
        return rows
    }

    var changes: Int { (try? db).map { Int(sqlite3_changes($0)) } ?? 0 }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
}

extension SQLiteDatabase.Value {
    var text: String? { if case .text(let s) = self { s } else { nil } }
    var blob: Data? { if case .blob(let d) = self { d } else { nil } }
    var double: Double? {
        switch self {
        case .double(let v): v
        case .int(let v): Double(v)
        default: nil
        }
    }
    var int: Int? { if case .int(let v) = self { Int(v) } else { nil } }
}
