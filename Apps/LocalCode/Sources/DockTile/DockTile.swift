#if targetEnvironment(macCatalyst)
  import ExceptionCatcher
  import UIKit

  /// The app's Dock tile. Catalyst can't link AppKit, so `NSApp.dockTile`, `NSImageView`,
  /// `NSImage` and `NSWorkspace` are reached through the Objective-C runtime, as SceneDelegate
  /// does for `NSVisualEffectView`. Main queue only.
  final class DockTile {
    private let tile: NSObject
    private var imageView: NSObject?
    let size: CGSize

    init?() {
      guard
        let applicationClass = NSClassFromString("NSApplication") as? NSObject.Type,
        let tile = try? ExceptionCatcher.catch(callback: {
          (applicationClass.value(forKey: "sharedApplication") as? NSObject)?.value(
            forKey: "dockTile")
        }) as? NSObject
      else { return nil }
      self.tile = tile
      size =
        (tile.value(forKey: "size") as? NSValue)?.cgSizeValue ?? CGSize(width: 128, height: 128)
    }

    /// Draws `image` in the Dock in place of the app's icon; nil gives the Dock the icon back.
    func show(_ image: CGImage?) {
      try? ExceptionCatcher.catch {
        if let image {
          let view: NSObject
          if let imageView {
            view = imageView
          } else {
            guard let viewClass = NSClassFromString("NSImageView") as? NSObject.Type else { return }
            view = viewClass.init()
            view.setValue(NSValue(cgRect: CGRect(origin: .zero, size: size)), forKey: "frame")
            // NSImageScaleProportionallyUpOrDown.
            view.setValue(3, forKey: "imageScaling")
            tile.setValue(view, forKey: "contentView")
            imageView = view
          }
          view.setValue(Self.nsImage(image, size: size), forKey: "image")
        } else if imageView != nil {
          tile.setValue(nil, forKey: "contentView")
          imageView = nil
        }
        tile.perform(NSSelectorFromString("display"))
      }
    }

    /// `[[NSImage alloc] initWithCGImage:size:]`.
    private static func nsImage(_ image: CGImage, size: CGSize) -> AnyObject? {
      let allocSelector = NSSelectorFromString("alloc")
      let initSelector = NSSelectorFromString("initWithCGImage:size:")
      guard let imageClass = NSClassFromString("NSImage"),
        let alloc = class_getClassMethod(imageClass, allocSelector),
        let initializer = class_getInstanceMethod(imageClass, initSelector)
      else { return nil }
      typealias Alloc = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>
      typealias Initialize =
        @convention(c) (AnyObject, Selector, CGImage, CGSize) -> Unmanaged<AnyObject>?
      let allocated = unsafeBitCast(method_getImplementation(alloc), to: Alloc.self)(
        imageClass, allocSelector)
      return unsafeBitCast(method_getImplementation(initializer), to: Initialize.self)(
        allocated.takeUnretainedValue(), initSelector, image, size)?.takeRetainedValue()
    }

    /// The app's icon as the system draws it in the Dock now (appearance and icon style included):
    /// `-[NSWorkspace iconForFile:]` drawn at the tile's size on a context of `scale`.
    func appIcon(scale: CGFloat, colorSpace: CGColorSpace) -> CGImage? {
      let pixels = Int((size.width * scale).rounded())
      let makeSelector = NSSelectorFromString("graphicsContextWithCGContext:flipped:")
      let drawSelector = NSSelectorFromString("drawInRect:fromRect:operation:fraction:")
      guard
        let workspaceClass = NSClassFromString("NSWorkspace") as? NSObject.Type,
        let workspace = workspaceClass.value(forKey: "sharedWorkspace") as? NSObject,
        let icon = workspace.perform(
          NSSelectorFromString("iconForFile:"), with: Bundle.main.bundlePath)?
          .takeUnretainedValue() as? NSObject,
        let graphicsContextClass = NSClassFromString("NSGraphicsContext"),
        let make = class_getClassMethod(graphicsContextClass, makeSelector),
        let draw = class_getInstanceMethod(type(of: icon), drawSelector),
        let context = CGContext(
          data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
          space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return nil }
      context.scaleBy(x: scale, y: scale)
      typealias Make = @convention(c) (AnyClass, Selector, CGContext, Bool) -> Unmanaged<AnyObject>?
      typealias Draw = @convention(c) (AnyObject, Selector, CGRect, CGRect, UInt, CGFloat) -> Void
      guard
        let graphics = unsafeBitCast(method_getImplementation(make), to: Make.self)(
          graphicsContextClass, makeSelector, context, false)?.takeUnretainedValue()
      else { return nil }
      let contextClass = graphicsContextClass as AnyObject
      _ = contextClass.perform(NSSelectorFromString("saveGraphicsState"))
      _ = contextClass.perform(NSSelectorFromString("setCurrentContext:"), with: graphics)
      // NSCompositingOperationCopy.
      unsafeBitCast(method_getImplementation(draw), to: Draw.self)(
        icon, drawSelector, CGRect(origin: .zero, size: size), .zero, 1, 1)
      _ = contextClass.perform(NSSelectorFromString("restoreGraphicsState"))
      return context.makeImage()
    }
  }
#endif
