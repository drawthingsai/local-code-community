//
//  BacktickFenceTests.swift
//  MarkdownEngineTests
//

import Foundation
import Testing

@testable import MarkdownEngine

@Suite("CommonMark backtick fence indentation")
struct BacktickFenceTests {

  private func codeToken(in source: String) throws -> MarkdownToken {
    try #require(
      MarkdownTokenizer.parseTokensViaAST(in: source).first(where: { $0.kind == .codeBlock })
    )
  }

  private func projectedContent(in source: String) throws -> BacktickFence.ContentProjection {
    let token = try codeToken(in: source)
    return BacktickFence.contentProjection(forCodeBlock: token, in: source as NSString)
  }

  @Test("examples 101–103: opening indentation removes up to that many spaces per line")
  func openingIndentationDedentsContent() throws {
    let examples = [
      (" ```\n aaa\naaa\n```\n", "aaa\naaa\n"),
      ("  ```\naaa\n  aaa\naaa\n  ```\n", "aaa\naaa\naaa\n"),
      ("   ```\n   aaa\n    aaa\n  aaa\n   ```\n", "aaa\n aaa\naaa\n"),
    ]

    for (source, expected) in examples {
      #expect(try projectedContent(in: source).text == expected)
    }
  }

  @Test("examples 105–106: closing indentation is independent of opening indentation")
  func closingIndentationIsIndependent() throws {
    #expect(try projectedContent(in: "```\naaa\n  ```\n").text == "aaa\n")
    #expect(try projectedContent(in: "   ```\naaa\n  ```\n").text == "aaa\n")
  }

  @Test("example 104: four spaces do not open a fenced block")
  func fourSpacesDoNotOpenFence() {
    let source = "    ```\n    aaa\n    ```\n"
    #expect(!BlockParser.parse(source).contains { $0.kind == .fencedCode })
    #expect(!MarkdownTokenizer.parseTokensViaAST(in: source).contains { $0.kind == .codeBlock })
  }

  @Test("example 107 leading-space rule: four spaces do not close a fenced block")
  func fourSpacesDoNotCloseFence() throws {
    // The final valid closer keeps this engine's existing closed-fence requirement
    // while proving the four-space line remains code content.
    let source = "```\naaa\n    ```\n```\n"
    let token = try codeToken(in: source)
    #expect((source as NSString).substring(with: token.markerRanges[1]) == "```")
    #expect(
      BacktickFence.contentProjection(forCodeBlock: token, in: source as NSString).text
        == "aaa\n    ```\n")
  }

  @Test("examples 119–120: a closer needs at least as many backticks as the opener")
  func shorterRunDoesNotClose() throws {
    let source = "````\naaa\n```\n``````\n"
    let token = try codeToken(in: source)
    #expect((source as NSString).substring(with: token.markerRanges[1]) == "``````")
    #expect(token.range == NSRange(location: 0, length: (source as NSString).length - 1))
    #expect(
      BacktickFence.contentProjection(forCodeBlock: token, in: source as NSString).text
        == "aaa\n```\n")
  }

  @Test("example 126 closing rule: a fence with an info string does not close")
  func infoStringDoesNotClose() throws {
    let source = "```\naaa\n```sh\nbbb\n```\n"
    let token = try codeToken(in: source)
    #expect(
      BacktickFence.contentProjection(forCodeBlock: token, in: source as NSString).text
        == "aaa\n```sh\nbbb\n")
  }

  @Test("a longer fence keeps a nested fenced block as one code block")
  func longerFenceWrapsNestedFence() throws {
    let source = """
      **Ran**:
      ````
      cat > README.md <<'EOF'
      ## Run it

      ```sh
      python3 -m http.server 5173
      ```

      Then open the page.
      EOF
      ls -la
      ````
      """
    let blocks = BlockParser.parse(source).filter { $0.kind == .fencedCode }
    #expect(blocks.count == 1)
    let tokens = MarkdownTokenizer.parseTokensViaAST(in: source).filter {
      $0.kind == .codeBlock
    }
    #expect(tokens.count == 1)
    let token = try #require(tokens.first)
    #expect(NSMaxRange(token.range) == (source as NSString).length)
    #expect(
      BacktickFence.contentProjection(forCodeBlock: token, in: source as NSString).text
        == """
        cat > README.md <<'EOF'
        ## Run it

        ```sh
        python3 -m http.server 5173
        ```

        Then open the page.
        EOF
        ls -la

        """)
    #expect(MarkdownTokenizer.extractLanguage(from: token, in: source) == nil)
  }

  @Test("the language follows the whole opening run")
  func languageAfterLongerOpener() throws {
    let source = "````swift\nlet x = 1\n````\n"
    let token = try codeToken(in: source)
    #expect(MarkdownTokenizer.extractLanguage(from: token, in: source) == "swift")
  }

  @Test("a tab before a top-level fence reaches indented-code territory")
  func tabDoesNotOpenFence() {
    for source in ["\t```\ncode\n```\n", " \t```\ncode\n```\n"] {
      #expect(!BlockParser.parse(source).contains { $0.kind == .fencedCode })
    }
  }

  @Test("normalized syntax ranges map around removed source indentation")
  func normalizedRangesMapToSource() throws {
    let source = "   ```\n   aaa\n    aaa\n  aaa\n   ```\n"
    let projection = try projectedContent(in: source)

    #expect(projection.text == "aaa\n aaa\naaa\n")
    #expect(
      projection.removedIndentRanges == [
        NSRange(location: 7, length: 3),
        NSRange(location: 14, length: 3),
        NSRange(location: 22, length: 2),
      ])
    #expect(
      projection.sourceRanges(
        for: NSRange(location: 0, length: (projection.text as NSString).length)
      ) == [
        NSRange(location: 10, length: 4),
        NSRange(location: 17, length: 5),
        NSRange(location: 24, length: 4),
      ])
  }
}
