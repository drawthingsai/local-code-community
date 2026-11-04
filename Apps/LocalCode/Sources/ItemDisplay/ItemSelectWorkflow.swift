import Dflat
import Localization
import UIKit

public protocol ItemSelectWorkflowDelegate: AnyObject {
  func didSelectItem(
    item: ItemViewModel.ItemIdentifier, section: ItemDisplaySectionIdentity,
    workflow: ItemSelectWorkflow)
  func didTapTrash(item: ItemViewModel.ItemIdentifier, workflow: ItemSelectWorkflow)
  func contextMenu(item: ItemViewModel.ItemIdentifier, workflow: ItemSelectWorkflow) -> UIMenu?
  func didSelectShowAll(showAll: Bool, workflow: ItemSelectWorkflow)
  func didSelectShowDetails(showDetails: Bool, workflow: ItemSelectWorkflow)
  func didDismiss(workflow: ItemSelectWorkflow)
}

public final class ItemSelectWorkflow: Workflow {
  public var viewControllable: UIViewController { viewController }
  private let viewController: ItemDisplayViewController
  private let cellHeight: CGFloat
  private let minimumLineSpacing: CGFloat
  final class ObjCResponder: NSObject {
    weak var workflow: ItemSelectWorkflow? = nil
  }
  private let objCResponder: ObjCResponder

  public weak var delegate: ItemSelectWorkflowDelegate? = nil
  private var viewModels: [ItemDisplaySectionModel] = []

  /// Whether rows show their detail and caption under the title.
  public var showsDetails = false {
    didSet {
      guard showsDetails != oldValue else { return }
      viewController.setShowsDetails(
        showsDetails, animated: viewController.viewIfLoaded?.window != nil)
      updatePreferredContentHeight()
    }
  }

  public init(
    userInterfaceIdiom: UIUserInterfaceIdiom, cellHeight: CGFloat, minimumLineSpacing: CGFloat,
    workspace: Workspace, isSwitchDisplayed: Bool, isDetailSwitchDisplayed: Bool,
    usesGlass: Bool = false
  ) {
    self.cellHeight = cellHeight
    self.minimumLineSpacing = minimumLineSpacing
    viewController = ItemDisplayViewController(
      userInterfaceIdiom: userInterfaceIdiom, cellHeight: cellHeight,
      minimumLineSpacing: minimumLineSpacing, workspace: workspace,
      segmentedControls: isSwitchDisplayed
        ? [LocalizedString.forKey("compat"), LocalizedString.forKey("all")] : [],
      isDetailSwitchDisplayed: isDetailSwitchDisplayed, usesGlass: usesGlass)
    viewController.modalPresentationStyle = .popover
    viewController.preferredContentSize = ItemSelectWorkflow.preferredContentSize
    objCResponder = ObjCResponder()
    objCResponder.workflow = self
    if let popoverPresentationController = viewController.popoverPresentationController {
      popoverPresentationController.permittedArrowDirections = [.up, .down]
      popoverPresentationController.delegate = objCResponder
    }
    viewController.delegate = self
  }

  public func updateTitle(title: String) {
    viewController.titleLabel.text = title
  }

  public func setViewModels(
    _ items: [ItemDisplaySectionModel], flag: ItemViewModel.ItemFlag? = nil
  ) {
    viewModels = items.map {
      var section = $0
      section.items = ItemDisplayCollectionViewCellViewModel.updateViewModels(
        from: section.items, isListView: true)
      return section
    }
    updatePreferredContentHeight()
    let selectedSegmentIndex: Int
    if let flag = flag, flag.contains(.compatible) {
      selectedSegmentIndex = 0
    } else {
      selectedSegmentIndex = 1
    }
    viewController.apply(
      viewModels, selectedSegmentIndex: selectedSegmentIndex, flag: flag, isListView: true,
      willScrollToSelectedItem: true)
  }

