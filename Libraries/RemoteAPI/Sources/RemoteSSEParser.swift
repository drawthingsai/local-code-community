import Foundation

public struct RemoteSSEParser: Sendable {
  public enum Event: Equatable, Sendable {
    case data(String)
    case done
  }

  private var lineBuffer = Data()
  private var eventDataLines = [Data]()
  private var eventByteCount = 0
  private let maximumEventBytes: Int

  public init(maximumEventBytes: Int = 1 * 1_024 * 1_024) {
    self.maximumEventBytes = max(1, maximumEventBytes)
  }

  public mutating func append(_ data: Data) throws -> [Event] {
    var events = [Event]()
    for byte in data {
      if byte == 0x0A {
        var line = lineBuffer
        lineBuffer.removeAll(keepingCapacity: true)
        if line.last == 0x0D {
          line.removeLast()
        }
        if let event = try consume(line: line) {
          events.append(event)
        }
      } else {
        lineBuffer.append(byte)
        guard lineBuffer.count + eventByteCount <= maximumEventBytes else {
          throw RemoteChatError.responseTooLarge(maximumBytes: maximumEventBytes)
        }
      }
    }
    return events
  }

  public mutating func finish() throws -> [Event] {
    var events = [Event]()
    if !lineBuffer.isEmpty {
      var line = lineBuffer
      lineBuffer.removeAll(keepingCapacity: false)
      if line.last == 0x0D {
        line.removeLast()
      }
      if let event = try consume(line: line) {
        events.append(event)
      }
    }
    if let event = try emitEvent() {
      events.append(event)
    }
    return events
  }

  private mutating func consume(line: Data) throws -> Event? {
    guard !line.isEmpty else { return try emitEvent() }
    guard line.first != 0x3A else { return nil }
    let colon = line.firstIndex(of: 0x3A)
    let fieldEnd = colon ?? line.endIndex
    guard String(decoding: line[..<fieldEnd], as: UTF8.self) == "data" else { return nil }
    var valueStart = colon.map { line.index(after: $0) } ?? line.endIndex
    if valueStart < line.endIndex, line[valueStart] == 0x20 {
      valueStart = line.index(after: valueStart)
    }
    let value = Data(line[valueStart...])
    eventByteCount += value.count
    if !eventDataLines.isEmpty {
      eventByteCount += 1
    }
    guard eventByteCount <= maximumEventBytes else {
      throw RemoteChatError.responseTooLarge(maximumBytes: maximumEventBytes)
    }
    eventDataLines.append(value)
    return nil
  }

  private mutating func emitEvent() throws -> Event? {
    guard !eventDataLines.isEmpty else { return nil }
    var payload = Data()
    payload.reserveCapacity(eventByteCount)
    for (index, line) in eventDataLines.enumerated() {
      if index > 0 { payload.append(0x0A) }
      payload.append(line)
    }
    eventDataLines.removeAll(keepingCapacity: true)
    eventByteCount = 0
    guard let text = String(data: payload, encoding: .utf8) else {
      throw RemoteChatError.malformedStream("event data is not valid UTF-8")
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]"
      ? .done : .data(text)
  }
}
