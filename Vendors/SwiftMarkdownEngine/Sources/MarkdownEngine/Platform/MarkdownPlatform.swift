#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

#if canImport(UIKit)

  public typealias NSColor = UIColor
  public typealias NSFont = UIFont
  public typealias NSImage = UIImage
  public typealias NSPasteboard = UIPasteboard

  extension UIColor {
    public static var labelColor: UIColor { .label }
    public static var secondaryLabelColor: UIColor { .secondaryLabel }
    public static var tertiaryLabelColor: UIColor { .tertiaryLabel }
    public static var linkColor: UIColor { .link }
    public static var textBackgroundColor: UIColor { .clear }
  }
#elseif canImport(AppKit)

  typealias MarkdownTextView = NativeTextView
#endif

enum MarkdownLayoutMetrics {
  /// Nonzero because a zero paragraph height means "use the natural line height".
  static let collapsedSourceLineHeight: CGFloat = 1e-5
}
