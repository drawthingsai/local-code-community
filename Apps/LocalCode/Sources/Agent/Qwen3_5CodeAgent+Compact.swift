import CryptoKit
import Foundation
import ProjectHistoryManager
import Tokenizer

extension Qwen3_5CodeAgent {
  enum CompactEffort {
    case low
    case high
  }

  static let maximumContextLength = 128 * 1_024
  static let lowCompactTokenThreshold = 32_768
  static let highCompactTokenThreshold = 96 * 1_024
  static let contextCheckpointCompactionTokenThreshold = 80 * 1_024
  static let contextCheckpointCompactionHistoryTokenBudget = 16_360
  static let minimumGenerationReserve = 8_192
  static let generationSafeStopTokenThreshold = maximumContextLength - 4_096
  static let contextCheckpointCompactionPrompt = """
    You are performing a CONTEXT CHECKPOINT COMPACTION. Create a handoff summary for another LLM that will resume the task.

    Include:
    - Current progress and key decisions made
    - Important context, constraints, or user preferences
    - What remains to be done (clear next steps)
    - Any critical data, examples, or references needed to continue

    Be concise, structured, and focused on helping the next LLM seamlessly continue the work.
    """
  static let contextCheckpointCompactionSummaryPrefix = """
    Another language model started to solve this problem and produced a summary of its thinking process. You also have access to the state of the tools that were used by that language model. Use this to build on the work that has already been done and avoid duplicating work. Here is the summary produced by the other language model, use the information in this summary to assist with your own analysis:
    """
  static let continueAfterCompactionPrompt = "Continue the unfinished task."
  private static let readResponsePreviewTokenThreshold = 8_192
  private static let toolResponseExternalizationTokenThreshold = 2_048
  private static let toolResponsePreviewLineLimit = 40
  private static let toolResponsePreviewSideTokenLimit = 512
  private static let imStartToken: Int32 = 248_045
  private static let toolResponseStartToken: Int32 = 248_066
  private static let toolResponseEndToken: Int32 = 248_067
  private static let thinkStartToken: Int32 = 248_068
  private static let thinkEndToken: Int32 = 248_069

  static func compact(
    _ prefixTokens: [Int32], embedSpans: inout [EmbedSpan], effort: CompactEffort,
    tokenizer: TiktokenTokenizer,
    projectPath: String?
  ) -> [Int32] {
    var offset = 0
    var segments = messageSegments(in: prefixTokens).map {
      tokens -> (tokens: [Int32], spans: [EmbedSpan]) in
      defer { offset += tokens.count }
      return (tokens, EmbedSpan.slice(embedSpans, range: offset..<(offset + tokens.count)))
    }
    if effort == .high {
      var compactedSegments = [(tokens: [Int32], spans: [EmbedSpan])]()
      var segmentIndex = 0
      while segmentIndex < segments.count {
        let segment = segments[segmentIndex]
        let nextSegment =
          segmentIndex + 1 < segments.count ? segments[segmentIndex + 1].tokens : []
        if nextSegment.contains(toolResponseStartToken) {
          segmentIndex += 2
        } else {
          compactedSegments.append(segment)
          segmentIndex += 1
        }
      }
      segments = compactedSegments
    }
    var compactedTokens = [Int32]()
    embedSpans = []
    for index in segments.indices {
      var segment = segments[index]
      let shouldKeepThinkBlocks =
        (effort == .high && index == segments.count - 1)
        || (index + 1 < segments.count
          && segments[index + 1].tokens.contains(toolResponseStartToken))
      let withoutThink =
        shouldKeepThinkBlocks
        ? segment.tokens : removeThinkBlocks(from: segment.tokens, embedSpans: &segment.spans)
      let tokens = compactToolResponses(
        in: withoutThink, embedSpans: &segment.spans, tokenizer: tokenizer, projectPath: projectPath
      )
      embedSpans += segment.spans.map { $0.offset(by: compactedTokens.count) }
      compactedTokens += tokens
    }
    return compactedTokens
  }

