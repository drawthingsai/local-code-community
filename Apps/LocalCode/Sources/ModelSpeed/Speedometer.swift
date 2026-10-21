import Foundation

/// Times a local model at growing context lengths, labeled the way llama-bench labels its depths.
/// The first run for a model builds its context into `speed_context_cache.sqlite3` under Caches;
/// after that, each reading restores that many tokens and times only what runs on top of them.
protocol Speedometer: AnyObject {
  /// Called on the generation queue as a reading reads and writes.
  var delegate: (any SpeedometerDelegate)? { get set }
  /// The context lengths this device has the memory to measure, in the order a run takes them.
  var contextLengths: [Int] { get }
  /// The prompt each prefill reading measures, in tokens: one full prefill chunk.
  var promptLength: Int { get }
  /// Tokens per second prefilling one full chunk of prompt on top of `contextLength` tokens, after
  /// a short cool-down. Runs on the generation queue. Returns nil when stopped or when the reading
  /// could not be taken.
  func prefillReading(contextLength: Int) -> Double?
  /// Tokens per second decoding 128 tokens with `contextLength` tokens already in context, after
  /// only a short prompt. Runs on the generation queue. Returns nil when stopped or when the
  /// reading could not be taken.
  func decodeReading(contextLength: Int) -> (tokensPerSecond: Double, decodedTokenCount: Int)?
  /// Safe from any queue; the reading in progress stops at its next step.
  func stop()
}

protocol SpeedometerDelegate: AnyObject {
  func speedometer(_ speedometer: any Speedometer, didUpdate progress: SpeedometerProgress)
}

enum SpeedometerProgress: Equatable {
  /// Prefilling the measured prompt, or the context a model's first run builds.
  case reading(finished: Int, total: Int)
  /// Decoding the measured reply.
  case writing(tokens: Int)
  /// Idle before a reading's prefill pass, so the heat of what ran before doesn't slow it.
  case coolingDown
}

struct SpeedometerReading: Equatable, Codable {
  /// Readings start with nothing in context, then double from 4K to 512K. A speedometer keeps
  /// the ones its model's context window and the device's memory allow, and that land on both its
  /// prefill chunks and its checkpoints.
  static let contextLengths = [
    0, 4_096, 8_192, 16_384, 32_768, 65_536, 131_072, 262_144, 524_288,
  ]

  var contextLength: Int
  var prefillTokensPerSecond: Double
  var decodeTokensPerSecond: Double
  /// Fewer than asked for when the model ends its reply early.
  var decodedTokenCount: Int
}

/// One family's chat template, copied from its code agent so the context reads like a real thread.
protocol SpeedometerTemplate {
  var assistantPromptTokens: [Int32] { get }
  /// Starts the sequence with the user's request.
  func requestTokens(_ text: String) -> [Int32]
  /// A later user turn.
  func userTokens(_ text: String) -> [Int32]
  func readCallTokens(path: String, startLine: Int) -> [Int32]
  func toolResultTokens(_ content: [Int32]) -> [Int32]
  func tokens(_ text: String) -> [Int32]
  func text(_ tokens: [Int32]) -> String
}

/// A fixed agent session over the bundled Python standard library: a request to read it, then read
/// calls and their results. Every multiple of `promptLength` falls right after a read call, so a
/// run can restore the context at any of them and prefill the pending result as the next prompt.
struct SpeedometerTranscript<Template: SpeedometerTemplate> {
  /// The measured prefill, in tokens: one full prefill chunk.
  let promptLength: Int

  private struct ReadPosition: Equatable {
    var file: Int
    var startLine: Int
  }

  private static var request: String {
    "Read through the Python standard library in Library/lib/python3.14, module by module, and keep "
      + "track of how the modules depend on one another."
  }
  // Asked after the pending result, so the decode is a reply of its own rather than the next read
  // call, which would end the turn before the decode's 128 tokens.
  private static var followUpRequest: String {
    "Before reading on, explain in detail what this part of the module does and how it relates to "
      + "the modules you have read so far."
  }
  // The read tool's default page size.
  private static var linesPerRead: Int { 500 }
  // How much of the pending result the decode prompt keeps.
  private static var decodeResultLength: Int { 32 }
  // Short files are skipped, and a file's last read starts early enough to be this long, so any
  // result can absorb the trimming that lands a block on its boundary.
  private static var minimumReadCharacters: Int { 4_000 }
  private static var minimumLastResultLength: Int { 64 }

