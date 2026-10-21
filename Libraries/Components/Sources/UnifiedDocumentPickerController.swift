import UIKit
import UniformTypeIdentifiers

#if targetEnvironment(macCatalyst)
  import ExceptionCatcher
  import ObjectiveC
#endif

public protocol UnifiedDocumentPickerControllerDelegate: AnyObject {
  func documentPicker(_ controller: UnifiedDocumentPickerController, didPickDocumentsAt urls: [URL])
  func documentPickerWasCancelled(_ controller: UnifiedDocumentPickerController)
}

extension UnifiedDocumentPickerControllerDelegate {
  public func documentPickerWasCancelled(_ controller: UnifiedDocumentPickerController) {}
}

/// Folder access prefers AppKit on Catalyst; other modes use UIKit.
public final class UnifiedDocumentPickerController {
  public weak var delegate: UnifiedDocumentPickerControllerDelegate?
  public var title: String? {
    get { picker.title }
    set { picker.title = newValue }
  }
  public var directoryURL: URL? {
    get { picker.directoryURL }
    set { picker.directoryURL = newValue }
  }
  public var allowsMultipleSelection: Bool {
    get { picker.allowsMultipleSelection }
    set { picker.allowsMultipleSelection = newValue }
  }

  private let picker: UIDocumentPickerViewController
  private let responder = ObjCResponder()
  private let prefersNativeFolderPicker: Bool
  #if targetEnvironment(macCatalyst)
    private var nativePanel: NSObject?
  #endif

  private final class ObjCResponder: NSObject, UIDocumentPickerDelegate {
    // Keeps the unified controller alive until a selection or cancellation callback.
    var controller: UnifiedDocumentPickerController?

    func documentPicker(
      _ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]
    ) {
      self.controller?.finish(urls)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
      self.controller?.finish(nil)
    }
  }

  public init(forOpeningContentTypes contentTypes: [UTType], asCopy: Bool = false) {
    picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: asCopy)
    prefersNativeFolderPicker = contentTypes == [.folder] && !asCopy
    picker.delegate = responder
  }

  public init(forExporting urls: [URL], asCopy: Bool = false) {
    picker = UIDocumentPickerViewController(forExporting: urls, asCopy: asCopy)
    prefersNativeFolderPicker = false
    picker.delegate = responder
  }

  fileprivate func present(
    from viewController: UIViewController, animated: Bool,
    completion: (() -> Void)? = nil
  ) -> Bool {
    dispatchPrecondition(condition: .onQueue(.main))
    guard responder.controller == nil, viewController.viewIfLoaded?.window != nil,
      viewController.presentedViewController == nil
    else { return false }
    responder.controller = self
    #if targetEnvironment(macCatalyst)
      if prefersNativeFolderPicker, presentAppKit() {
        completion?()
        return true
      }
      // A synchronous delegate callback must not be followed by another picker.
      guard responder.controller != nil else { return true }
    #endif
    viewController.present(picker, animated: animated, completion: completion)
    return true
  }

  private func finish(_ urls: [URL]?) {
    guard responder.controller != nil else { return }
    responder.controller = nil
    #if targetEnvironment(macCatalyst)
      nativePanel = nil
    #endif
    if let urls {
      delegate?.documentPicker(self, didPickDocumentsAt: urls)
    } else {
      delegate?.documentPickerWasCancelled(self)
    }
  }

  /// Dismissing a pending request reports cancellation through the delegate.
  public func dismiss(animated: Bool, completion: (() -> Void)? = nil) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard responder.controller != nil else {
      completion?()
      return
    }
    #if targetEnvironment(macCatalyst)
      if let panel = nativePanel {
        nativePanel = nil
        _ = try? ExceptionCatcher.catch { panel.perform(NSSelectorFromString("close")) }
        finish(nil)
        completion?()
        return
      }
    #endif
    picker.dismiss(animated: animated) { [self] in
      finish(nil)
      completion?()
    }
  }

  #if targetEnvironment(macCatalyst)
    private func presentAppKit() -> Bool {
      // AppKit is unavailable in the Catalyst SDK. Keep runtime access optional and fall back to UIKit.
      let opened =
        (try? ExceptionCatcher.catch { () -> Bool in
          let factorySelector = NSSelectorFromString("openPanel")
          guard let panelClass = NSClassFromString("NSOpenPanel"),
            let factoryMethod = class_getClassMethod(panelClass, factorySelector)
          else { return false }
          typealias Factory = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>?
          let factory = unsafeBitCast(method_getImplementation(factoryMethod), to: Factory.self)
          guard let panel = factory(panelClass, factorySelector)?.takeUnretainedValue() as? NSObject
          else { return false }
          let beginSelector = NSSelectorFromString("beginWithCompletionHandler:")
          let selectors = [
            "setDirectoryURL:", "setCanChooseDirectories:", "setCanChooseFiles:",
            "setCanCreateDirectories:", "setAllowsMultipleSelection:", "setTitle:", "URLs", "close",
          ]
          guard panel.responds(to: beginSelector),
            selectors.allSatisfy({ panel.responds(to: NSSelectorFromString($0)) })
          else { return false }
          panel.setValue(true, forKey: "canChooseDirectories")
          panel.setValue(false, forKey: "canChooseFiles")
          // NSOpenPanel hides the New Folder button unless this is enabled.
          panel.setValue(true, forKey: "canCreateDirectories")
          panel.setValue(allowsMultipleSelection, forKey: "allowsMultipleSelection")
          if let title { panel.setValue(title, forKey: "title") }
          if let directoryURL { panel.setValue(directoryURL, forKey: "directoryURL") }
          nativePanel = panel
          typealias Completion = @convention(block) (Int) -> Void
          typealias Begin = @convention(c) (AnyObject, Selector, Completion) -> Void
          let begin = unsafeBitCast(panel.method(for: beginSelector), to: Begin.self)
          let completion: Completion = { [weak self, weak panel] response in
            guard let self, let panel, self.nativePanel === panel else { return }
            // NSModalResponseOK == 1. Cancel completes this request without opening another picker.
            let urls: [URL]? =
              response == 1
              ? try? ExceptionCatcher.catch { panel.value(forKey: "URLs") as? [URL] } : nil
            self.finish(urls)
          }
          begin(panel, beginSelector, completion)
          return true
        }) ?? false
      if !opened, let panel = nativePanel {
        nativePanel = nil
        // If opening threw after creating a window, close it before presenting the UIKit fallback.
        _ = try? ExceptionCatcher.catch { panel.perform(NSSelectorFromString("close")) }
      }
      return opened
    }
  #endif
}

extension UIViewController {
  /// Returns false if presentation cannot begin; no delegate callback is sent in that case.
  @discardableResult
  public func present(
    _ controller: UnifiedDocumentPickerController, animated: Bool,
    completion: (() -> Void)? = nil
  ) -> Bool {
    controller.present(from: self, animated: animated, completion: completion)
  }
}
