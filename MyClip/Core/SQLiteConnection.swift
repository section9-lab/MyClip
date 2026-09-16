import Foundation
import SQLite3

// Owned by LibraryStore. FULLMUTEX also protects connection teardown.
final class SQLiteConnection: @unchecked Sendable {
    private let handle: OpaquePointer

    init(url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开数据库"
            if let database { sqlite3_close(database) }
            throw LibraryError.database(message)
        }
        handle = database
        sqlite3_busy_timeout(handle, 5_000)
    }

    deinit { sqlite3_close(handle) }

    func script(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &message) == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
            sqlite3_free(message)
            throw LibraryError.database(text)
        }
    }

    @discardableResult
    func run(_ sql: String, _ arguments: [String?] = []) throws -> [[String: String]] {
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &prepared, nil) == SQLITE_OK, let statement = prepared else {
            throw LibraryError.database(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        for (index, argument) in arguments.enumerated() {
            let result: Int32
            if let argument {
                result = argument.withCString {
                    sqlite3_bind_text(statement, Int32(index + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
            } else {
                result = sqlite3_bind_null(statement, Int32(index + 1))
            }
            guard result == SQLITE_OK else { throw LibraryError.database(String(cString: sqlite3_errmsg(handle))) }
        }
        var rows: [[String: String]] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW else { throw LibraryError.database(String(cString: sqlite3_errmsg(handle))) }
            var row: [String: String] = [:]
            for column in 0..<sqlite3_column_count(statement) {
                if let value = sqlite3_column_text(statement, column) {
                    row[String(cString: sqlite3_column_name(statement, column))] = String(cString: value)
                }
            }
            rows.append(row)
        }
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try script("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try script("COMMIT")
            return result
        } catch {
            try? script("ROLLBACK")
            throw error
        }
    }
}
