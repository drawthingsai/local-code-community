import Dispatch
import Foundation
import MarkdownEngine
import MarkdownEngineCodeBlocks

/// HighlighterSwift's colors and code-block background with the code font chosen in Machine
/// Settings.
private struct CodeFontSyntaxHighlighter: SyntaxHighlighter {
  let base: HighlighterSwiftBridge
  /// Thinking text skips highlighting.
  let highlightsCode: Bool

  func codeFont(size: CGFloat) -> NSFont {
    MarkdownFonts.default.codeFont(size: size) ?? base.codeFont(size: size)
  }

  func backgroundColor() -> NSColor {
    base.backgroundColor()
  }

  func highlight(code: String, language: String?) -> NSAttributedString? {
    highlightsCode ? base.highlight(code: code, language: language) : nil
  }

  var appearanceDidChangeNotification: Notification.Name? {
    base.appearanceDidChangeNotification
  }
}

enum MarkdownSyntaxHighlighter {
  private static let bridge = HighlighterSwiftBridge()
  static let shared: any SyntaxHighlighter = CodeFontSyntaxHighlighter(
    base: bridge, highlightsCode: true)
  static let transient: any SyntaxHighlighter = CodeFontSyntaxHighlighter(
    base: bridge, highlightsCode: false)
}
