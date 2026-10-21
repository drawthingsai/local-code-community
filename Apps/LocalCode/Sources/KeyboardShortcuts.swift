import Localization
import UIKit

enum KeyboardShortcutAction: CaseIterable {
  case newProject
  case newChat
  case machineSettings
  case projectsTab
  case settingsTab
  case kitTab
  case activitiesTab
  case focusChat
  case stopConversation

  func title(isBotModeEnabled: Bool) -> String {
    switch self {
    case .newProject:
      return LocalizedString.forKey(isBotModeEnabled ? "new_bot" : "new_project")
    case .newChat:
      return LocalizedString.forKey("new_chat")
    case .machineSettings:
      return LocalizedString.forKey("machine_settings")
    case .projectsTab:
      return LocalizedString.forKey(isBotModeEnabled ? "bots" : "projects")
    case .settingsTab:
      return LocalizedString.forKey("settings")
    case .kitTab:
      return LocalizedString.forKey("kit")
    case .activitiesTab:
      return LocalizedString.forKey("activities")
    case .focusChat:
      return LocalizedString.forKey("focus_chat")
    case .stopConversation:
      return LocalizedString.forKey("stop_conversation")
    }
  }

  var shortcut: KeyboardShortcut {
    switch self {
    case .newProject:
      return KeyboardShortcut(input: "p", modifierFlags: .command)
    case .newChat:
      return KeyboardShortcut(input: "n", modifierFlags: .command)
    case .machineSettings:
      return KeyboardShortcut(input: ",", modifierFlags: .command)
    case .projectsTab:
      return KeyboardShortcut(input: "1", modifierFlags: .command)
    case .settingsTab:
      return KeyboardShortcut(input: "2", modifierFlags: .command)
    case .kitTab:
      return KeyboardShortcut(input: "3", modifierFlags: .command)
    case .activitiesTab:
      return KeyboardShortcut(input: "4", modifierFlags: .command)
    case .focusChat:
      return KeyboardShortcut(input: "l", modifierFlags: .command)
    case .stopConversation:
      return KeyboardShortcut(input: ".", modifierFlags: .command)
    }
  }
}

struct KeyboardShortcut: Equatable {
  let input: String
  let modifierFlags: UIKeyModifierFlags

  init(input: String, modifierFlags: UIKeyModifierFlags) {
    self.input = Self.normalizedInput(input)
    self.modifierFlags = modifierFlags.intersection(Self.supportedModifierFlags)
  }

  static let supportedModifierFlags: UIKeyModifierFlags = [
    .command, .control, .alternate, .shift,
  ]

  private static func normalizedInput(_ input: String) -> String {
    return input.count == 1 ? input.lowercased() : input
  }
}
