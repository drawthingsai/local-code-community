import Foundation
import ProjectHistoryManager
import Tokenizer

extension Inkling2CodeAgent {
  // Inkling 2 Small takes up to 1M tokens. Keep the agent context where GLM 5.3's is, so prefill
  // and decoding stay acceptably fast and the full-attention caches stay small.
  static var maximumContextLength: Int { 192 * 1_024 }
  static var contextCheckpointCompactionTokenThreshold: Int { 156 * 1_024 }
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

  /// Rounds of the conversation: the user's or the tools' messages, then the model's turn. A
  /// round starts at the first user or tool message after the model's end of turn, so the parts of
  /// one message, such as an image and its label, stay together, and a long tool loop keeps its
  /// recent rounds.
  static func messageSegments(in tokens: [Int32]) -> [[Int32]] {
    guard !tokens.isEmpty else { return [] }
    var segments = [[Int32]]()
    var segmentStart = tokens.startIndex
    for index in tokens.indices.dropFirst()
    where (tokens[index] == userMessageToken || tokens[index] == toolMessageToken)
      && tokens[index - 1] == endOfTurnToken
    {
      segments.append(Array(tokens[segmentStart..<index]))
      segmentStart = index
    }
    segments.append(Array(tokens[segmentStart..<tokens.endIndex]))
    return segments
  }

  /// Replaces the reminder message, a user message holding only the delimited reminder, with
  /// `replacement`, a whole message or nothing. Nil when there is no reminder message.
  static func replaceSystemReminder(
    in tokens: [Int32], embedSpans: [EmbedSpan] = [], with replacement: [Int32],
    startTokens: [Int32], endTokens: [Int32]
  ) -> (tokens: [Int32], embedSpans: [EmbedSpan])? {
    let opening = [userMessageToken, textContentToken] + startTokens
    let closing = endTokens + [endMessageToken]
    guard !startTokens.isEmpty, !endTokens.isEmpty, opening.count <= tokens.count else {
      return nil
    }
    guard
      let start = (0...(tokens.count - opening.count)).first(where: {
        tokens[$0..<$0 + opening.count].elementsEqual(opening)
      })
    else { return nil }
    let endSearchStart = start + opening.count
    guard closing.count <= tokens.count - endSearchStart else { return nil }
    guard
      let end = (endSearchStart...(tokens.count - closing.count)).first(where: {
        tokens[$0..<$0 + closing.count].elementsEqual(closing)
      })
    else { return nil }
    let remainderStart = end + closing.count
    var result = Array(tokens[..<start])
    result += replacement
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
    _ bodyTokens: [Int32], tokenizer: TiktokenTokenizer, saveToolResponse: (String) -> String?
  ) -> [Int32]? {
    let responseText = tokenizer.decode(bodyTokens)
    guard let path = saveToolResponse(responseText) else {
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
    return tokenizer.tokenize(text: preview, addSpecialTokens: false).0
  }

  private static func cappedHeadText(
    from lines: [String], tokenizer: TiktokenTokenizer
  ) -> String {
    var output = ""
    var tokenCount = 0
    for line in lines.prefix(toolResponsePreviewLineLimit) {
      let fragment = output.isEmpty ? line : "\n\(line)"
      let fragmentTokens = tokenizer.tokenize(text: fragment, addSpecialTokens: false).0
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
      let fragmentTokens = tokenizer.tokenize(text: fragment, addSpecialTokens: false).0
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
