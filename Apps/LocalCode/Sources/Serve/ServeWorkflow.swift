import Combine
import ModelZoo
import UIKit

/// What's being served, in place of the chat, for as long as the rail is on Serve.
final class ServeWorkflow: Workflow {
  let viewController = ServeViewController()
  var viewControllable: UIViewController { viewController }
  /// Nil while serving is off, which is then what the page shows.
  var serveController: ServeController? {
    didSet {
      guard serveController !== oldValue else { return }
      observeState()
    }
  }
  private var stateSubscription: AnyCancellable?

  init(serveController: ServeController?, contextCachePath: String?) {
    self.serveController = serveController
    viewController.delegate = self
    viewController.contextCachePath = contextCachePath
    observeState()
  }

  private func observeState() {
    guard let serveController else {
      stateSubscription = nil
      viewController.state = ServeState()
      return
    }
    stateSubscription = serveController.state.receive(on: DispatchQueue.main).sink {
      [weak self] state in
      self?.viewController.state = state
    }
  }
}

extension ServeWorkflow: ServeViewControllerDelegate {
  func serveViewController(_ viewController: ServeViewController, didCopy text: String) {
    UIPasteboard.general.string = text
  }

  func serveViewController(
    _ viewController: ServeViewController, displayNameForModel model: String
  ) -> String {
    LLMZoo.humanReadableNameForModel(model)
  }
}
