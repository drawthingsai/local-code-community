#if !SWIFT_PACKAGE
  import Foundation

  private final class SwiftMathBundleToken {}

  extension Bundle {
    static var module: Bundle {
      Bundle(for: SwiftMathBundleToken.self)
    }
  }
#endif
