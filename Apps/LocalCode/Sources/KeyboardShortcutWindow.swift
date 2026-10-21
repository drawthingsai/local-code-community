import UIKit

protocol EscapeKeyDismissible: AnyObject {
  func dismissWithEscape()
}

final class KeyboardShortcutWindow: UIWindow {
  /// Posted for every touch, press, scroll, or pointer event the window receives.
  static let didReceiveUserEventNotification = Notification.Name(
    "KeyboardShortcutWindow.didReceiveUserEvent")

  var shortcutActionHandler: ((KeyboardShortcutAction) -> Void)?

  override func sendEvent(_ event: UIEvent) {
    if event.type != .motion && event.type != .remoteControl {
      NotificationCenter.default.post(name: Self.didReceiveUserEventNotification, object: self)
    }
    if let pressesEvent = event as? UIPressesEvent {
      if pressesEvent.allPresses.contains(where: {
        $0.phase == .began && $0.key?.charactersIgnoringModifiers == UIKeyCommand.inputEscape
      }) {
        var presentedViewController = rootViewController?.presentedViewController
        while let nextViewController = presentedViewController?.presentedViewController {
          presentedViewController = nextViewController
        }
        if let dismissible = presentedViewController as? EscapeKeyDismissible {
          dismissible.dismissWithEscape()
          return
        }
      }
      if rootViewController?.presentedViewController == nil {
        var matchedAction: KeyboardShortcutAction?
        for press in pressesEvent.allPresses {
          guard press.phase == .began, let key = press.key else { continue }
          let pressedShortcut = KeyboardShortcut(
            input: key.charactersIgnoringModifiers, modifierFlags: key.modifierFlags)
          matchedAction = KeyboardShortcutAction.allCases.first(where: {
            $0.shortcut == pressedShortcut
          })
          if matchedAction != nil { break }
        }
        if let matchedAction {
          shortcutActionHandler?(matchedAction)
          return
        }
      }
    }
    super.sendEvent(event)
  }
}