  static func retainedConversationTokens(
    in tokens: [Int32], embedSpans: inout [EmbedSpan], tokenBudget: Int
  ) -> [Int32] {
    let messages = messageSegments(in: tokens)
    var retainedTurns = [[Int32]]()
    var retainedTokenCount = 0
    var messageIndex = messages.count
    while messageIndex >= 2 {
      let turn = messages[messageIndex - 2] + messages[messageIndex - 1]
      let candidateTokenCount = retainedTokenCount + turn.count
      if candidateTokenCount >= tokenBudget {
        if candidateTokenCount - tokenBudget < tokenBudget - retainedTokenCount {
          retainedTurns.append(turn)
        }
        break
      }
      retainedTurns.append(turn)
      retainedTokenCount = candidateTokenCount
      messageIndex -= 2
    }
    let retained = retainedTurns.reversed().flatMap { $0 }
    embedSpans = EmbedSpan.slice(embedSpans, range: (tokens.count - retained.count)..<tokens.count)
    return retained
  }

  static func messageSegments(in tokens: [Int32]) -> [[Int32]] {
    guard !tokens.isEmpty else { return [] }
    var segments = [[Int32]]()
    var segmentStart: Int? = nil
    for index in tokens.indices {
      guard tokens[index] == imStartToken else { continue }
      if let start = segmentStart {
        segments.append(Array(tokens[start..<index]))
      } else if index > tokens.startIndex {
        segments.append(Array(tokens[tokens.startIndex..<index]))
      }
      segmentStart = index
    }
    if let start = segmentStart {
      segments.append(Array(tokens[start..<tokens.endIndex]))
    } else {
      segments.append(tokens)
    }
    return segments
  }

  private static func removeThinkBlocks(from segment: [Int32], embedSpans: inout [EmbedSpan])
    -> [Int32]
  {
    var result = [Int32]()
    var cursor = 0
    while cursor < segment.count {
      guard let thinkStart = segment[cursor...].firstIndex(of: thinkStartToken),
        let thinkEnd = segment[(thinkStart + 1)...].firstIndex(of: thinkEndToken)
      else {
        result += segment[cursor...]
        break
      }
      let removedBefore = cursor - result.count
      result += segment[cursor..<thinkStart]
      embedSpans = EmbedSpan.replacingTokens(
        embedSpans,
        range: (thinkStart - removedBefore)..<(thinkEnd + 1 - removedBefore), replacementCount: 0)
      cursor = thinkEnd + 1
    }
    return result
  }

  private static func compactToolResponses(
    in tokens: [Int32], embedSpans: inout [EmbedSpan], tokenizer: TiktokenTokenizer,
    projectPath: String?
  ) -> [Int32] {
    var result = [Int32]()
    var cursor = 0
    while cursor < tokens.count {
      guard let responseStart = tokens[cursor...].firstIndex(of: toolResponseStartToken) else {
        result += tokens[cursor...]
        break
      }
      result += tokens[cursor..<responseStart]
      guard
        let responseEnd = tokens[(responseStart + 1)...].firstIndex(of: toolResponseEndToken)
      else {
        result += tokens[responseStart...]
        break
      }
      let bodyTokens = Array(tokens[(responseStart + 1)..<responseEnd])
      let bodyStart = result.count + 1
      if !embedSpans.contains(where: {
        $0.start < bodyStart + bodyTokens.count && $0.end > bodyStart
      }),
        bodyTokens.count > toolResponseExternalizationTokenThreshold,
        let replacementTokens = compactedToolResponseTokens(
          bodyTokens, tokenizer: tokenizer, projectPath: projectPath)
      {
        embedSpans = EmbedSpan.replacingTokens(
          embedSpans,
          range: bodyStart..<(bodyStart + bodyTokens.count),
          replacementCount: replacementTokens.count)
        result.append(toolResponseStartToken)
        result += replacementTokens
        result.append(toolResponseEndToken)
      } else {
        result += tokens[responseStart...responseEnd]
      }
      cursor = responseEnd + 1
    }
    return result
  }

  static func compactedToolResponseTokens(
    _ bodyTokens: [Int32], tokenizer: TiktokenTokenizer, projectPath: String?
  ) -> [Int32]? {
    let responseText = tokenizer.decode(bodyTokens)
    guard let path = externalizeToolResponse(responseText, projectPath: projectPath) else {
      return nil
    }
    let reference =
      "Full tool response saved at \(path). Read it in bounded chunks with start_line and "
      + "max_lines; do not use whole=true."
    return previewTokens(for: responseText, reference: reference, tokenizer: tokenizer)
  }