  private let template: Template
  private let files: [(path: String, lines: [String])]
  private let resultOverhead: Int
  /// The context the cache holds, ending right after a read call at every multiple of
  /// `promptLength`.
  private(set) var contextTokens = [Int32]()
  private var pendingPositions = [Int: ReadPosition]()

  /// - Parameter libraryURL: The bundled `lib/python3.14` directory.
  init?(template: Template, libraryURL: URL, promptLength: Int, maximumContextLength: Int) {
    guard let fileNames = try? FileManager.default.contentsOfDirectory(atPath: libraryURL.path)
    else { return nil }
    files = fileNames.filter { $0.hasSuffix(".py") }.sorted().compactMap { fileName in
      guard
        let content = try? String(
          contentsOf: libraryURL.appendingPathComponent(fileName), encoding: .utf8),
        content.utf8.count >= Self.minimumReadCharacters
      else { return nil }
      return ("Library/lib/python3.14/\(fileName)", content.components(separatedBy: "\n"))
    }
    self.template = template
    self.promptLength = promptLength
    resultOverhead = template.toolResultTokens([]).count
    guard !files.isEmpty else { return nil }
    var tokens = openingTokens
    var position = ReadPosition(file: 0, startLine: 1)
    var boundary = promptLength
    while boundary <= maximumContextLength {
      guard fill(&tokens, position: &position, to: boundary, endsWithPrompt: false) else {
        return nil
      }
      pendingPositions[boundary] = position
      boundary += promptLength
    }
    contextTokens = tokens
  }

  /// The prompt measured at `contextLength`: the pending read's result, then the assistant prompt.
  func promptTokens(contextLength: Int) -> [Int32]? {
    var tokens = [Int32]()
    var position = ReadPosition(file: 0, startLine: 1)
    if contextLength == 0 {
      tokens = openingTokens
    } else {
      guard let pendingPosition = pendingPositions[contextLength] else { return nil }
      position = pendingPosition
    }
    guard fill(&tokens, position: &position, to: promptLength, endsWithPrompt: true) else {
      return nil
    }
    return tokens
  }

  /// The prompt under the measured decode at `contextLength`: the start of the pending read's
  /// result, then the follow-up request and the assistant prompt. It is kept short, so the decode
  /// runs at about the context it is labeled with.
  func decodePromptTokens(contextLength: Int) -> [Int32]? {
    var tokens = [Int32]()
    var position = ReadPosition(file: 0, startLine: 1)
    if contextLength == 0 {
      tokens = openingTokens
    } else {
      guard let pendingPosition = pendingPositions[contextLength] else { return nil }
      position = pendingPosition
    }
    let result = Array(resultTokens(at: position).prefix(Self.decodeResultLength))
    return tokens + template.toolResultTokens(result) + template.userTokens(Self.followUpRequest)
      + template.assistantPromptTokens
  }

  private var openingTokens: [Int32] {
    template.requestTokens(Self.request) + readCallTokens(at: ReadPosition(file: 0, startLine: 1))
  }

