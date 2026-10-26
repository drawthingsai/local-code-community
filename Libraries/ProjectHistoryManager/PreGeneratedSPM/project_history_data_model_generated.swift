import Dflat
import FlatBuffers
import Foundation
import SQLite3
import SQLiteDflat

public enum ProjectHistoryRole: Int8, DflatFriendlyValue, CaseIterable {
  case user = 0
  case assistant = 1
  case memory = 2
  public static func < (lhs: ProjectHistoryRole, rhs: ProjectHistoryRole) -> Bool {
    return lhs.rawValue < rhs.rawValue
  }
}

public enum EmbedKind: UInt8, DflatFriendlyValue, CaseIterable {
  case image = 0
  case audio = 1
  case video = 2
  public static func < (lhs: EmbedKind, rhs: EmbedKind) -> Bool {
    return lhs.rawValue < rhs.rawValue
  }
}

public struct MemoryContext: Equatable, FlatBuffersDecodable {
  public var user: String?
  public var memory: String?
  public init(user: String? = nil, memory: String? = nil) {
    self.user = user ?? nil
    self.memory = memory ?? nil
  }
  public init(_ obj: zzz_DflatGen_MemoryContext) {
    self.user = obj.user
    self.memory = obj.memory
  }

  public static func from(byteBuffer bb: ByteBuffer) -> Self {
    Self(zzz_DflatGen_MemoryContext.getRootAsMemoryContext(bb: bb))
  }

  public static func verify(byteBuffer bb: ByteBuffer) -> Bool {
    do {
      var bb = bb
      var verifier = try Verifier(buffer: &bb)
      try ForwardOffset<zzz_DflatGen_MemoryContext>.verify(
        &verifier, at: 0, of: zzz_DflatGen_MemoryContext.self)
      return true
    } catch {
      return false
    }
  }

  public static var flatBuffersSchemaVersion: String? {
    return nil
  }
}

public struct ToolCallParameter: Equatable, FlatBuffersDecodable {
  public var name: String?
  public var value: String?
  public init(name: String? = nil, value: String? = nil) {
    self.name = name ?? nil
    self.value = value ?? nil
  }
  public init(_ obj: zzz_DflatGen_ToolCallParameter) {
    self.name = obj.name
    self.value = obj.value
  }

  public static func from(byteBuffer bb: ByteBuffer) -> Self {
    Self(zzz_DflatGen_ToolCallParameter.getRootAsToolCallParameter(bb: bb))
  }

  public static func verify(byteBuffer bb: ByteBuffer) -> Bool {
    do {
      var bb = bb
      var verifier = try Verifier(buffer: &bb)
      try ForwardOffset<zzz_DflatGen_ToolCallParameter>.verify(
        &verifier, at: 0, of: zzz_DflatGen_ToolCallParameter.self)
      return true
    } catch {
      return false
    }
  }

  public static var flatBuffersSchemaVersion: String? {
    return nil
  }
}

public struct ToolCall: Equatable, FlatBuffersDecodable {
  public var function: String?
  public var parameters: [ToolCallParameter]
  public var reason: String?
  public init(function: String? = nil, parameters: [ToolCallParameter]? = [], reason: String? = nil)
  {
    self.function = function ?? nil
    self.parameters = parameters ?? []
    self.reason = reason ?? nil
  }
  public init(_ obj: zzz_DflatGen_ToolCall) {
    self.function = obj.function
    var __parameters = [ToolCallParameter]()
    for i: Int32 in 0..<obj.parametersCount {
      guard let o = obj.parameters(at: i) else { break }
      __parameters.append(ToolCallParameter(o))
    }
    self.parameters = __parameters
    self.reason = obj.reason
  }

  public static func from(byteBuffer bb: ByteBuffer) -> Self {
    Self(zzz_DflatGen_ToolCall.getRootAsToolCall(bb: bb))
  }

  public static func verify(byteBuffer bb: ByteBuffer) -> Bool {
    do {
      var bb = bb
      var verifier = try Verifier(buffer: &bb)
      try ForwardOffset<zzz_DflatGen_ToolCall>.verify(
        &verifier, at: 0, of: zzz_DflatGen_ToolCall.self)
      return true
    } catch {
      return false
    }
  }

  public static var flatBuffersSchemaVersion: String? {
    return nil
  }
}

public struct EmbedSpan: Equatable, FlatBuffersDecodable {
  public var start: Int64
  public var length: Int64
  public var digest: [UInt8]
  public var kind: EmbedKind
  public init(
    start: Int64? = 0, length: Int64? = 0, digest: [UInt8]? = [], kind: EmbedKind? = .image
  ) {
    self.start = start ?? 0
    self.length = length ?? 0
    self.digest = digest ?? []
    self.kind = kind ?? .image
  }
  public init(_ obj: zzz_DflatGen_EmbedSpan) {
    self.start = obj.start
    self.length = obj.length
    self.digest = obj.digest
    self.kind = EmbedKind(rawValue: obj.kind.rawValue) ?? .image
  }

