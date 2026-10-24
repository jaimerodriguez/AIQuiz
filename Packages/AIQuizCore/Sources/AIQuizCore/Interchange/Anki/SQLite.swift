import Foundation
import SQLite3

/// A minimal SQLite connection for reading and writing Anki collections. One connection is
/// used by one task from open to close.
final class SQLiteDatabase {
    enum Value: Equatable {
        case int(Int64)
        case double(Double)
        case text(String)
        case blob(Data)
        case null

        var int: Int64 {
            switch self {
            case .int(let v): return v
            case .double(let v): return Int64(v)
            case .text(let s): return Int64(s) ?? 0
            default: return 0
            }
        }

        var text: String {
            switch self {
            case .text(let s): return s
            case .int(let v): return String(v)
            case .double(let v): return String(v)
            case .blob(let d): return String(decoding: d, as: UTF8.self)
            case .null: return ""
            }
        }

        var blob: Data {
            switch self {
            case .blob(let d): return d
            case .text(let s): return Data(s.utf8)
            default: return Data()
            }
        }
    }

    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { "The Anki collection couldn't be read (\(message))." }
    }

    private var db: OpaquePointer?

    init(path: String) throws {
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            throw Failure(message: message)
        }
        // Current Anki tables sort names with a `unicase` collation; SQLite refuses to read
        // them unless one is registered. Case-insensitive comparison is what it means.
        sqlite3_create_collation_v2(db, "unicase", SQLITE_UTF8, nil, { _, lengthA, a, lengthB, b in
            let left = String(decoding: UnsafeRawBufferPointer(start: a, count: Int(lengthA)), as: UTF8.self).lowercased()
            let right = String(decoding: UnsafeRawBufferPointer(start: b, count: Int(lengthB)), as: UTF8.self).lowercased()
            return left < right ? -1 : (left == right ? 0 : 1)
        }, nil)
    }

    deinit {
        sqlite3_close(db)
    }

    func tableExists(_ name: String) throws -> Bool {
        try query("select count(*) from sqlite_master where type = 'table' and name = ?", [.text(name)]).first?.first?.int == 1
    }

    func query(_ sql: String, _ arguments: [Value] = []) throws -> [[Value]] {
        let statement = try prepare(sql, arguments)
        defer { sqlite3_finalize(statement) }
        var rows: [[Value]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw Failure(message: String(cString: sqlite3_errmsg(db))) }
            rows.append((0..<sqlite3_column_count(statement)).map { column in
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: return .int(sqlite3_column_int64(statement, column))
                case SQLITE_FLOAT: return .double(sqlite3_column_double(statement, column))
                case SQLITE_TEXT: return .text(String(cString: sqlite3_column_text(statement, column)))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, column))
                    guard count > 0, let bytes = sqlite3_column_blob(statement, column) else { return .blob(Data()) }
                    return .blob(Data(bytes: bytes, count: count))
                default: return .null
                }
            })
        }
        return rows
    }

    func execute(_ sql: String, _ arguments: [Value] = []) throws {
        if arguments.isEmpty {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw Failure(message: String(cString: sqlite3_errmsg(db))) }
            return
        }
        let statement = try prepare(sql, arguments)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw Failure(message: String(cString: sqlite3_errmsg(db))) }
    }

    private func prepare(_ sql: String, _ arguments: [Value]) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw Failure(message: String(cString: sqlite3_errmsg(db)))
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, argument) in arguments.enumerated() {
            let position = Int32(index + 1)
            switch argument {
            case .int(let v): sqlite3_bind_int64(statement, position, v)
            case .double(let v): sqlite3_bind_double(statement, position, v)
            case .text(let s): sqlite3_bind_text(statement, position, s, -1, transient)
            case .blob(let d): _ = d.withUnsafeBytes { sqlite3_bind_blob(statement, position, $0.baseAddress, Int32(d.count), transient) }
            case .null: sqlite3_bind_null(statement, position)
            }
        }
        return statement
    }
}