  /// Appends read results and calls after a pending read call until `tokens` is exactly `end` long,
  /// finishing with a read call for wherever the reading stopped, or with the follow-up request and
  /// the assistant prompt.
  private func fill(
    _ tokens: inout [Int32], position: inout ReadPosition, to end: Int, endsWithPrompt: Bool
  ) -> Bool {
    let promptTokens =
      template.userTokens(Self.followUpRequest) + template.assistantPromptTokens
    for _ in 0..<64 {
      let remaining = end - tokens.count
      let content = resultTokens(at: position)
      let next = readPosition(after: position, lines: Self.linesPerRead)
      let nextCall = readCallTokens(at: next)
      let fullLength = resultOverhead + content.count + nextCall.count
      let reserve =
        resultOverhead + max(promptTokens.count, nextCall.count + 4) + Self.minimumLastResultLength
      if remaining - fullLength >= reserve {
        tokens += template.toolResultTokens(content) + nextCall
        position = next
        continue
      }
      if endsWithPrompt {
        let length = remaining - resultOverhead - promptTokens.count
        if length > 0, length <= content.count {
          tokens += template.toolResultTokens(Array(content.prefix(length))) + promptTokens
          return true
        }
      } else {
        // The call names the line the trimmed result stopped at, which can change its length.
        var callLength = nextCall.count
        for _ in 0..<4 {
          let length = remaining - resultOverhead - callLength
          guard length > 0, length <= content.count else { break }
          let trimmed = Array(content.prefix(length))
          let stopped = readPosition(after: position, lines: completeLineCount(in: trimmed))
          let call = readCallTokens(at: stopped)
          if call.count == callLength {
            tokens += template.toolResultTokens(trimmed) + call
            position = stopped
            return true
          }
          callLength = call.count
        }
      }
      // Too little room is left after this result for another, yet it is too short to land on the
      // boundary by itself: hand part of it to one more read.
      let length = content.count - max(1, reserve - (remaining - fullLength))
      guard length > 0 else { return false }
      let trimmed = Array(content.prefix(length))
      let stopped = readPosition(after: position, lines: completeLineCount(in: trimmed))
      tokens += template.toolResultTokens(trimmed) + readCallTokens(at: stopped)
      position = stopped
    }
    return false
  }

  private func readCallTokens(at position: ReadPosition) -> [Int32] {
    template.readCallTokens(path: files[position.file].path, startLine: position.startLine)
  }

  /// The read tool's output for up to a page of lines from `position`, as tokens.
  private func resultTokens(at position: ReadPosition) -> [Int32] {
    let (path, lines) = files[position.file]
    let startLine = position.startLine
    let endLine = min(lines.count, startLine + Self.linesPerRead - 1)
    // Copied from the read tool's output.
    let header: String
    if endLine < lines.count {
      header =
        "\(path): lines \(startLine)-\(endLine) of \(lines.count); "
        + "continue_offset=\(endLine + 1); "
        + "call the more tool with count=\(Self.linesPerRead) to read the next chunk"
    } else {
      header = "\(path): lines \(startLine)-\(endLine) of \(lines.count)"
    }
    let body = lines[(startLine - 1)..<endLine].enumerated().map { offset, line in
      "\(startLine + offset):\(Self.lineTag(line))> \(line)"
    }.joined(separator: "\n")
    return template.tokens(body.isEmpty ? header : header + "\n" + body)
  }

  /// How many result lines `content` shows in full, after its header line.
  private func completeLineCount(in content: [Int32]) -> Int {
    max(0, template.text(content).filter { $0 == "\n" }.count - 1)
  }

  /// Where reading continues `lines` lines past `position`: the next file after the end of one,
  /// and never so close to a file's end that the read would be short.
  private func readPosition(after position: ReadPosition, lines: Int) -> ReadPosition {
    var file = position.file
    var startLine = position.startLine + lines
    if startLine > files[file].lines.count {
      file = (file + 1) % files.count
      startLine = 1
    }
    let fileLines = files[file].lines
    var latestStartLine = fileLines.count + 1
    var characters = 0
    while latestStartLine > 1, characters < Self.minimumReadCharacters {
      latestStartLine -= 1
      characters += fileLines[latestStartLine - 1].utf8.count + 1
    }
    return ReadPosition(file: file, startLine: min(startLine, latestStartLine))
  }

  // Copied from the read tool, which tags each line so edits can refer to it.
  private static func lineTag(_ line: String) -> String {
    let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_-")
    var hash: UInt32 = 2_166_136_261
    for byte in line.utf8 {
      hash ^= UInt32(byte)
      hash = hash &* 16_777_619
    }
    var tag = ""
    for shift in stride(from: 18, through: 0, by: -6) {
      tag.append(alphabet[Int((hash >> UInt32(shift)) & 0x3f)])
    }
    return tag
  }
}
