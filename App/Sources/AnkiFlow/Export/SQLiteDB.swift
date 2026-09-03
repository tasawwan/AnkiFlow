import Foundation
import SQLite3

enum SQLValue {
    case int(Int64)
    case text(String)
    case null
}

enum SQLiteError: LocalizedError {
    case open(String)
    case step(String)

    var errorDescription: String? {
        switch self {
        case .open(let message): return "Could not create the collection database: \(message)"
        case .step(let message): return "Database error while writing the deck: \(message)"
        }
    }
}

/// A very small sqlite3 wrapper -- just enough to write a collection.anki2.
/// Uses the system SQLite, so the app has no external dependencies at all.
final class SQLiteDB {
    private var handle: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        if sqlite3_open(path, &handle) != SQLITE_OK {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw SQLiteError.open(message)
        }
    }

    deinit {
        if let handle { sqlite3_close(handle) }
    }

    func execute(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &errorPointer) != SQLITE_OK {
            let message = errorPointer.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errorPointer)
            throw SQLiteError.step(message)
        }
    }

    func run(_ sql: String, _ values: [SQLValue]) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError.step(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }

        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .int(let number):
                sqlite3_bind_int64(statement, index, number)
            case .text(let string):
                sqlite3_bind_text(statement, index, string, -1, Self.transient)
            case .null:
                sqlite3_bind_null(statement, index)
            }
        }

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteError.step(String(cString: sqlite3_errmsg(handle)))
        }
    }

    func close() {
        if let handle { sqlite3_close(handle) }
        handle = nil
    }
}
