import Foundation
import SQLite3

public enum AppDataError: LocalizedError {
  case unreadable(app: String, reason: String)
  case unsupportedSchema(app: String, reason: String)
  case queryFailed(app: String, reason: String)

  public var errorDescription: String? {
    switch self {
    case .unreadable(let app, let reason):
      return
        "Cannot read \(app) data (\(reason)). Allow access to the \(app) folder; macOS may also require Full Disk Access."
    case .unsupportedSchema(let app, let reason):
      return "This version of the \(app) database is not supported (\(reason))."
    case .queryFailed(let app, let reason): return "Cannot read \(app) data (\(reason))."
    }
  }
}

/// A read-only connection to a database that another app keeps writing, such as Messages'
/// chat.db. Opening never creates the database or changes its journal mode, and each query sees
/// the latest committed rows.
final class ReadOnlyDatabase {
  private let database: OpaquePointer
  private let app: String
  private let isCancelled: () -> Bool

  /// Opening reads nothing, so this compiles `queries` now. Missing access or an unknown schema
  /// then fails here rather than partway through a command.
  init(path: String, app: String, queries: [String], isCancelled: @escaping () -> Bool) throws {
    var handle: OpaquePointer?
    var status = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil)
    for query in queries where status == SQLITE_OK {
      var statement: OpaquePointer?
      status = sqlite3_prepare_v2(handle, query, -1, &statement, nil)
      sqlite3_finalize(statement)
    }
    guard status == SQLITE_OK, let handle else {
      let reason = String(cString: sqlite3_errmsg(handle))
      sqlite3_close(handle)
      throw status == SQLITE_ERROR
        ? AppDataError.unsupportedSchema(app: app, reason: reason)
        : .unreadable(app: app, reason: reason)
    }
    database = handle
    self.app = app
    self.isCancelled = isCancelled
    sqlite3_busy_timeout(handle, 1_000)
    // Interrupts long scans once the command is cancelled.
    sqlite3_progress_handler(
      handle, 1_000,
      { context in
        guard let context else { return 0 }
        return Unmanaged<ReadOnlyDatabase>.fromOpaque(context).takeUnretainedValue().isCancelled()
          ? 1 : 0
      }, Unmanaged.passUnretained(self).toOpaque())
  }

  deinit { sqlite3_close(database) }

  /// The caller finalizes the statement.
  func prepare(_ query: String) throws -> OpaquePointer {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK, let statement
    else {
      sqlite3_finalize(statement)
      throw AppDataError.queryFailed(app: app, reason: String(cString: sqlite3_errmsg(database)))
    }
    return statement
  }

  /// Returns true for a row and false when done.
  func step(_ statement: OpaquePointer) throws -> Bool {
    guard !isCancelled() else { throw AppleUtilityError.cancelled }
    switch sqlite3_step(statement) {
    case SQLITE_ROW: return true
    case SQLITE_DONE: return false
    case SQLITE_INTERRUPT: throw AppleUtilityError.cancelled
    default:
      throw AppDataError.queryFailed(app: app, reason: String(cString: sqlite3_errmsg(database)))
    }
  }
}

/// Text in a result column; nil for NULL.
func columnText(_ statement: OpaquePointer, _ column: Int32) -> String? {
  guard let bytes = sqlite3_column_text(statement, column) else { return nil }
  let count = Int(sqlite3_column_bytes(statement, column))
  return String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
}
