import Foundation
import Testing

@testable import MarkdownEngine

@Suite("Markdown code delimiters")
struct MarkdownCodeTests {
  @Test func blockKeepsNestedFencesInOneCodeBlock() throws {
    let command = """
      rm -f media/preview-day.png && cat > README.md <<'EOF'
      # Hushwood

      ## Run it

      ```sh
      python3 -m http.server 5173 --bind 127.0.0.1
      ```

      Then open <http://127.0.0.1:5173>.
      EOF
      ls -la; echo ---; ls -la media
      """
    let markdown = "**Ran**: \n\(MarkdownCode.block(command))"
    #expect(markdown.hasSuffix("\n````\n\(command)\n````"))

    let tokens = MarkdownTokenizer.parseTokensViaAST(in: markdown).filter {
      $0.kind == .codeBlock
    }
    #expect(tokens.count == 1)
    let token = try #require(tokens.first)
    #expect(
      BacktickFence.contentProjection(forCodeBlock: token, in: markdown as NSString).text
        == command + "\n")
  }

  @Test func blockUsesThreeBackticksForPlainCode() {
    #expect(MarkdownCode.block("ls\npwd") == "```\nls\npwd\n```")
  }

  @Test func inlineOutrunsBackticksInTheCode() {
    #expect(MarkdownCode.inline("ls -la") == "`ls -la`")
    #expect(MarkdownCode.inline("echo `date` && ls") == "``echo `date` && ls``")
    #expect(MarkdownCode.inline("echo `date`") == "`` echo `date` ``")
    #expect(MarkdownCode.inline("a ``b`` c") == "```a ``b`` c```")
  }

  @Test func inlineRoundTripsThroughTheParser() throws {
    for code in ["echo `date` && ls", "echo `date`", "a ``b`` c", #"ls \"#] {
      let markdown = "**Ran**: \(MarkdownCode.inline(code))"
      let token = try #require(
        MarkdownTokenizer.parseTokensViaAST(in: markdown).first { $0.kind == .inlineCode })
      #expect((markdown as NSString).substring(with: token.contentRange) == code)
    }
  }
}
