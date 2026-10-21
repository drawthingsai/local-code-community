#if targetEnvironment(macCatalyst)
  import CoreImage
  import ExceptionCatcher
  import UIKit

  extension UIWindow {
    /// The AppKit window hosting this window, found through the runtime because AppKit is
    /// unavailable to Mac Catalyst at compile time. Nil until the window is on screen.
    public var hostingNSWindow: NSObject? {
      try? ExceptionCatcher.catch {
        guard
          let windows = NSClassFromString("NSApplication")?.value(
            forKeyPath: "sharedApplication.windows") as? [NSObject]
        else { return nil }
        return windows.first {
          // Plain AppKit windows, rim glows among them, throw when asked for UIKit windows.
          $0.responds(to: NSSelectorFromString("uiWindows"))
            && ($0.value(forKeyPath: "uiWindows") as? [UIWindow] ?? []).contains(self)
        }
      }
    }
  }

  /// Draws `RimGlowWashes` outside a window, where its shadow would be, and turns that shadow
  /// off. A window cannot draw past its frame, so the glow is a borderless, transparent,
  /// click-through AppKit window ordered just below it as a child: AppKit moves and reorders it
  /// with the window, and it is re-framed whenever the window resizes.
  public final class RimGlowWindowController {
    private static let size: CGFloat = 20
    private static let strength: Float = 0.6
    /// Fallback for the window's corner radius when AppKit does not report one.
    private static let defaultCornerRadius: CGFloat = 16

    private weak var window: UIWindow?
    private var hostWindow: NSObject?
    private var glowWindow: NSObject?
    private let rootLayer = CALayer()
    private let maskLayer = CALayer()
    private let washes = RimGlowWashes()
    private var observers = [NSObjectProtocol]()
    private var maskScale: CGFloat = 0

    public init(window: UIWindow) {
      self.window = window
      rootLayer.opacity = Self.strength
      rootLayer.addSublayer(washes.layer)
      rootLayer.mask = maskLayer
    }

    /// Catalyst hosts the window in AppKit shortly after it becomes visible, so this retries
    /// for up to two seconds.
    public func attach(attempt: Int = 0) {
      guard glowWindow == nil, let window else { return }
      guard let host = window.hostingNSWindow else {
        guard attempt < 40 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
          self?.attach(attempt: attempt + 1)
        }
        return
      }
      guard let glow = Self.makeGlowWindow(containing: rootLayer) else { return }
      hostWindow = host
      glowWindow = glow
      host.setValue(false, forKey: "hasShadow")
      Self.addChild(glow, to: host)
      let center = NotificationCenter.default
      for name in [
        "NSWindowDidResizeNotification", "NSWindowDidEndLiveResizeNotification",
        "NSWindowDidChangeBackingPropertiesNotification",
      ] {
        observers.append(
          center.addObserver(forName: Notification.Name(name), object: host, queue: .main) {
            [weak self] _ in
            self?.layout()
          })
      }
      // A full-screen window has no edge to glow around.
      observers.append(
        center.addObserver(
          forName: Notification.Name("NSWindowWillEnterFullScreenNotification"), object: host,
          queue: .main
        ) { [weak self] _ in
          self?.glowWindow?.perform(NSSelectorFromString("orderOut:"), with: nil)
        })
      observers.append(
        center.addObserver(
          forName: Notification.Name("NSWindowDidExitFullScreenNotification"), object: host,
          queue: .main
        ) { [weak self] _ in
          guard let self, let hostWindow = self.hostWindow, let glowWindow = self.glowWindow
          else { return }
          Self.addChild(glowWindow, to: hostWindow)
          self.layout()
        })
      washes.addAnimations()
      layout()
    }

    public func detach() {
      observers.forEach { NotificationCenter.default.removeObserver($0) }
      observers.removeAll()
      washes.removeAnimations()
      if let hostWindow, let glowWindow {
        hostWindow.perform(NSSelectorFromString("removeChildWindow:"), with: glowWindow)
        glowWindow.perform(NSSelectorFromString("orderOut:"), with: nil)
      }
      hostWindow = nil
      glowWindow = nil
    }

    private func layout() {
      guard let hostWindow, let glowWindow else { return }
      // Twice the glow size leaves room for the blur's falloff.
      let margin = ceil(Self.size * 2)
      let frame = Self.frame(of: hostWindow).insetBy(dx: -margin, dy: -margin)
      let selector = NSSelectorFromString("setFrame:display:")
      typealias SetFrame = @convention(c) (AnyObject, Selector, CGRect, Bool) -> Void
      unsafeBitCast(glowWindow.method(for: selector), to: SetFrame.self)(
        glowWindow, selector, frame, true)
      let bounds = CGRect(origin: .zero, size: frame.size)
      let scale = glowWindow.value(forKey: "backingScaleFactor") as? CGFloat ?? 2
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      rootLayer.frame = bounds
      maskLayer.frame = bounds
      washes.layout(in: bounds)
      if scale != maskScale {
        let radius =
          (try? ExceptionCatcher.catch { hostWindow.value(forKey: "_cornerRadius") as? CGFloat })
          .flatMap { $0 } ?? Self.defaultCornerRadius
        if let mask = Self.maskImage(margin: margin, radius: radius, scale: scale) {
          maskScale = scale
          maskLayer.contents = mask.image
          maskLayer.contentsScale = scale
          maskLayer.contentsCenter = mask.center
        }
      }
      CATransaction.commit()
    }

    /// The window's rounded rect, grown by 0.3 of the glow size and blurred by half of it.
    /// Rendered once as a nine-slice: its stretchable middle is far enough from the corners
    /// that the blur there is a straight edge's, so resizing never redraws it.
    private static func maskImage(
      margin: CGFloat, radius: CGFloat, scale: CGFloat
    ) -> (image: CGImage, center: CGRect)? {
      let spread = size * 0.3
      let sigma = size * 0.5
      let side = ((margin + radius + sigma * 3) * 2 + 1).rounded(.up)
      let bounds = CGRect(x: 0, y: 0, width: side, height: side)
      let format = UIGraphicsImageRendererFormat.preferred()
      format.scale = scale
      let shape = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
        UIColor.black.setFill()
        UIBezierPath(
          roundedRect: bounds.insetBy(dx: margin - spread, dy: margin - spread),
          cornerRadius: radius + spread
        ).fill()
      }
      guard let shapeImage = shape.cgImage else { return nil }
      let input = CIImage(cgImage: shapeImage)
      let blurred = input.clampedToExtent().applyingGaussianBlur(sigma: Double(sigma * scale))
        .cropped(to: input.extent)
      guard let image = CIContext().createCGImage(blurred, from: input.extent) else {
        return nil
      }
      let middle = 0.5 - 0.5 / side
      return (image, CGRect(x: middle, y: middle, width: 1 / side, height: 1 / side))
    }

    private static func makeGlowWindow(containing layer: CALayer) -> NSObject? {
      guard let windowClass = NSClassFromString("NSWindow") as? NSObject.Type,
        let clearColor = (NSClassFromString("NSColor") as? NSObject.Type)?.value(
          forKey: "clearColor")
      else { return nil }
      return try? ExceptionCatcher.catch { () -> NSObject? in
        let glow = windowClass.init()
        glow.setValue(0, forKey: "styleMask")  // Borderless.
        glow.setValue(false, forKey: "opaque")
        glow.setValue(clearColor, forKey: "backgroundColor")
        glow.setValue(false, forKey: "hasShadow")
        glow.setValue(true, forKey: "ignoresMouseEvents")
        glow.setValue(false, forKey: "releasedWhenClosed")
        glow.setValue(2, forKey: "animationBehavior")  // NSWindowAnimationBehaviorNone.
        // Transient and ignoresCycle: out of Mission Control's groups and window cycling.
        glow.setValue((1 << 3) | (1 << 6), forKey: "collectionBehavior")
        guard let contentView = glow.value(forKey: "contentView") as? NSObject else { return nil }
        contentView.setValue(true, forKey: "wantsLayer")
        guard let contentLayer = contentView.value(forKey: "layer") as? CALayer else {
          return nil
        }
        contentLayer.addSublayer(layer)
        return glow
      }.flatMap { $0 }
    }

    private static func addChild(_ child: NSObject, to parent: NSObject) {
      let selector = NSSelectorFromString("addChildWindow:ordered:")
      typealias AddChildWindow = @convention(c) (AnyObject, Selector, AnyObject, Int) -> Void
      _ = try? ExceptionCatcher.catch {
        // NSWindowBelow.
        unsafeBitCast(parent.method(for: selector), to: AddChildWindow.self)(
          parent, selector, child, -1)
      }
    }

    private static func frame(of window: NSObject) -> CGRect {
      (window.value(forKey: "frame") as? NSValue)?.cgRectValue ?? .zero
    }
  }
#endif