  public static func from(byteBuffer bb: ByteBuffer) -> Self {
    Self(zzz_DflatGen_EmbedSpan.getRootAsEmbedSpan(bb: bb))
  }

  public static func verify(byteBuffer bb: ByteBuffer) -> Bool {
    do {
      var bb = bb
      var verifier = try Verifier(buffer: &bb)
      try ForwardOffset<zzz_DflatGen_EmbedSpan>.verify(
        &verifier, at: 0, of: zzz_DflatGen_EmbedSpan.self)
      return true
    } catch {
      return false
    }
  }

  public static var flatBuffersSchemaVersion: String? {
    return nil
  }
}

public final class ProjectHistoryNode: Dflat.Atom, SQLiteDflat.SQLiteAtom, FlatBuffersDecodable,
  Equatable
{
  public static func == (lhs: ProjectHistoryNode, rhs: ProjectHistoryNode) -> Bool {
    guard lhs.threadId == rhs.threadId else { return false }
    guard lhs.datetime == rhs.datetime else { return false }
    guard lhs.role == rhs.role else { return false }
    guard lhs.logTokens == rhs.logTokens else { return false }
    guard lhs.tokens == rhs.tokens else { return false }
    guard lhs.toolCalls == rhs.toolCalls else { return false }
    guard lhs.textEdits == rhs.textEdits else { return false }
    guard lhs.textLineage == rhs.textLineage else { return false }
    guard lhs.plaintext == rhs.plaintext else { return false }
    guard lhs.logPlaintext == rhs.logPlaintext else { return false }
    guard lhs.compacted == rhs.compacted else { return false }
    guard lhs.duration == rhs.duration else { return false }
    guard lhs.embedSpans == rhs.embedSpans else { return false }
    guard lhs.memoryContext == rhs.memoryContext else { return false }
    guard lhs.systemSeenMemoryContext == rhs.systemSeenMemoryContext else { return false }
    guard lhs.imagePaths == rhs.imagePaths else { return false }
    return true
  }
  public var _rowid: Int64 = -1
  public var _changesTimestamp: Int64 = -1
  public let threadId: Int64
  public let datetime: Int64
  public let role: ProjectHistoryRole
  public let logTokens: [Int32]
  public let tokens: [Int32]
  public let toolCalls: [ToolCall]
  public let textEdits: Int64
  public let textLineage: Int64
  public let plaintext: String?
  public let logPlaintext: String?
  public let compacted: Bool
  public let duration: Double
  public let embedSpans: [EmbedSpan]
  public let memoryContext: MemoryContext?
  public let systemSeenMemoryContext: MemoryContext?
  public let imagePaths: [String]
  public init(
    threadId: Int64, datetime: Int64, role: ProjectHistoryRole? = .user, logTokens: [Int32]? = [],
    tokens: [Int32]? = [], toolCalls: [ToolCall]? = [], textEdits: Int64? = -1,
    textLineage: Int64? = -1, plaintext: String? = nil, logPlaintext: String? = nil,
    compacted: Bool? = false, duration: Double? = 0.0, embedSpans: [EmbedSpan]? = [],
    memoryContext: MemoryContext? = nil, systemSeenMemoryContext: MemoryContext? = nil,
    imagePaths: [String]? = []
  ) {
    self.threadId = threadId
    self.datetime = datetime
    self.role = role ?? .user
    self.logTokens = logTokens ?? []
    self.tokens = tokens ?? []
    self.toolCalls = toolCalls ?? []
    self.textEdits = textEdits ?? -1
    self.textLineage = textLineage ?? -1
    self.plaintext = plaintext ?? nil
    self.logPlaintext = logPlaintext ?? nil
    self.compacted = compacted ?? false
    self.duration = duration ?? 0.0
    self.embedSpans = embedSpans ?? []
    self.memoryContext = memoryContext ?? nil
    self.systemSeenMemoryContext = systemSeenMemoryContext ?? nil
    self.imagePaths = imagePaths ?? []
  }
  public init(_ obj: zzz_DflatGen_ProjectHistoryNode) {
    self.threadId = obj.threadId
    self.datetime = obj.datetime
    self.role = ProjectHistoryRole(rawValue: obj.role.rawValue) ?? .user
    self.logTokens = obj.logTokens
    self.tokens = obj.tokens
    var __toolCalls = [ToolCall]()
    for i: Int32 in 0..<obj.toolCallsCount {
      guard let o = obj.toolCalls(at: i) else { break }
      __toolCalls.append(ToolCall(o))
    }
    self.toolCalls = __toolCalls
    self.textEdits = obj.textEdits
    self.textLineage = obj.textLineage
    self.plaintext = obj.plaintext
    self.logPlaintext = obj.logPlaintext
    self.compacted = obj.compacted
    self.duration = obj.duration
    var __embedSpans = [EmbedSpan]()
    for i: Int32 in 0..<obj.embedSpansCount {
      guard let o = obj.embedSpans(at: i) else { break }
      __embedSpans.append(EmbedSpan(o))
    }
    self.embedSpans = __embedSpans
    self.memoryContext = obj.memoryContext.map { MemoryContext($0) }
    self.systemSeenMemoryContext = obj.systemSeenMemoryContext.map { MemoryContext($0) }
    var __imagePaths = [String]()
    for i: Int32 in 0..<obj.imagePathsCount {
      guard let o = obj.imagePaths(at: i) else { break }
      __imagePaths.append(String(o))
    }
    self.imagePaths = __imagePaths
  }
  public static func from(data: Data) -> Self {
    return data.withUnsafeBytes { buffer in
      let bb = ByteBuffer(
        assumingMemoryBound: UnsafeMutableRawPointer(mutating: buffer.baseAddress!),
        capacity: buffer.count)
      return Self(zzz_DflatGen_ProjectHistoryNode.getRootAsProjectHistoryNode(bb: bb))
    }
  }
  public static func from(byteBuffer bb: ByteBuffer) -> Self {
    Self(zzz_DflatGen_ProjectHistoryNode.getRootAsProjectHistoryNode(bb: bb))
  }
  public static func verify(byteBuffer bb: ByteBuffer) -> Bool {
    do {
      var bb = bb
      var verifier = try Verifier(buffer: &bb)
      try ForwardOffset<zzz_DflatGen_ProjectHistoryNode>.verify(
        &verifier, at: 0, of: zzz_DflatGen_ProjectHistoryNode.self)
      return true
    } catch {
      return false
    }
  }
  public static var flatBuffersSchemaVersion: String? {
    return nil
  }
  public static var table: String { "projecthistorynode" }
  public static var indexFields: [String] { [] }
  public static func setUpSchema(_ toolbox: PersistenceToolbox) {
    guard let sqlite = ((toolbox as? SQLitePersistenceToolbox).map { $0.connection }) else {
      return
    }
    sqlite3_exec(
      sqlite.sqlite,
      "CREATE TABLE IF NOT EXISTS projecthistorynode (rowid INTEGER PRIMARY KEY AUTOINCREMENT, __pk0 INTEGER, __pk1 INTEGER, p BLOB, UNIQUE(__pk0, __pk1))",
      nil, nil, nil)
  }
  public static func insertIndex(
    _ toolbox: PersistenceToolbox, field: String, rowid: Int64, table: ByteBuffer
  ) -> Bool {
    return true
  }
}

