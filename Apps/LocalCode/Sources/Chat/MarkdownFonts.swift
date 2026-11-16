import CoreText
import Style
import UIKit
import os

/// The text and code fonts of messages and the chat input. Machine Settings writes the choices to
/// the workspace dictionary as `text_font` and `code_font`, and ChatWorkflow sets them here. A
/// choice is a font family name, and nil is the system font.
final class MarkdownFonts {
  static let `default` = MarkdownFonts()

  /// The text fonts offered besides the system font, in menu order. Only the bundled fonts present
  /// are offered: builds from the public repository have no Tiempos Text or Elena.
  let textFamilies: [String]
  /// The code fonts offered besides SF Mono, in menu order. Menlo comes with the system.
  let codeFamilies: [String]

  // Elena's lowercase letters are about 12% shorter than SF's at the same point size, so it is
  // drawn larger to look the size the font size setting asks for.
  private static let textScales: [String: CGFloat] = ["Elena": 1.14]

  private struct State {
    var textFamily: String?
    var codeFamily: String?
    var codeFonts: [CGFloat: UIFont] = [:]
  }

  // The syntax highlighter asks for code fonts while styling, which may happen off the main queue.
  private let state: OSAllocatedUnfairLock<State>

  private init() {
    // Registering the fonts bundled under Fonts/ for this process makes them available by family
    // name, like installed fonts.
    if let fontsURL = Bundle.main.resourceURL?.appendingPathComponent("Fonts", isDirectory: true),
      let enumerator = FileManager.default.enumerator(
        at: fontsURL, includingPropertiesForKeys: nil)
    {
      for case let url as URL in enumerator where ["otf", "ttf"].contains(url.pathExtension) {
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
      }
    }
    textFamilies = ["Tiempos Text", "Elena"].filter(Self.isAvailable)
    codeFamilies = ["Menlo", "JetBrains Mono"].filter(Self.isAvailable)
    state = OSAllocatedUnfairLock(initialState: State())
  }

  static func isAvailable(_ family: String) -> Bool {
    !UIFont.fontNames(forFamilyName: family).isEmpty
  }

  /// A family that is not available, as when a font chosen with the font picker was uninstalled,
  /// leaves the system font.
  var textFamily: String? {
    get { state.withLock { $0.textFamily } }
    set {
      dispatchPrecondition(condition: .onQueue(.main))
      let family = newValue.flatMap { Self.isAvailable($0) ? $0 : nil }
      guard family != textFamily else { return }
      state.withLock { $0.textFamily = family }
      // The text views set their base font from textFont(replacing:) in their font size bindings.
      FontMetrics.default.updateFontMetrics()
    }
  }

  /// A family that is not available leaves SF Mono.
  var codeFamily: String? {
    get { state.withLock { $0.codeFamily } }
    set {
      dispatchPrecondition(condition: .onQueue(.main))
      let family = newValue.flatMap { Self.isAvailable($0) ? $0 : nil }
      guard family != codeFamily else { return }
      state.withLock {
        $0.codeFamily = family
        $0.codeFonts = [:]
      }
      // Setting the base font again restyles a text view, which asks for its code fonts anew.
      FontMetrics.default.updateFontMetrics()
    }
  }

  /// The text font in place of `font`, the regular system font at the size the font size setting
  /// gives.
  func textFont(replacing font: UIFont) -> UIFont {
    guard let family = textFamily else { return font }
    return UIFont(
      descriptor: UIFontDescriptor(fontAttributes: [.family: family]),
      size: font.pointSize * (Self.textScales[family] ?? 1))
  }

  /// The chosen code font, or nil for SF Mono, which the syntax highlighter supplies.
  func codeFont(size: CGFloat) -> UIFont? {
    state.withLock { state in
      guard let family = state.codeFamily else { return nil }
      if let font = state.codeFonts[size] {
        return font
      }
      let font = UIFont(descriptor: UIFontDescriptor(fontAttributes: [.family: family]), size: size)
      state.codeFonts[size] = font
      return font
    }
  }
}
