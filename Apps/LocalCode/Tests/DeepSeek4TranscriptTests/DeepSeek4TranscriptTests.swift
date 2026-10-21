import Foundation
import LLM
import ProjectHistoryManager
import Testing

protocol TranscriptGenerator {
  static var version: LLMVersion { get }
  static var safeTokenizer: TestTokenizer { get }
  static var unsafeTokenizer: TestTokenizer { get }
}

final class DeepSeek4CodeAgent<Generator: TranscriptGenerator> {
  static var toolCallFormat: DeepSeek4ToolCallParser.Format { .init(version: Generator.version) }
  static var userToken: Int32 { 128_803 }
}

enum DeepSeek4TextGenerator: TranscriptGenerator {
  static let version = LLMVersion.deepseek_4_flash
  static let safeTokenizer = TestTokenizer()
  static let unsafeTokenizer = TestTokenizer()
}

enum DeepSeek4_1TextGenerator: TranscriptGenerator {
  static let version = LLMVersion.deepseek_4_1_flash
  static let safeTokenizer = TestTokenizer()
  static let unsafeTokenizer = TestTokenizer()
}

struct TestTokenizer {
  func tokenize(
    text: String, truncation: Bool, maxLength: Int, paddingToken: Int32?,
    addSpecialTokens: Bool
  ) -> (Int, [Int32], Int, Int, Int) {
    (0, text.unicodeScalars.map { Int32($0.value) }, 0, 0, 0)
  }

  func decode(_ tokens: [Int32], specialTokens: [Int32: String]) -> String {
    tokens.map { token in
      if let specialToken = specialTokens[token] {
        return specialToken
      }
      return UnicodeScalar(UInt32(token)).map(String.init) ?? ""
    }.joined()
  }
}

@Suite("DeepSeek 4 transcript")
struct DeepSeek4TranscriptTests {
  @Test func deepSeekRoundTripUsesGeneratorVersion() throws {
    let transcript: [AgentTranscriptEntry] = [
      .user("Read the skill"),
      .assistant(
        text: "I'll read it.", thinking: "",
        toolCalls: [
          AgentTranscriptToolCall(
            function: "read",
            parameters: [
              "path": .init(string: true, value: "SKILL.md")
            ])
        ]),
      .toolResults([AgentTranscriptToolResult(content: "Skill instructions", isError: false)]),
      .assistant(text: "Done", thinking: "", toolCalls: []),
    ]
    let v4 = DeepSeek4CodeAgent<DeepSeek4TextGenerator>.parse(transcript)
    let v41 = DeepSeek4CodeAgent<DeepSeek4_1TextGenerator>.parse(transcript)
    #expect(TestTokenizer().decode(v41, specialTokens: [:]).contains("<｜DSML｜ calls>"))
    for parsed in [
      DeepSeek4CodeAgent<DeepSeek4TextGenerator>.parse(v4),
      DeepSeek4CodeAgent<DeepSeek4_1TextGenerator>.parse(v41),
    ] {
      #expect(parsed == transcript)
    }
    // The selected generator determines the grammar, not the contents of the output.
    let mismatched = DeepSeek4CodeAgent<DeepSeek4_1TextGenerator>.parse(v4)
    guard case .assistant(_, _, let toolCalls) = mismatched[1] else {
      Issue.record("Missing assistant turn")
      return
    }
    #expect(toolCalls.isEmpty)
  }

  @Test func appendedProjectContextSystemReminderIsHiddenFromVisiblePrompt() {
    let systemReminder = "\n\n<system-reminder>P</system-reminder>"
    let tokens: [Int32] =
      [128_803, 65] + systemReminder.unicodeScalars.map { Int32($0.value) }
      + [128_804, 128_822, 66, 1]

    let transcript = DeepSeek4CodeAgent<DeepSeek4TextGenerator>.parse(tokens)
    #expect(transcript.count == 2)
    #expect(transcript[0] == .user("A"))
    #expect(transcript[1] == .assistant(text: "B", thinking: "", toolCalls: []))
  }

  @Test func compactionDoesNotRetainHalfAnImage() {
    let span = EmbedSpan(
      start: 2, length: 4, digest: Array(repeating: 1, count: 32), kind: .image)
    let result = DeepSeek4CodeAgent<DeepSeek4TextGenerator>.retainedConversationTokens(
      in: [1, 2, 99, 99, 99, 99, 3, 4], embedSpans: [span], tokenBudget: 4)
    #expect(result.tokens == [3, 4])
    #expect(result.embedSpans.isEmpty)
    let full = DeepSeek4CodeAgent<DeepSeek4TextGenerator>.retainedConversationTokens(
      in: [1, 2, 99, 99, 99, 99, 3, 4], embedSpans: [span], tokenBudget: 6)
    #expect(full.embedSpans == [span.offset(by: -2)])
  }

  @Test func reminderReplacementRebasesImageSpans() {
    let span = EmbedSpan(
      start: 5, length: 2, digest: Array(repeating: 1, count: 32), kind: .image)
    let result = DeepSeek4CodeAgent<DeepSeek4TextGenerator>.replaceSystemReminder(
      in: [1, 7, 4, 8, 9, 99, 99, 3], embedSpans: [span], with: [7, 8, 9], startTokens: [7],
      endTokens: [8, 9])
    #expect(result?.tokens == [1, 7, 8, 9, 99, 99, 3])
    #expect(result?.embedSpans == [span.offset(by: -1)])
  }

  @Test func removesOnlyFirstSystemReminderDuringCompaction() {
    #expect(
      DeepSeek4CodeAgent<DeepSeek4TextGenerator>.replaceSystemReminder(
        in: [1, 7, 4, 8, 9, 2, 7, 5, 8, 9, 3], with: [],
        startTokens: [7], endTokens: [8, 9])?.tokens
        == [1, 2, 7, 5, 8, 9, 3])
    #expect(
      DeepSeek4CodeAgent<DeepSeek4TextGenerator>.replaceSystemReminder(
        in: [1, 2, 3], with: [], startTokens: [7], endTokens: [8, 9]) == nil)
  }

  @Test func memoryRefreshReplacesReminderWithoutChangingConversation() {
    #expect(
      DeepSeek4CodeAgent<DeepSeek4TextGenerator>.replaceSystemReminder(
        in: [1, 7, 4, 8, 9, 2, 7, 5, 8, 9, 3], with: [7, 6, 8, 9],
        startTokens: [7], endTokens: [8, 9])?.tokens
        == [1, 7, 6, 8, 9, 2, 7, 5, 8, 9, 3])
  }

  @Test func toolCallsAlwaysHaveOfficialTwoNewlinePrefix() throws {
    for text in ["", "summary"] {
      let tokens = DeepSeek4CodeAgent<DeepSeek4TextGenerator>.parse([
        .assistant(
          text: text, thinking: "",
          toolCalls: [
            AgentTranscriptToolCall(
              function: "edit",
              parameters: [
                "new": AgentTranscriptToolCall.Parameter(string: true, value: "replacement")
              ])
          ])
      ])
      let assistant = try #require(tokens.firstIndex(of: 128_804))
      let bodyStart = tokens.index(assistant, offsetBy: 2)
      let body = TestTokenizer().decode(
        Array(tokens[bodyStart..<tokens.index(before: tokens.endIndex)]), specialTokens: [:])

      #expect(body.hasPrefix(text + "\n\n<｜DSML｜tool_calls>\n"))
    }
  }
}