  private func updatePreferredContentHeight() {
    let items = viewModels.flatMap(\.items)
    // Rows span the popover less the list's 8pt insets. Before the popover lays out, take its
    // preferred width, or on iOS its 320pt default; once it lays out, the height follows its width.
    let viewWidth = viewController.viewIfLoaded?.bounds.width ?? 0
    let preferredWidth = ItemSelectWorkflow.preferredContentSize.width
    let rowWidth = (viewWidth > 0 ? viewWidth : preferredWidth > 0 ? preferredWidth : 320) - 16
    let rowsHeight = items.reduce(0) { height, item in
      guard case .itemAcronymViewModel(let viewModel) = item else { return height + cellHeight }
      let rowHeight =
        (showsDetails
          ? ItemDisplayCollectionViewAcronymListCell.detailedHeight(for: viewModel, width: rowWidth)
          : nil) ?? cellHeight
      return height + rowHeight
        + (viewModel.startsGroup ? ItemDisplayCollectionViewAcronymListCell.groupSpacing : 0)
    }
    // The list shows a header above each titled section that has rows.
    let sectionHeadersHeight =
      CGFloat(viewModels.filter { $0.identifier != .noSection && !$0.items.isEmpty }.count)
      * ItemDisplayViewController.sectionHeaderHeight
    // Title, search field and gaps, section headers and rows, then the inset below the last row.
    let height =
      viewController.headerHeight + viewController.searchFieldTopSpacing
      + viewController.searchFieldHeight + viewController.listTopSpacing
      + sectionHeadersHeight + rowsHeight + CGFloat(max(0, items.count - 1)) * minimumLineSpacing
      + viewController.bottomInset
    #if os(macOS) || (os(iOS) && targetEnvironment(macCatalyst))
      viewController.preferredContentSize.height = min(
        ItemSelectWorkflow.preferredContentSize.height, height)
    #else
      viewController.preferredContentSize.height = items.count <= 5 ? height : 0
    #endif
  }

  private func didDismissView() {
    delegate?.didDismiss(workflow: self)
  }
}

extension ItemSelectWorkflow.ObjCResponder:
  UIPopoverPresentationControllerDelegate
{
  func adaptivePresentationStyle(
    for controller: UIPresentationController, traitCollection: UITraitCollection
  ) -> UIModalPresentationStyle {
    return .none
  }
}

extension ItemSelectWorkflow.ObjCResponder:
  UIAdaptivePresentationControllerDelegate
{
  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    workflow?.didDismissView()
  }
}

extension ItemSelectWorkflow {
  func selectItem(at name: ItemViewModel.ItemIdentifier) {
    viewController.selectItem(at: name)
  }
  func unselectAll() {
    viewController.unselectAll()
  }

}

extension ItemSelectWorkflow: ItemDisplayViewControllerDelegate {
  func didCloseItemDisplay() {
    viewController.dismiss(animated: true) { [weak self] in
      self?.didDismissView()
    }
  }

  func didSelectItem(item: ItemViewModel.ItemIdentifier, section: ItemDisplaySectionIdentity) {
    delegate?.didSelectItem(item: item, section: section, workflow: self)
  }

  func didTapTrash(item: ItemViewModel.ItemIdentifier) {
    delegate?.didTapTrash(item: item, workflow: self)
  }

  func contextMenu(for item: ItemViewModel.ItemIdentifier) -> UIMenu? {
    delegate?.contextMenu(item: item, workflow: self)
  }

  func didTapSegmentedControl(at index: Int) {
    viewModels = viewModels.map {
      var section = $0
      section.items = ItemDisplayCollectionViewCellViewModel.updateViewModels(
        from: section.items, isListView: true)
      return section
    }
    if index == 0 {
      viewController.apply(
        viewModels, selectedSegmentIndex: index, flag: .compatible, isListView: true,
        willScrollToSelectedItem: true)
    } else {
      viewController.apply(
        viewModels, selectedSegmentIndex: index, flag: nil, isListView: true,
        willScrollToSelectedItem: true)
    }
    delegate?.didSelectShowAll(showAll: index == 1, workflow: self)
  }

  func didChangeViewControllerWidth() {
    updatePreferredContentHeight()
  }

  func didTapDetailSwitch() {
    showsDetails.toggle()
    delegate?.didSelectShowDetails(showDetails: showsDetails, workflow: self)
  }

  func didTapSectionHeader(section: ItemDisplaySectionIdentity, selectedSegmentIndex: Int) {
    for i in 0..<viewModels.count {
      if viewModels[i].identifier == section {
        switch section {
        case .noSection:
          break
        case .section(_, _, _, let isCollapsible, let isCollapsed):
          if isCollapsible {
            viewModels[i].identifier = section.withCollapsedState(!isCollapsed)
          }
        }
        viewController.apply(
          viewModels, selectedSegmentIndex: selectedSegmentIndex, flag: viewController.flag,
          isListView: true, willScrollToSelectedItem: false)
        break
      }
    }
  }
}

extension ItemSelectWorkflow {
  static let preferredContentSize: CGSize = {
    #if os(macOS) || (os(iOS) && targetEnvironment(macCatalyst))
      return CGSize(width: 375, height: 800)
    #else
      return CGSizeZero
    #endif
  }()
}
