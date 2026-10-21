import ProjectHistoryManager
import UIKit

enum ChatHistoryMessage {
  case assistant(String, datetime: Date, duration: TimeInterval)
  case user(String, datetime: Date)
}

/// The conversation surface `ChatWorkflow` drives, implemented once per device layout.
protocol ChatViewControllable: UIViewController {
  var delegate: ChatViewControllableDelegate? { get set }
  var isBotModeEnabled: Bool { get set }
  var localPathResolver: LocalPathResolver? { get }
  func setLocalPathResolver(_ resolver: LocalPathResolver?, refreshVisibleCells: Bool)
  func setOnboardingViewController(
    _ controller: OnboardingViewController?, animated: Bool, completionHandler: (() -> Void)?)
  func insertChatBannerView(_ bannerView: UIView)
  func removeChatBannerView(_ bannerView: UIView)
  func setActionableMessage(_ message: ProjectHistoryItem.ActionableMessage?)
  func appendUser(_ text: String, datetime: Date)
  func setHistory(
    _ messages: [ChatHistoryMessage], hasIncompleteResponse: Bool, incompleteResponseText: String)
  func setQueuedItems(_ items: [ProjectQueuedItem], animated: Bool)
  func setSteeringQueuedItems(_ items: [ProjectQueuedItem])
  func appendAssistant(
    _ text: String, thinking: String, output: String, datetime: Date?, duration: TimeInterval,
    isTransient: Bool, mode: ProjectHistoryItem.Mode)
  func setLastMessage(
    _ text: String, thinking: String, output: String, datetime: Date?, duration: TimeInterval,
    isTransient: Bool, mode: ProjectHistoryItem.Mode)
  func removeLastTransientMessage()
}

// Protocol requirements cannot declare default arguments; these overloads keep call sites short.
extension ChatViewControllable {
  func setLocalPathResolver(_ resolver: LocalPathResolver?) {
    setLocalPathResolver(resolver, refreshVisibleCells: true)
  }

  func setHistory(_ messages: [ChatHistoryMessage]) {
    setHistory(messages, hasIncompleteResponse: false, incompleteResponseText: "")
  }

  func appendAssistant(_ text: String, isTransient: Bool, mode: ProjectHistoryItem.Mode) {
    appendAssistant(
      text, thinking: "", output: "", datetime: nil, duration: 0, isTransient: isTransient,
      mode: mode)
  }

  func setLastMessage(_ text: String, isTransient: Bool, mode: ProjectHistoryItem.Mode) {
    setLastMessage(
      text, thinking: "", output: "", datetime: nil, duration: 0, isTransient: isTransient,
      mode: mode)
  }

  func setLastMessage(
    _ text: String, duration: TimeInterval, isTransient: Bool, mode: ProjectHistoryItem.Mode
  ) {
    setLastMessage(
      text, thinking: "", output: "", datetime: nil, duration: duration,
      isTransient: isTransient, mode: mode)
  }
}