public struct ProjectHistoryNodeBuilder {
  public var threadId: Int64
  public var datetime: Int64
  public var role: ProjectHistoryRole
  public var logTokens: [Int32]
  public var tokens: [Int32]
  public var toolCalls: [ToolCall]
  public var textEdits: Int64
  public var textLineage: Int64
  public var plaintext: String?
  public var logPlaintext: String?
  public var compacted: Bool
  public var duration: Double
  public var embedSpans: [EmbedSpan]
  public var memoryContext: MemoryContext?
  public var systemSeenMemoryContext: MemoryContext?
  public var imagePaths: [String]
  public init(from object: ProjectHistoryNode) {
    threadId = object.threadId
    datetime = object.datetime
    role = object.role
    logTokens = object.logTokens
    tokens = object.tokens
    toolCalls = object.toolCalls
    textEdits = object.textEdits
    textLineage = object.textLineage
    plaintext = object.plaintext
    logPlaintext = object.logPlaintext
    compacted = object.compacted
    duration = object.duration
    embedSpans = object.embedSpans
    memoryContext = object.memoryContext
    systemSeenMemoryContext = object.systemSeenMemoryContext
    imagePaths = object.imagePaths
  }
  public func build() -> ProjectHistoryNode {
    ProjectHistoryNode(
      threadId: threadId, datetime: datetime, role: role, logTokens: logTokens, tokens: tokens,
      toolCalls: toolCalls, textEdits: textEdits, textLineage: textLineage, plaintext: plaintext,
      logPlaintext: logPlaintext, compacted: compacted, duration: duration, embedSpans: embedSpans,
      memoryContext: memoryContext, systemSeenMemoryContext: systemSeenMemoryContext,
      imagePaths: imagePaths)
  }
}

#if compiler(>=5.5) && canImport(_Concurrency)
  extension ProjectHistoryNode: @unchecked Sendable {}
#endif
