import Tokenizer

func tokenizeSystemPromptSections(
  _ sections: [SystemPromptSection], unsafeTokenizer: TiktokenTokenizer,
  safeTokenizer: TiktokenTokenizer
) -> [Int32] {
  var normalizedSections = [SystemPromptSection]()
  for section in sections where !section.text.isEmpty {
    if normalizedSections.last?.allowsSpecialTokens == section.allowsSpecialTokens {
      normalizedSections[normalizedSections.count - 1].text += section.text
    } else {
      normalizedSections.append(section)
    }
  }

  var result = [Int32]()
  for index in normalizedSections.indices {
    let tokenizer =
      normalizedSections[index].allowsSpecialTokens ? unsafeTokenizer : safeTokenizer
    guard index + 1 < normalizedSections.count else {
      result.append(
        contentsOf: tokenizer.tokenize(
          text: normalizedSections[index].text, addSpecialTokens: false
        ).0)
      break
    }

    let trailingNewlineCount = normalizedSections[index].text.reversed().prefix {
      $0 == "\n"
    }.count
    let leadingNewlineCount = normalizedSections[index + 1].text.prefix { $0 == "\n" }.count
    let newlineCount = trailingNewlineCount + leadingNewlineCount
    guard newlineCount > 0 else {
      result.append(
        contentsOf: tokenizer.tokenize(
          text: normalizedSections[index].text, addSpecialTokens: false
        ).0)
      continue
    }

    // Keep a boundary newline run on one tokenizer side so BPE can merge the whole run.
    normalizedSections[index].text.removeLast(trailingNewlineCount)
    normalizedSections[index + 1].text.removeFirst(leadingNewlineCount)
    let newlines = String(repeating: "\n", count: newlineCount)
    let sectionWithNewlinesTokens = tokenizer.tokenize(
      text: normalizedSections[index].text + newlines, addSpecialTokens: false
    ).0
    let newlineTokens = tokenizer.tokenize(
      text: newlines, addSpecialTokens: false
    ).0
    // BPE only merges tokens: if the standalone newline tokens remain a suffix, no merge
    // crossed this boundary. Reuse the prefix instead of tokenizing the whole section again.
    let newlinesRemainSeparate =
      sectionWithNewlinesTokens.suffix(newlineTokens.count).elementsEqual(newlineTokens)
    if !newlinesRemainSeparate {
      normalizedSections[index].text += newlines
      result.append(contentsOf: sectionWithNewlinesTokens)
    } else {
      // Qwen and JoyAI pretokenization never merges a newline run into following text.
      result.append(contentsOf: sectionWithNewlinesTokens.dropLast(newlineTokens.count))
      normalizedSections[index + 1].text = newlines + normalizedSections[index + 1].text
    }
  }
  return result
}
