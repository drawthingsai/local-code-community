import Foundation
import UIKit

public enum FontSizeCategory: CGFloat {
  case extraSmall = 0.9
  case small = 1
  case normal = 1.15
  case large = 1.3
  case extraLarge = 1.45
}

final class ScalableFontHandler: NSObject {
  let originalFont: UIFont
  let scaleFont: (NSObject, UIFont) -> Void
  init(font: UIFont, scaleFont: @escaping (NSObject, UIFont) -> Void) {
    self.originalFont = font
    self.scaleFont = scaleFont
  }
}

public final class FontMetrics {
  public static let systemDefaultFontSizeCategory: FontSizeCategory = {
    #if targetEnvironment(macCatalyst)
      return .normal
    #else
      return .small
    #endif
  }()
  private var views: NSMapTable<AnyObject, NSMutableArray> = NSMapTable<AnyObject, NSMutableArray>
    .weakToStrongObjects()
  public static let `default`: FontMetrics = {
    let fontMetrics = FontMetrics()
    if let currentFontScale = UserDefaults.standard.object(forKey: "AppFontSize") as? CGFloat,
      let fontSize = FontSizeCategory(rawValue: currentFontScale)
    {
      fontMetrics.size = fontSize
    }
    return fontMetrics
  }()

  private static let defaultButtonFontScaler = { (button: UIButton, font: UIFont) -> Void in
    var configuration = button.configuration
    configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
      var outgoing = $0
      outgoing.font = font
      return outgoing
    }
    button.configuration = configuration
  }

  private static let defaultLabelFonScaler = { (label: UILabel, font: UIFont) -> Void in
    label.font = font
  }

  public var size: FontSizeCategory {
    didSet {
      dispatchPrecondition(condition: .onQueue(.main))
      UserDefaults.standard.set(size.rawValue, forKey: "AppFontSize")
      updateFontMetrics()
    }
  }

  public init() {
    size = Self.systemDefaultFontSizeCategory
  }

  public func scaleFont<T: AnyObject>(
    _ font: UIFont, bindTo view: T, scaleFontHandler: @escaping (T, UIFont) -> Void
  ) {
    scaleFontHandler(
      view,
      font.withSize(font.pointSize * size.rawValue))
    guard let handlers = views.object(forKey: view) else {
      views.setObject(
        NSMutableArray(
          object: ScalableFontHandler(font: font) { object, font in
            scaleFontHandler(object as! T, font)
          }),
        forKey: view)
      return
    }
    handlers.add(
      ScalableFontHandler(font: font) { object, font in
        scaleFontHandler(object as! T, font)
      })
  }

  public func scaleFont(_ font: UIFont, bindTo button: UIButton) {
    scaleFont(font, bindTo: button, scaleFontHandler: FontMetrics.defaultButtonFontScaler)
  }

  public func scaleFont(_ font: UIFont, bindTo label: UILabel) {
    scaleFont(font, bindTo: label, scaleFontHandler: FontMetrics.defaultLabelFonScaler)
  }

  public func clearBinding<T: AnyObject>(to view: T) {
    views.removeObject(forKey: view)
  }

  private func updateFontMetrics() {
    dispatchPrecondition(condition: .onQueue(.main))
    let keyEnumerator = views.keyEnumerator()
    while let view = keyEnumerator.nextObject() as? NSObject {
      guard let handlers = views.object(forKey: view) else { continue }
      for case let handler as ScalableFontHandler in handlers {
        handler.scaleFont(
          view,
          handler.originalFont.withSize(handler.originalFont.pointSize * size.rawValue))
      }
    }
  }
}
