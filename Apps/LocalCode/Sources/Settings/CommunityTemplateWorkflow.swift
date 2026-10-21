import UIKit

protocol CommunityTemplateWorkflowDelegate: AnyObject {
  func communityTemplateWorkflow(
    _ workflow: CommunityTemplateWorkflow, didSelectTemplateNamed name: String)
  func didDismiss(workflow: CommunityTemplateWorkflow)
}

/// Lists the community templates to start a new project from.
final class CommunityTemplateWorkflow: Workflow {
  var viewControllable: UIViewController { viewController }

  private let viewController: CommunityTemplateViewController

  final class ObjCResponder: NSObject {
    weak var workflow: CommunityTemplateWorkflow?
  }

  private let objCResponder = ObjCResponder()
  weak var delegate: CommunityTemplateWorkflowDelegate?

  init() {
    viewController = CommunityTemplateViewController()
    viewController.modalPresentationStyle = .formSheet
    viewController.delegate = self
    objCResponder.workflow = self
    TemplateZoo.fetchTemplateNames { [weak self] result in
      DispatchQueue.main.async {
        guard let self else { return }
        switch result {
        case .success(let names):
          self.viewController.state = .loaded(names)
        case .failure:
          self.viewController.state = .failed
        }
      }
    }
  }

  func didPresentCommunityTemplateView() {
    viewController.presentationController?.delegate = objCResponder
  }

  private func didDismissView() {
    delegate?.didDismiss(workflow: self)
  }
}

extension CommunityTemplateWorkflow.ObjCResponder: UIAdaptivePresentationControllerDelegate {
  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    workflow?.didDismissView()
  }
}

extension CommunityTemplateWorkflow: CommunityTemplateViewControllerDelegate {
  func didTapClose() {
    viewController.dismiss(animated: true) { [weak self] in
      self?.didDismissView()
    }
  }

  func didSelectTemplate(named name: String) {
    // The project name prompt can only be presented once the list is gone.
    viewController.dismiss(animated: true) { [weak self] in
      guard let self else { return }
      self.delegate?.communityTemplateWorkflow(self, didSelectTemplateNamed: name)
      self.didDismissView()
    }
  }
}
