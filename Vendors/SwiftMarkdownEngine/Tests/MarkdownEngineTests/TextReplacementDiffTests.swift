import Foundation
import Testing

@testable import MarkdownEngine

@Suite("Complete-string replacement diff")
struct TextReplacementDiffTests {
  private func apply(_ diff: TextReplacementDiff, old: String, new: String) -> String {
    let replacement = (new as NSString).substring(with: diff.newRange)
    return (old as NSString).replacingCharacters(in: diff.oldRange, with: replacement)
  }

  private func apply(
    _ diff: AttributedTextReplacementDiff,
    old: NSAttributedString,
    new: NSAttributedString
  ) -> NSAttributedString {
    let result = NSMutableAttributedString(attributedString: old)
    result.replaceCharacters(
      in: diff.oldRange, with: new.attributedSubstring(from: diff.newRange))
    return result
  }

  @Test func appendUsesAnEmptyOldTailRange() throws {
    let old = "Rendered response"
    let new = "Rendered response continues"
    let diff = try #require(TextReplacementDiff(old: old, new: new))

    #expect(diff.oldRange == NSRange(location: 17, length: 0))
    #expect(diff.newRange == NSRange(location: 17, length: 10))
    #expect(diff.delta == 10)
    #expect(apply(diff, old: old, new: new) == new)
  }

  @Test func removingPrefixUsesTheSharedSuffix() throws {
    let old = "temporary prefix\n# Stable content\nBody"
    let new = "# Stable content\nBody"
    let diff = try #require(TextReplacementDiff(old: old, new: new))

    #expect(diff.oldRange == NSRange(location: 0, length: 17))
    #expect(diff.newRange == NSRange(location: 0, length: 0))
    #expect(diff.delta == -17)
    #expect(apply(diff, old: old, new: new) == new)
  }

  @Test func middleReplacementPreservesBothSides() throws {
    let old = "before **draft** after"
    let new = "before **final answer** after"
    let diff = try #require(TextReplacementDiff(old: old, new: new))

    #expect(apply(diff, old: old, new: new) == new)
    #expect(diff.delta == (new as NSString).length - (old as NSString).length)
  }

  @Test func identicalStringsHaveNoEdit() {
    #expect(TextReplacementDiff(old: "same", new: "same") == nil)
  }

  @Test func editDoesNotSplitAComposedCharacter() throws {
    let old = "A 😀 suffix"
    let new = "A 😃 suffix"
    let diff = try #require(TextReplacementDiff(old: old, new: new))

    #expect(diff.oldRange == NSRange(location: 2, length: 2))
    #expect(diff.newRange == NSRange(location: 2, length: 2))
    #expect(apply(diff, old: old, new: new) == new)
  }

  @Test func removingEmojiPrefixKeepsAValidSuffixBoundary() throws {
    let old = "👋🏽 prefix body"
    let new = "body"
    let diff = try #require(TextReplacementDiff(old: old, new: new))

    #expect(apply(diff, old: old, new: new) == new)
    #expect(diff.newRange.length == 0)
  }

  @Test func attributedAppendTouchesOnlyTheTailWhenExistingStylesMatch() throws {
    let key = NSAttributedString.Key("style")
    let old = NSAttributedString(string: "Hello", attributes: [key: "body"])
    let new = NSAttributedString(string: "Hello world", attributes: [key: "body"])
    let textDiff = try #require(TextReplacementDiff(old: old.string, new: new.string))
    let diff = AttributedTextReplacementDiff(old: old, new: new, textDiff: textDiff)

    #expect(diff.oldRange == NSRange(location: 5, length: 0))
    #expect(diff.newRange == NSRange(location: 5, length: 6))
    #expect(apply(diff, old: old, new: new).isEqual(to: new))
  }

  @Test func attributedPrefixRemovalPreservesTheStyledSuffix() throws {
    let key = NSAttributedString.Key("style")
    let old = NSMutableAttributedString(string: "prefix body", attributes: [key: "temporary"])
    old.setAttributes([key: "body"], range: NSRange(location: 7, length: 4))
    let new = NSAttributedString(string: "body", attributes: [key: "body"])
    let textDiff = try #require(TextReplacementDiff(old: old.string, new: new.string))
    let diff = AttributedTextReplacementDiff(old: old, new: new, textDiff: textDiff)

    #expect(diff.oldRange == NSRange(location: 0, length: 7))
    #expect(diff.newRange == NSRange(location: 0, length: 0))
    #expect(apply(diff, old: old, new: new).isEqual(to: new))
  }

  @Test func attributedDiffWidensWhenMarkdownStyleChangesOutsideTextEdit() throws {
    let key = NSAttributedString.Key("style")
    let old = NSAttributedString(string: "before draft after", attributes: [key: "body"])
    let new = NSMutableAttributedString(
      string: "before final after", attributes: [key: "body"])
    new.setAttributes([key: "emphasis"], range: NSRange(location: 0, length: 12))
    let textDiff = try #require(TextReplacementDiff(old: old.string, new: new.string))
    let diff = AttributedTextReplacementDiff(old: old, new: new, textDiff: textDiff)

    #expect(diff.oldRange.location == 0)
    #expect(diff.newRange.location == 0)
    #expect(apply(diff, old: old, new: new).isEqual(to: new))
  }

  @Test func appendAndPrefixRemovalDescriptorsMatchFullMarkdownParse() throws {
    let state = DocumentParseState()
    let initial = "temporary prefix\n# Answer\nBody"
    _ = state.tokens(for: initial, edit: nil)

    let withoutPrefix = "# Answer\nBody"
    let prefixDiff = try #require(TextReplacementDiff(old: initial, new: withoutPrefix))
    let prefixTokens = state.tokens(
      for: withoutPrefix,
      edit: ParseEditDescriptor(editedRange: prefixDiff.newRange, delta: prefixDiff.delta)
    )
    let expectedPrefixTokens = MarkdownTokenizer.fullTokens(
      blocks: BlockParser.computeBlocks(withoutPrefix), ns: withoutPrefix as NSString)
    #expect(tokenDump(prefixTokens) == tokenDump(expectedPrefixTokens))

    let appended = withoutPrefix + "\n\n**Continued**"
    let appendDiff = try #require(TextReplacementDiff(old: withoutPrefix, new: appended))
    let appendTokens = state.tokens(
      for: appended,
      edit: ParseEditDescriptor(editedRange: appendDiff.newRange, delta: appendDiff.delta)
    )
    let expectedAppendTokens = MarkdownTokenizer.fullTokens(
      blocks: BlockParser.computeBlocks(appended), ns: appended as NSString)
    #expect(tokenDump(appendTokens) == tokenDump(expectedAppendTokens))
  }

  private func tokenDump(_ tokens: [MarkdownToken]) -> [String] {
    tokens.map { token in
      "\(token.kind)|\(token.range)|\(token.contentRange)|\(token.markerRanges)"
    }
  }
}
