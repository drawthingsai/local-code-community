import Components
import Localization
import SQLiteDflat
import SnapKit
import Style
import UIKit

/// A miniature of the chat on the reading style page: the project bar, a short exchange and the
/// chat input, which are the chat's own views at 70% of their size. The messages take the message
/// font, so the text font and the message zoom show here as they change; the chat width is set on
/// the controller.
final class OnboardingChatPreviewController {
  var view: UIView { borderView }

  var chatWidth = ChatWidth.normal {
    didSet {
      guard chatWidth != oldValue else { return }
      normalWidthConstraint?.isActive = chatWidth == .normal
      let animated = borderView.window != nil && !UIAccessibility.isReduceMotionEnabled
      UIView.animate(
        withDuration: animated ? 0.4 : 0, delay: 0, usingSpringWithDamping: 0.85,
        initialSpringVelocity: 0
      ) {
        self.borderView.layoutIfNeeded()
      } completion: { _ in
        // The rows were measured before they took their new width; measure them at it.
        self.collectionView.collectionViewLayout.invalidateLayout()
      }
    }
  }

  private static let scale: CGFloat = 0.7

  private let projectBarController: ProjectBarController
  private let chatInputController: ChatInputController
  private lazy var borderView: BorderView = {
    let view = BorderView.defaultBorderView(cornerRadius: 16)
    view.backgroundColor = .tertiaryBackground
    view.clipsToBounds = true
    return view
  }()
  // Laid out at the chat's own size, then shown smaller. Nothing in it is meant to be used.
  private lazy var canvasView: UIView = {
    let view = UIView(frame: .zero)
    view.transform = CGAffineTransform(scaleX: Self.scale, y: Self.scale)
    view.isUserInteractionEnabled = false
    view.accessibilityElementsHidden = true
    return view
  }()
  // The chat column: the input spans it, and the transcript rests 32pt inside.
  private lazy var columnView = UIView(frame: .zero)
  // The chat's transcript layout with the chat's own cells, so a message is measured and drawn
  // here as it is there.
  private lazy var collectionView: UICollectionView = {
    let itemSize = NSCollectionLayoutSize(
      widthDimension: .fractionalWidth(1), heightDimension: .estimated(120))
    let group = NSCollectionLayoutGroup.vertical(
      layoutSize: itemSize, subitems: [NSCollectionLayoutItem(layoutSize: itemSize)])
    let section = NSCollectionLayoutSection(group: group)
    section.interGroupSpacing = 16
    let collectionView = UICollectionView(
      frame: .zero, collectionViewLayout: UICollectionViewCompositionalLayout(section: section))
    collectionView.backgroundColor = .clear
    collectionView.isScrollEnabled = false
    collectionView.contentInsetAdjustmentBehavior = .never
    collectionView.selfSizingInvalidation = .enabledIncludingConstraints
    collectionView.register(
      ProjectHistoryUserViewCell.self,
      forCellWithReuseIdentifier: ProjectHistoryUserViewCell.reusableIdentifier)
    collectionView.register(
      ProjectHistoryAssistantViewCell.self,
      forCellWithReuseIdentifier: ProjectHistoryAssistantViewCell.reusableIdentifier)
    return collectionView
  }()
  // A short exchange: the first item is the prompt, the second the reply.
  private lazy var dataSource = UICollectionViewDiffableDataSource<Int, Int>(
    collectionView: collectionView
  ) { collectionView, indexPath, item in
    guard item > 0 else {
      let cell =
        collectionView.dequeueReusableCell(
          withReuseIdentifier: ProjectHistoryUserViewCell.reusableIdentifier, for: indexPath)
        as! ProjectHistoryUserViewCell
      cell.text = LocalizedString.forKey("rename_these_photos_by_date")
      cell.datetime = Date()
      return cell
    }
    let cell =
      collectionView.dequeueReusableCell(
        withReuseIdentifier: ProjectHistoryAssistantViewCell.reusableIdentifier, for: indexPath)
      as! ProjectHistoryAssistantViewCell
    // The line of code wraps in a normal column and fits a wide one.
    cell.text =
      "## \(LocalizedString.forKey("done"))\n\n"
      + LocalizedString.forKey("photos_renamed_by_date_detail")
      + "\n\n```python\nfor photo in photos: rename_by_date(photo)\n```"
    cell.setDatetime(Date(), duration: 3)
    return cell
  }
  private var normalWidthConstraint: Constraint?

  init(workspace: SQLiteWorkspace, userInterfaceIdiom: UIUserInterfaceIdiom) {
    projectBarController = ProjectBarController(userInterfaceIdiom: userInterfaceIdiom)
    // A new workspace opens on its root project.
    projectBarController.projectName = "./"
    chatInputController = ChatInputController(
      workspace: workspace, userInterfaceIdiom: userInterfaceIdiom)
    chatInputController.isEmptyState = false
    // The column here is narrower than a real one, with no room for a model's name.
    chatInputController.isModelSelectorHidden = true
    borderView.addSubview(canvasView)
    canvasView.addSubview(columnView)
    columnView.addSubview(collectionView)
    // The transcript runs on under the input, as it does in the chat.
    canvasView.addSubview(chatInputController.view)
    canvasView.addSubview(projectBarController.view)
    borderView.snp.makeConstraints { make in
      // Below the page column's width, so the page hidden in onboarding's stack closes without
      // pulling every page down to the narrowest width the chat input allows.
      make.height.equalTo(borderView.snp.width).priority(.medium)
    }
    canvasView.snp.makeConstraints { make in
      make.center.equalToSuperview()
      make.width.equalToSuperview().dividedBy(Self.scale)
      make.height.equalToSuperview().dividedBy(Self.scale)
    }
    projectBarController.view.snp.makeConstraints { make in
      make.leading.top.equalToSuperview().inset(20)
    }
    columnView.snp.makeConstraints { make in
      make.top.bottom.centerX.equalToSuperview()
      // A wide column fills the panel but for its margins; a normal one is 960 to its 1280.
      make.width.equalToSuperview().offset(-64).priority(.low)
      normalWidthConstraint =
        make.width.equalToSuperview().multipliedBy(0.75).offset(-48).constraint
    }
    collectionView.snp.makeConstraints { make in
      make.top.equalTo(projectBarController.view.snp.bottom).offset(16)
      make.leading.trailing.equalToSuperview().inset(32)
      make.bottom.equalToSuperview()
    }
    chatInputController.view.snp.makeConstraints { make in
      make.leading.trailing.equalTo(columnView)
      make.bottom.equalToSuperview().offset(-24)
    }
    var snapshot = NSDiffableDataSourceSnapshot<Int, Int>()
    snapshot.appendSections([0])
    snapshot.appendItems([0, 1])
    dataSource.apply(snapshot, animatingDifferences: false)
  }
}
