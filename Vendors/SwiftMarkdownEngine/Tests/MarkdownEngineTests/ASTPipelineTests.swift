//
//  ASTPipelineTests.swift
//  MarkdownEngineTests
//
//  Phase 2.5 — end-to-end checks that the full AST pipeline (BlockParser +
//  InlineParser + adapter) fixes the bugs the characterization latch pinned.
//

import Foundation
import Testing

@testable import MarkdownEngine

@Suite("Phase 2.5 — AST pipeline end-to-end")
struct ASTPipelineTests {

  @Test("bug 2: no inline markup tokens inside a fenced code block")
  func bug2InlineInsideCode() {
    let text = "```swift\n*not italic* `not code`\n```\n"
    let tokens = MarkdownTokenizer.parseTokensViaAST(in: text)
    #expect(!tokens.isEmpty)
    #expect(tokens.allSatisfy { $0.kind == .codeBlock })
  }

  @Test("indented fence preserves code, marker, and language ranges")
  func indentedFenceRanges() throws {
    let text = "   ```bash\n   curl\n   ```\n"
    let token = try #require(MarkdownTokenizer.parseTokensViaAST(in: text).first)

    #expect(token.kind == .codeBlock)
    #expect((text as NSString).substring(with: token.contentRange) == "   curl\n")
    #expect(token.markerRanges.count == 2)
    #expect((text as NSString).substring(with: token.markerRanges[0]) == "   ```bash\n")
    #expect((text as NSString).substring(with: token.markerRanges[1]) == "   ```")
    #expect(
      BacktickFence.contentProjection(forCodeBlock: token, in: text as NSString).text == "curl\n"
    )
    #expect(MarkdownTokenizer.extractLanguage(from: token, in: text) == "bash")
  }

  @Test(#"block LaTeX is opaque: no inline tokens inside $$…$$ or \[…\]"#)
  func blockLatexIsOpaque() {
    for text in ["$$\n\\{x\\} *a* `b`\n$$", "\\[\n\\{x\\} *a* `b`\n\\]"] {
      #expect(MarkdownTokenizer.parseTokensViaAST(in: text).map(\.kind) == [.blockLatex])
    }
  }

  @Test("text beside a $$…$$ on its line is still parsed inline")
  func textBesideBlockLatex() {
    let tokens = MarkdownTokenizer.parseTokensViaAST(in: "$$\\{1\\}$$ and **bold**")
    #expect(tokens.map(\.kind) == [.blockLatex, .bold])
  }

  @Test(#"a \[ … \] block token covers the delimiters and holds the math"#)
  func bracketBlockLatexToken() throws {
    let text = "   \\[\n   a = b\n   \\]\n"
    let ns = text as NSString
    let token = try #require(MarkdownTokenizer.parseTokensViaAST(in: text).first)

    #expect(token.kind == .blockLatex)
    #expect(ns.substring(with: token.range) == "\\[\n   a = b\n   \\]")
    #expect(ns.substring(with: token.contentRange) == "\n   a = b\n   ")
    #expect(token.markerRanges.map { ns.substring(with: $0) } == ["\\[", "\\]"])
    #expect(token.standaloneParagraphRange(in: ns) != nil)
  }

  @Test(#"\(math\) is an inline LaTeX token whose content is the math alone"#)
  func parenthesizedLatexToken() throws {
    let text = "so \\( a\\,b \\) holds"
    let ns = text as NSString
    let tokens = MarkdownTokenizer.parseTokensViaAST(in: text)

    #expect(tokens.map(\.kind) == [.inlineLatex])
    let token = try #require(tokens.first)
    #expect(ns.substring(with: token.contentRange) == "a\\,b")
    #expect(token.markerRanges.map { ns.substring(with: $0) } == ["\\( ", " \\)"])
  }

  @Test("a link whose text is inline code is a link token with a code token inside")
  func linkWithCodeText() throws {
    let text = "see [`parse()`](src/my\\_file.swift) here"
    let ns = text as NSString
    let tokens = MarkdownTokenizer.parseTokensViaAST(in: text)

    #expect(tokens.map(\.kind) == [.link, .inlineCode])
    let link = try #require(tokens.first)
    #expect(ns.substring(with: link.contentRange) == "`parse()`")
    // The destination is what lies between the token's own parentheses.
    let urlStart = NSMaxRange(link.markerRanges[2])
    let url = ns.substring(
      with: NSRange(location: urlStart, length: link.markerRanges[3].location - urlStart))
    #expect(url == "src/my\\_file.swift")
    #expect(normalizedMarkdownLinkDestination(url) == "src/my_file.swift")
  }

  @Test("a link destination resolves its escape pairs")
  func linkDestinationEscapes() {
    #expect(normalizedMarkdownLinkDestination(#"a\_b\(c\).md"#) == "a_b(c).md")
    #expect(normalizedMarkdownLinkDestination(#" <my\_file.md> "#) == "my_file.md")
    // A backslash before anything but ASCII punctuation is a backslash.
    #expect(normalizedMarkdownLinkDestination(#"C:\Users\x\_y"#) == #"C:\Users\x_y"#)
    #expect(normalizedMarkdownLinkDestination(#"a\\b\"#) == #"a\b\"#)
    #expect(normalizedMarkdownLinkDestination("plain/path.md") == "plain/path.md")
  }

  @Test("bug 4: a link with balanced parens in the URL is one whole link token")
  func bug4LinkParens() {
    let tokens = MarkdownTokenizer.parseTokensViaAST(in: "see [w](a(b)) end")
    let link = tokens.first { $0.kind == .link }
    #expect(link?.range == NSRange(location: 4, length: 9))
  }

  @Test("bug 3: no spurious latex token across code spans")
  func bug3CrossCodeLatex() {
    let tokens = MarkdownTokenizer.parseTokensViaAST(in: "the `$a` and `$b` vars")
    #expect(!tokens.contains { $0.kind == .inlineLatex })
    #expect(tokens.filter { $0.kind == .inlineCode }.count == 2)
  }

  @Test("block-level tokens are preserved (heading + emphasis in the title)")
  func headingPlusInline() {
    let tokens = MarkdownTokenizer.parseTokensViaAST(in: "# Title *x*")
    #expect(tokens.contains { $0.kind == .heading })
    #expect(tokens.contains { $0.kind == .italic })
  }
}
