import CryptoKit
import Foundation
import ProjectHistoryManager
import Tokenizer

extension DeepSeek4CodeAgent {
  // Keep the active agent context below the model's full capacity so prefill and
  // decoding remain acceptably fast.
  static var maximumContextLength: Int { 512 * 1_024 }
  static var contextCheckpointCompactionTokenThreshold: Int { 416 * 1_024 }
  static var contextCheckpointCompactionHistoryTokenBudget: Int { 64 * 1_024 }
  static var minimumGenerationReserve: Int { 8_192 }
  static var readResponsePreviewTokenThreshold: Int { 65_536 }
  static var toolResponseExternalizationTokenThreshold: Int { 32_768 }

  static var contextCheckpointCompactionPrompt: String {
    """
    You are performing a CONTEXT CHECKPOINT COMPACTION. Create a handoff summary for another LLM that will resume the task.

    Include:
    - Current progress and key decisions made
    - Important context, constraints, or user preferences
    - What remains to be done (clear next steps)
    - Any critical data, examples, or references needed to continue

    Be concise, structured, and focused on helping the next LLM seamlessly continue the work.
    """
  }
  static var contextCheckpointCompactionSummaryPrefix: String {
    """
    Another language model started to solve this problem and produced a summary of its thinking process. You also have access to the state of the tools that were used by that language model. Use this to build on the work that has already been done and avoid duplicating work. Here is the summary produced by the other language model, use the information in this summary to assist with your own analysis:
    """
  }
  static var continueAfterCompactionPrompt: String { "Continue the unfinished task." }

  private static var toolResponsePreviewLineLimit: Int { 40 }
  private static var toolResponsePreviewSideTokenLimit: Int { 512 }

  static func retainedConversationTokens(
    in tokens: [Int32], embedSpans: [EmbedSpan] = [], tokenBudget: Int
  ) -> (tokens: [Int32], embedSpans: [EmbedSpan]) {
    guard tokens.count > tokenBudget else { return (tokens, embedSpans) }
    let segments = messageSegments(in: tokens)
    var retainedSegments = [[Int32]]()
    var retainedTokenCount = 0
    for segment in segments.reversed() {
      let candidateTokenCount = retainedTokenCount + segment.count
      guard candidateTokenCount <= tokenBudget else { break }
      retainedSegments.append(segment)
      retainedTokenCount = candidateTokenCount
    }
    var start = tokens.count - (retainedSegments.isEmpty ? tokenBudget : retainedTokenCount)
    if let span = embedSpans.first(where: { $0.start < start && start < $0.end }) {
      start = Int(span.end)
    }
    return (Array(tokens[start...]), EmbedSpan.slice(embedSpans, range: start..<tokens.count))
  }

  static func messageSegments(in tokens: [Int32]) -> [[Int32]] {
    guard !tokens.isEmpty else { return [] }
    var segments = [[Int32]]()
    var segmentStart: Int? = nil
    for index in tokens.indices {
      guard tokens[index] == userToken else { continue }
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

  static func replaceSystemReminder(
    in tokens: [Int32], embedSpans: [EmbedSpan] = [], with replacement: [Int32],
    startTokens: [Int32], endTokens: [Int32]
  ) -> (tokens: [Int32], embedSpans: [EmbedSpan])? {
    guard !startTokens.isEmpty, !endTokens.isEmpty, startTokens.count <= tokens.count else {
      return nil
    }
    let lastStart = tokens.count - startTokens.count
    guard
      let start = (0...lastStart).first(where: {
        tokens[$0..<$0 + startTokens.count].elementsEqual(startTokens)
      })
    else { return nil }
    let endSearchStart = start + startTokens.count
    guard endTokens.count <= tokens.count - endSearchStart else { return nil }
    let lastEnd = tokens.count - endTokens.count
    guard
      let end = (endSearchStart...lastEnd).first(where: {
        tokens[$0..<$0 + endTokens.count].elementsEqual(endTokens)
      })
    else { return nil }
    var result = Array(tokens[..<start])
    result += replacement
    let remainderStart = end + endTokens.count
    if remainderStart < tokens.count {
      result.append(contentsOf: tokens[remainderStart...])
    }
    return (
      result,
      EmbedSpan.replacingTokens(
        embedSpans, range: start..<remainderStart, replacementCount: replacement.count)
    )
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

  static func previewedReadResponseTokens(
    _ bodyTokens: [Int32], request: ToolCall.Request, tokenizer: TiktokenTokenizer
  ) -> [Int32] {
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
      text: preview, truncation: false, maxLength: 0, paddingToken: nil,
      addSpecialTokens: false)
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
        text: fragment, truncation: false, maxLength: 0, paddingToken: nil,
        addSpecialTokens: false)
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
        text: fragment, truncation: false, maxLength: 0, paddingToken: nil,
        addSpecialTokens: false)
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