  static func previewedReadResponseTokensIfNeeded(
    _ bodyTokens: [Int32], request: ToolCall.Request, tokenizer: TiktokenTokenizer
  ) -> [Int32]? {
    guard bodyTokens.count > readResponsePreviewTokenThreshold else { return nil }
    let responseText = tokenizer.decode(bodyTokens)
    let path = request.parameters["path"]?.value ?? "the same path"
    let startLine = request.parameters["start_line"].flatMap { Int($0.value) } ?? 1
    let reference =
      "This read result was too large for context and was not saved as another tool response. "
      + "Re-read \(String(reflecting: path)) with whole=false, a smaller max_lines, and "
      + "start_line=\(startLine). Do not use whole=true."
    return previewTokens(for: responseText, reference: reference, tokenizer: tokenizer)
  }

  private static func previewTokens(
    for responseText: String, reference: String, tokenizer: TiktokenTokenizer
  ) -> [Int32] {
    let lines = responseText.components(separatedBy: "\n")
    let head = cappedHeadText(from: lines, tokenizer: tokenizer)
    let tail = cappedTailText(from: lines, tokenizer: tokenizer)
    let preview = [head, reference, tail].filter { !$0.isEmpty }.joined(separator: "\n\n...\n\n")
    let (_, previewTokens, _, _, _) = tokenizer.tokenize(
      text: preview, truncation: false, maxLength: 0, paddingToken: nil, addSpecialTokens: false)
    return previewTokens
  }

  private static func externalizeToolResponse(
    _ responseText: String, projectPath: String?
  ) -> String? {
    guard let projectPath = projectPath?.trimmingCharacters(in: .whitespacesAndNewlines),
      !projectPath.isEmpty
    else { return nil }
    let digest = SHA256.hash(data: Data(responseText.utf8))
    let sha256 = digest.map { String(format: "%02x", $0) }.joined()
    let relativePath = ".localc/tool_responses/\(sha256).md"
    let projectURL = URL(fileURLWithPath: projectPath, isDirectory: true)
    let responseDirectoryURL =
      projectURL
      .appendingPathComponent(".localc", isDirectory: true)
      .appendingPathComponent("tool_responses", isDirectory: true)
    let responseURL = responseDirectoryURL.appendingPathComponent("\(sha256).md")
    do {
      try FileManager.default.createDirectory(
        at: responseDirectoryURL, withIntermediateDirectories: true)
      try Data(responseText.utf8).write(to: responseURL, options: .atomic)
      return relativePath
    } catch {
      return nil
    }
  }

  private static func cappedHeadText(
    from lines: [String], tokenizer: TiktokenTokenizer
  ) -> String {
    var output = ""
    var tokenCount = 0
    for line in lines.prefix(toolResponsePreviewLineLimit) {
      let fragment = output.isEmpty ? line : "\n\(line)"
      let (_, fragmentTokens, _, _, _) = tokenizer.tokenize(
        text: fragment, truncation: false, maxLength: 0, paddingToken: nil, addSpecialTokens: false)
      if tokenCount + fragmentTokens.count <= toolResponsePreviewSideTokenLimit {
        output += fragment
        tokenCount += fragmentTokens.count
        continue
      }
      let remainingTokenCount = toolResponsePreviewSideTokenLimit - tokenCount
      if remainingTokenCount > 0 {
        output += tokenizer.decode(Array(fragmentTokens.prefix(remainingTokenCount)))
      }
      break
    }
    return output
  }

  private static func cappedTailText(
    from lines: [String], tokenizer: TiktokenTokenizer
  ) -> String {
    var output = ""
    var tokenCount = 0
    for line in lines.suffix(toolResponsePreviewLineLimit).reversed() {
      let fragment = output.isEmpty ? line : "\(line)\n"
      let (_, fragmentTokens, _, _, _) = tokenizer.tokenize(
        text: fragment, truncation: false, maxLength: 0, paddingToken: nil, addSpecialTokens: false)
      if tokenCount + fragmentTokens.count <= toolResponsePreviewSideTokenLimit {
        output = fragment + output
        tokenCount += fragmentTokens.count
        continue
      }
      let remainingTokenCount = toolResponsePreviewSideTokenLimit - tokenCount
      if remainingTokenCount > 0 {
        output = tokenizer.decode(Array(fragmentTokens.suffix(remainingTokenCount))) + output
      }
      break
    }
    return output
  }
}
