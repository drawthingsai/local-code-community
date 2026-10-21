import Dispatch
import Foundation
import MarkdownEngine
import MarkdownEngineCodeBlocks

private struct TransientMarkdownSyntaxHighlighter: SyntaxHighlighter {
  let base: any SyntaxHighlighter
  private let codeFontCache = NSCache<NSNumber, NSFont>()

  func codeFont(size: CGFloat) -> NSFont {
    let key = NSNumber(value: Double(size))
    if let font = codeFontCache.object(forKey: key) {
      return font
    }
    let font = base.codeFont(size: size)
    codeFontCache.setObject(font, forKey: key)
    return font
  }

  func backgroundColor() -> NSColor {
    base.backgroundColor()
  }

  func highlight(code: String, language: String?) -> NSAttributedString? {
    nil
  }

  var appearanceDidChangeNotification: Notification.Name? {
    base.appearanceDidChangeNotification
  }
}

enum MarkdownSyntaxHighlighter {
  static let shared = HighlighterSwiftBridge()
  static let transient: any SyntaxHighlighter = TransientMarkdownSyntaxHighlighter(base: shared)
}
