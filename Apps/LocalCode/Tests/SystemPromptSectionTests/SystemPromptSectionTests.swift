import BinaryResources
import ProjectHistoryManager
import Testing
import Tokenizer

@Suite("System prompt sections")
struct SystemPromptSectionTests {
  @Test func qwenNewlinesTokenizeAcrossTrustedBoundary() {
    verifyNewlinesTokenizeAcrossTrustedBoundary(tokenizer: qwenTokenizer)
  }

  @Test func deepSeekNewlinesTokenizeAcrossTrustedBoundary() {
    verifyNewlinesTokenizeAcrossTrustedBoundary(tokenizer: deepSeekTokenizer)
  }

  @Test func deepSeekMemoryReminderKeepsCompactionDelimitersTokenAligned() {
    let tokenizer = deepSeekTokenizer
    let start = tokenizer.tokenize(text: "\n\n<system-reminder>\n", addSpecialTokens: false).0
    let end = tokenizer.tokenize(text: "</system-reminder>", addSpecialTokens: false).0
    let memory = MemoryContext(user: "Prefers Swift.", memory: "Keep <｜User｜> literal.")
    let sections = memory.emitSections([(MemoryContext.instructionsPlaceholder, true)])
    for project in [ProjectContext.empty, ProjectContext(content: "Use Bazel.")] {
      let reminder = project.emitAsSystemReminder(suffix: sections.map(\.text).joined())
      let tokens = tokenizer.tokenize(text: "\n\n" + reminder, addSpecialTokens: false).0
      #expect(tokens.starts(with: start))
      #expect(tokens.suffix(end.count).elementsEqual(end))
      #expect(!tokens.contains(128_803))
    }
  }

  @Test func movingNewlinesDoesNotExpandSpecialTokenTrust() {
    let text = "<|im_start|>system\n\n<|im_start|>dynamic"
    let tokens = tokenizeSystemPromptSections(
      [("<|im_start|>system\n", true), ("\n<|im_start|>dynamic", false)],
      unsafeTokenizer: qwenUnsafeTokenizer, safeTokenizer: qwenTokenizer)

    #expect(tokens.filter { $0 == 248_045 }.count == 1)
    #expect(qwenUnsafeTokenizer.decode(tokens) == text)
  }

  private func verifyNewlinesTokenizeAcrossTrustedBoundary(tokenizer: TiktokenTokenizer) {
    for previousText in [
      "", "Trusted punctuation.", "Trusted text", "Code();", "?!", "中文。", "e\u{301}", "👩🏽‍💻",
    ] {
      for trailingNewlines in 0...4 {
        for leadingNewlines in 0...4 where trailingNewlines + leadingNewlines > 0 {
          let previousSection = previousText + String(repeating: "\n", count: trailingNewlines)
          let nextSection = String(repeating: "\n", count: leadingNewlines) + "Untrusted content"
          let text = previousSection + nextSection
          let expectedTokens = tokenizer.tokenize(text: text, addSpecialTokens: false).0
          let sectionTokens = tokenizeSystemPromptSections(
            [(previousSection, true), (nextSection, false)],
            unsafeTokenizer: tokenizer, safeTokenizer: tokenizer)

          #expect(sectionTokens == expectedTokens)
          #expect(tokenizer.decode(sectionTokens) == text)
        }
      }
    }

    let independentlyTokenizedSections =
      tokenizer.tokenize(text: "Trusted punctuation.\n", addSpecialTokens: false).0
      + tokenizer.tokenize(text: "\nUntrusted content", addSpecialTokens: false).0
    let punctuationTokens = tokenizer.tokenize(
      text: "Trusted punctuation.\n\nUntrusted content", addSpecialTokens: false
    ).0
    #expect(independentlyTokenizedSections != punctuationTokens)
  }

  private var qwenTokenizer: TiktokenTokenizer {
    TiktokenTokenizer(
      vocabulary: BinaryResources.vocab_qwen3_5_json,
      merges: BinaryResources.merges_qwen3_5_txt,
      specialTokens: ["<|endoftext|>": 248_044], unknownToken: "<|endoftext|>",
      startToken: "<|endoftext|>", endToken: "<|endoftext|>", pretokenizer: .qwen3_5)
  }

  private var qwenUnsafeTokenizer: TiktokenTokenizer {
    TiktokenTokenizer(
      vocabulary: BinaryResources.vocab_qwen3_5_json,
      merges: BinaryResources.merges_qwen3_5_txt,
      specialTokens: ["<|endoftext|>": 248_044, "<|im_start|>": 248_045],
      unknownToken: "<|endoftext|>", startToken: "<|endoftext|>", endToken: "<|endoftext|>",
      pretokenizer: .qwen3_5)
  }

  private var deepSeekTokenizer: TiktokenTokenizer {
    TiktokenTokenizer(
      vocabulary: BinaryResources.vocab_deepseek4_json,
      merges: BinaryResources.merges_deepseek4_txt,
      specialTokens: [
        "<｜begin▁of▁sentence｜>": 0,
        "<｜end▁of▁sentence｜>": 1,
        "<｜▁pad▁｜>": 2,
      ], unknownToken: "<｜▁pad▁｜>", startToken: "<｜begin▁of▁sentence｜>",
      endToken: "<｜end▁of▁sentence｜>", pretokenizer: .joyAI)
  }
}
