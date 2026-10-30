import Foundation
import SQLite3

/// A value bound to a `?` placeholder.
enum SQLiteValue {
    case integer(Int64)
    case real(Double)
    case text(String)
    case null
}

struct SQLiteError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// One SQLite connection. A connection is not thread-safe, so every connection here is owned by exactly one queue:
/// `SettingsDatabase` gives the writer its own queue and hands out readers one per queue.
final class SQLiteConnection {
    private let handle: OpaquePointer

    init(path: String, readOnly: Bool) throws {
        var handle: OpaquePointer?
        // NOMUTEX: the caller guarantees single-threaded use, which saves SQLite's own locking on every call.
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) | SQLITE_OPEN_NOMUTEX
        let code = sqlite3_open_v2(path, &handle, flags, nil)
        guard code == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? String(cString: sqlite3_errstr(code))
            if let handle { sqlite3_close_v2(handle) }
            throw SQLiteError(message: "open \(path): \(message)")
        }
        self.handle = handle
        sqlite3_busy_timeout(handle, 3_000)
        // A reader never writes, even if a query is wrong: the pool exists to keep reads off the writer.
        if readOnly { try execute("PRAGMA query_only = ON") }
    }

    deinit { sqlite3_close_v2(handle) }

    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(handle, sql, nil, nil, &error)
        guard code == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errstr(code))
            sqlite3_free(error)
            throw SQLiteError(message: "\(sql): \(message)")
        }
    }

    @discardableResult
    func run(_ sql: String, _ bindings: [SQLiteValue] = []) throws -> Int {
        let statement = try prepare(sql)
        try statement.bind(bindings)
        while try statement.step() {}
        return Int(sqlite3_changes(handle))
    }

    func query<T>(_ sql: String, _ bindings: [SQLiteValue] = [], _ row: (SQLiteRow) throws -> T) throws -> [T] {
        let statement = try prepare(sql)
        try statement.bind(bindings)
        var rows: [T] = []
        while try statement.step() { rows.append(try row(SQLiteRow(handle: statement.handle))) }
        return rows
    }

    /// Runs `body` as one transaction on this connection. `BEGIN IMMEDIATE` takes the write lock up front, so two
    /// writers fail fast instead of deadlocking halfway through a read-then-write.
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

    private func prepare(_ sql: String) throws -> SQLiteStatement {
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else {
            throw SQLiteError(message: "prepare \(sql): \(String(cString: sqlite3_errmsg(handle)))")
        }
        return SQLiteStatement(handle: statement, sql: sql)
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class SQLiteStatement {
    let handle: OpaquePointer
    private let sql: String

    fileprivate init(handle: OpaquePointer, sql: String) {
        self.handle = handle
        self.sql = sql
    }

    deinit { sqlite3_finalize(handle) }

    func bind(_ values: [SQLiteValue]) throws {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch value {
            case .integer(let number): code = sqlite3_bind_int64(handle, index, number)
            case .real(let number): code = sqlite3_bind_double(handle, index, number)
            case .null: code = sqlite3_bind_null(handle, index)
            case .text(let text):
                code = text.withCString { sqlite3_bind_text(handle, index, $0, -1, sqliteTransient) }
            }
            guard code == SQLITE_OK else { throw SQLiteError(message: "bind \(index) in \(sql): \(String(cString: sqlite3_errmsg(sqlite3_db_handle(handle))))") }
        }
    }

    /// True when a row is ready, false when the statement is done.
    func step() throws -> Bool {
        switch sqlite3_step(handle) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        case let code:
            throw SQLiteError(message: "step \(sql): \(String(cString: sqlite3_errstr(code)))")
        }
    }
}

struct SQLiteRow {
    let handle: OpaquePointer

    func int(_ index: Int32) -> Int64 { sqlite3_column_int64(handle, index) }
    func bool(_ index: Int32) -> Bool { int(index) != 0 }
    func double(_ index: Int32) -> Double { sqlite3_column_double(handle, index) }

    func string(_ index: Int32) -> String? {
        guard let text = sqlite3_column_text(handle, index) else { return nil }
        return String(cString: text)
    }

    func optionalInt(_ index: Int32) -> Int? {
        guard sqlite3_column_type(handle, index) != SQLITE_NULL else { return nil }
        return Int(int(index))
    }
}
