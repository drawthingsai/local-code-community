import Components
import Dflat
import Localization
import Style
import UIKit

protocol ItemDisplayViewControllerDelegate: AnyObject {
  func didCloseItemDisplay()
  func didTapTrash(item: ItemViewModel.ItemIdentifier)
  func didTapSegmentedControl(at index: Int)
  func didSelectItem(item: ItemViewModel.ItemIdentifier, section: ItemDisplaySectionIdentity)
  func didTapSectionHeader(section: ItemDisplaySectionIdentity, selectedSegmentIndex: Int)
  func didTapDetailSwitch()
  func contextMenu(for item: ItemViewModel.ItemIdentifier) -> UIMenu?
}

final class ItemDisplayViewController: UIViewController, EscapeKeyDismissible {
  weak var delegate: ItemDisplayViewControllerDelegate? = nil
  override var keyCommands: [UIKeyCommand]? {
    let command = UIKeyCommand(
      input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(dismissWithEscape))
    command.wantsPriorityOverSystemBehavior = true
    return [command]
  }
  private let workspace: Workspace
  private let cellHeight: CGFloat
  private let minimumLineSpacing: CGFloat
  private let segmentedControls: [String]
  private let isDetailSwitchDisplayed: Bool
  private let userInterfaceIdiom: UIUserInterfaceIdiom
  /// Shows the popover on Liquid Glass where available, with its roomier header and search field.
  private let usesGlass: Bool
  // Measured from the designs. The header ends with its divider.
  let headerHeight: CGFloat
  let searchFieldTopSpacing: CGFloat
  let searchFieldHeight: CGFloat
  let listTopSpacing: CGFloat
  let bottomInset: CGFloat
  private var items: [ItemDisplaySectionModel] = []
  private var displayingItems: [ItemDisplaySectionModel] = []
  private var isListView: Bool = true
  private var showsDetails = false

  public private(set) var flag: ItemViewModel.ItemFlag? = nil

  init(
    userInterfaceIdiom: UIUserInterfaceIdiom, cellHeight: CGFloat, minimumLineSpacing: CGFloat,
    workspace: Workspace, segmentedControls: [String], isDetailSwitchDisplayed: Bool,
    usesGlass: Bool
  ) {
    self.userInterfaceIdiom = userInterfaceIdiom
    self.cellHeight = cellHeight
    self.minimumLineSpacing = minimumLineSpacing
    self.workspace = workspace
    self.segmentedControls = segmentedControls
    self.isDetailSwitchDisplayed = isDetailSwitchDisplayed
    self.usesGlass = usesGlass
    if usesGlass {
      headerHeight = 52.5
      searchFieldTopSpacing = 12
      searchFieldHeight = 36
      listTopSpacing = 16
      bottomInset = 16
    } else {
      headerHeight = 39
      searchFieldTopSpacing = 7
      searchFieldHeight = 32
      listTopSpacing = 9
      bottomInset = 8
    }
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) {
    fatalError()
  }

  private lazy var searchFieldBackground: UIView = {
    if usesGlass, #available(iOS 26.0, *) {
      let view = UIView()
      let glassView = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
      glassView.cornerConfiguration = .capsule()
      view.addSubview(glassView)
      glassView.snp.makeConstraints { make in
        make.edges.equalToSuperview()
      }
      return view
    }
    let view = BorderView.defaultBorderView(cornerRadius: searchFieldHeight / 2)
    view.backgroundColor = .tertiaryBackground
    return view
  }()
  private lazy var searchIconView: UIImageView = {
    let imageView = UIImageView(
      image: #imageLiteral(resourceName: "search-16").withRenderingMode(.alwaysTemplate))
    imageView.tintColor = usesGlass ? .secondaryText : .senaryText
    return imageView
  }()
  private lazy var searchField: UITextField = {
    let textField = UITextField()
    textField.placeholder = LocalizedString.forKey("search")
    textField.textColor = .primaryText
    textField.clearButtonMode = .whileEditing
    textField.returnKeyType = .search
    textField.autocapitalizationType = .none
    textField.autocorrectionType = .no
    textField.delegate = self
    if usesGlass {
      textField.attributedPlaceholder = NSAttributedString(
        string: LocalizedString.forKey("search"),
        attributes: [.foregroundColor: UIColor.secondaryText])
    }
    FontMetrics.default.scaleFont(
      usesGlass ? .systemFont(ofSize: 13, weight: .medium) : .systemFont(ofSize: 14),
      bindTo: textField
    ) {
      $0.font = $1
    }
    textField.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        self.filterContentForSearchText(self.searchField.text ?? "")
      }, for: .editingChanged)
    return textField
  }()
  // Shows the icon for whether the rows show their details, not the action a tap takes.
  private lazy var detailSwitch: UIButton = {
    let button = UIButton(type: .custom)
    var configuration: UIButton.Configuration
    if #available(iOS 26.0, *) {
      configuration = .glass()
    } else {
      configuration = .filled()
    }
    configuration.cornerStyle = .capsule
    configuration.baseForegroundColor = .senaryText
    configuration.image = #imageLiteral(resourceName: "paragraph-none-16").withRenderingMode(
      .alwaysTemplate)
    configuration.contentInsets = .zero
    if #unavailable(iOS 26.0) {
      configuration.background.backgroundColor = .tertiaryFill
    }
    button.configuration = configuration
    button.accessibilityLabel = LocalizedString.forKey("show_details")
    button.toolTip = LocalizedString.forKey("show_details")
    button.addAction(
      UIAction { [weak self] _ in
        self?.delegate?.didTapDetailSwitch()
      }, for: .touchUpInside)
    return button
  }()

  public private(set) lazy var titleLabel: UILabel = {
    let label = UILabel()
    FontMetrics.default.scaleFont(
      .systemFont(ofSize: usesGlass ? 16 : 15, weight: usesGlass ? .semibold : .medium),
      bindTo: label)
    label.textColor = .secondaryText
    return label
  }()

  lazy var collectionView: UICollectionView = {
    let collectionViewLayout = UICollectionViewFlowLayout()
    collectionViewLayout.minimumLineSpacing = minimumLineSpacing
    collectionViewLayout.minimumInteritemSpacing = 4
    let screenWidth = UIScreen.main.bounds.width
    collectionViewLayout.itemSize = CGSize(width: 70, height: 70)
    collectionViewLayout.sectionInset = .zero
    collectionViewLayout.sectionHeadersPinToVisibleBounds = true
    let collectionView = UICollectionView(frame: .zero, collectionViewLayout: collectionViewLayout)
    collectionView.backgroundColor = .clear
    collectionView.allowsMultipleSelection = false
    collectionView.register(
      ItemDisplayCollectionViewCell.self,
      forCellWithReuseIdentifier: ItemDisplayCollectionViewCell.reusableIdentifier)
    collectionView.register(
      ItemDisplayCollectionViewListCell.self,
      forCellWithReuseIdentifier: ItemDisplayCollectionViewListCell.reusableIdentifier)
    collectionView.register(
      ItemDisplayCollectionViewAcronymCell.self,
      forCellWithReuseIdentifier: ItemDisplayCollectionViewAcronymCell.reusableIdentifier)
    collectionView.register(
      ItemDisplayCollectionViewAcronymListCell.self,
      forCellWithReuseIdentifier: ItemDisplayCollectionViewAcronymListCell.reusableIdentifier)
    collectionView.register(
      SectionHeaderView.self,
      forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
      withReuseIdentifier: SectionHeaderView.reusableIdentifier)

    collectionView.delegate = self
    return collectionView
  }()

  private lazy var collectionViewDiffableDataSource:
    UICollectionViewDiffableDataSource<
      ItemDisplaySectionIdentity, ItemDisplayCollectionViewCellViewModel
    > = { [weak self] in
      guard let self = self else {
        // Fallback data source if self is nil
        return UICollectionViewDiffableDataSource<
          ItemDisplaySectionIdentity, ItemDisplayCollectionViewCellViewModel
        >(
          collectionView: UICollectionView(
            frame: .zero, collectionViewLayout: UICollectionViewFlowLayout())
        ) { _, _, _ in UICollectionViewCell() }
      }

      let collectionViewDiffableDataSource = UICollectionViewDiffableDataSource<
        ItemDisplaySectionIdentity, ItemDisplayCollectionViewCellViewModel
      >(collectionView: self.collectionView) { collectionView, indexPath, viewModel in

        switch viewModel {
        case .itemAcronymViewModel(let itemAcronymViewModel):
          if itemAcronymViewModel.isList {
            let cell =
              collectionView.dequeueReusableCell(
                withReuseIdentifier: ItemDisplayCollectionViewAcronymListCell.reusableIdentifier,
                for: indexPath) as! ItemDisplayCollectionViewAcronymListCell
            cell.usesGlass = self.usesGlass
            cell.setViewModel(with: itemAcronymViewModel, showsDetails: self.showsDetails)
            cell.delegate = self
            return cell
          } else {
            let cell =
              collectionView.dequeueReusableCell(
                withReuseIdentifier: ItemDisplayCollectionViewAcronymCell.reusableIdentifier,
                for: indexPath) as! ItemDisplayCollectionViewAcronymCell
            cell.setViewModel(with: itemAcronymViewModel)
            return cell
          }

        case .itemViewModel(let itemViewModel):
          if itemViewModel.isList {
            let cell =
              collectionView.dequeueReusableCell(
                withReuseIdentifier: ItemDisplayCollectionViewListCell.reusableIdentifier,
                for: indexPath) as! ItemDisplayCollectionViewListCell
            cell.setViewModel(with: itemViewModel)
            return cell
          } else {
            let cell =
              collectionView.dequeueReusableCell(
                withReuseIdentifier: ItemDisplayCollectionViewCell.reusableIdentifier,
                for: indexPath) as! ItemDisplayCollectionViewCell
            cell.setViewModel(with: itemViewModel)
            return cell
          }
        }
      }
      collectionViewDiffableDataSource.supplementaryViewProvider = {
        [weak self] collectionView, kind, indexPath in
        guard let self = self,
          let sectionIdentifier = collectionViewDiffableDataSource.sectionIdentifier(
            for: indexPath.section)
        else {
          return collectionView.dequeueReusableSupplementaryView(
            ofKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: SectionHeaderView.reusableIdentifier, for: indexPath)
        }
        switch sectionIdentifier {
        case .noSection:
          return collectionView.dequeueReusableSupplementaryView(
            ofKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: SectionHeaderView.reusableIdentifier, for: indexPath)
        case .section(let name, let image, _, let isCollapsible, let isCollapsed):
          let sectionHeaderView =
            collectionView.dequeueReusableSupplementaryView(
              ofKind: UICollectionView.elementKindSectionHeader,
              withReuseIdentifier: SectionHeaderView.reusableIdentifier, for: indexPath)
            as! SectionHeaderView
          sectionHeaderView.delegate = self
          sectionHeaderView.sectionIdentifier = sectionIdentifier
          sectionHeaderView.setViewModel(
            SectionHeaderView.ViewModel(
              title: name.description,
              image: image,
              isCollapsed: isCollapsed,
              isCollapsible: isCollapsible))
          return sectionHeaderView
        }
      }
      return collectionViewDiffableDataSource
    }()

  private lazy var xButton: UIButton = {
    let button = UIButton(type: .custom)
    var configuration = UIButton.Configuration.filled()
    configuration.cornerStyle = .capsule
    configuration.background.backgroundColor = .clear
    configuration.baseForegroundColor = .senaryText
    configuration.image =
      (usesGlass
      ? #imageLiteral(resourceName: "close-24") : #imageLiteral(resourceName: "close-16"))
      .withRenderingMode(.alwaysTemplate)
    configuration.contentInsets = .zero
    button.configuration = configuration
    button.configurationUpdateHandler = {
      guard var configuration = $0.configuration else { return }
      configuration.background.backgroundColor =
        $0.isHighlighted || $0.state.contains(.focused) ? .quinaryBackground : .clear
      $0.configuration = configuration
    }
    return button
  }()
  private lazy var graySeparator: UIView = {
    let graySeparator = UIView()
    graySeparator.backgroundColor = .selectorGrayColor
    graySeparator.isHidden = true
    return graySeparator
  }()
  private lazy var listSwitch: UISegmentedControl = {
    let listSwitch = UISegmentedControl(items: segmentedControls)
    listSwitch.selectedSegmentIndex = 0
    FontMetrics.default.scaleFont(.systemFont(ofSize: 13), bindTo: listSwitch) {
      $0.setTitleTextAttributes([.font: $1], for: .normal)
    }
    return listSwitch
  }()

  func resetSearchState() {
    searchField.text = nil
    guard displayingItems != items else { return }
    filterContentForSearchText("")
  }

  func apply(
    _ items: [ItemDisplaySectionModel], selectedSegmentIndex: Int, flag: ItemViewModel.ItemFlag?,
    isListView: Bool, willScrollToSelectedItem: Bool
  ) {
    self.items = items
    self.flag = flag
    self.isListView = isListView
    let selectedItemIdentifier = collectionView.indexPathsForSelectedItems?.first.flatMap {
      collectionViewDiffableDataSource.itemIdentifier(for: $0)?.itemIdentifier
    }
    if selectedSegmentIndex != listSwitch.selectedSegmentIndex {
      listSwitch.selectedSegmentIndex = selectedSegmentIndex
    }

    if #available(iOS 17.0, macCatalyst 17.0, *) {
      collectionView.performBatchUpdates {
        if viewIfLoaded != nil {
          updateCollectionViewLayout(isListView: isListView, animated: true)
        }
        filterContentForSearchText(searchField.text ?? "")
      }
    } else {
      if viewIfLoaded != nil {
        updateCollectionViewLayout(isListView: isListView, animated: true)
      }
      filterContentForSearchText(searchField.text ?? "", reloadData: true)
    }
    if willScrollToSelectedItem, let selectedItemIdentifier {
      let collectionView = collectionView
      let collectionViewDiffableDataSource = collectionViewDiffableDataSource
      DispatchQueue.main.async {
        guard
          let selectedItem = collectionViewDiffableDataSource.snapshot().itemIdentifiers.first(
            where: { $0.itemIdentifier == selectedItemIdentifier }),
          let indexPath = collectionViewDiffableDataSource.indexPath(for: selectedItem)
        else {
          return
        }
        collectionView.selectItem(at: indexPath, animated: true, scrollPosition: [.top, .left])
      }
    }
  }

  func setShowsDetails(_ showsDetails: Bool, animated: Bool) {
    guard self.showsDetails != showsDetails else { return }
    self.showsDetails = showsDetails
    detailSwitch.configuration?.image =
      (showsDetails
      ? #imageLiteral(resourceName: "paragraph-16")
      : #imageLiteral(resourceName: "paragraph-none-16"))
      .withRenderingMode(.alwaysTemplate)
    detailSwitch.accessibilityTraits = showsDetails ? [.button, .selected] : [.button]
    guard viewIfLoaded != nil else { return }
    // Reconfiguring keeps the selection, and the flow layout asks for the new row heights.
    var snapshot = collectionViewDiffableDataSource.snapshot()
    snapshot.reconfigureItems(snapshot.itemIdentifiers)
    collectionViewDiffableDataSource.apply(snapshot, animatingDifferences: false)
    if animated {
      collectionView.performBatchUpdates {
        collectionView.collectionViewLayout.invalidateLayout()
      }
    } else {
      collectionView.collectionViewLayout.invalidateLayout()
    }
  }

  override func viewSafeAreaInsetsDidChange() {
    collectionView.contentInset = UIEdgeInsets(
      top: 0, left: 0, bottom: view.safeAreaInsets.bottom + bottomInset, right: 0)
    collectionView.scrollIndicatorInsets = UIEdgeInsets(
      top: 0, left: 0, bottom: view.safeAreaInsets.bottom + bottomInset, right: 0)
  }

  func updateCollectionViewLayout(isListView: Bool, animated: Bool) {
    guard
      let collectionViewLayout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout
    else { return }
    if isListView {
      let width: CGFloat = collectionView.bounds.width
      collectionViewLayout.itemSize = CGSize(width: width, height: cellHeight)
      collectionViewLayout.sectionInset = .zero
    } else {
      let width: CGFloat = floor((collectionView.bounds.width - 14 * 2 - 2 * 4) / 3)
      collectionViewLayout.itemSize = CGSize(width: width, height: width + 48)
      collectionViewLayout.sectionInset = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }

    collectionView.setCollectionViewLayout(collectionViewLayout, animated: animated)
  }

  private lazy var topDivider: UIView = {
    let topDivider = UIView(frame: .zero)
    topDivider.backgroundColor = .tertiaryBorder
    topDivider.isUserInteractionEnabled = false
    return topDivider
  }()

  override func viewDidLoad() {
    if usesGlass, #available(iOS 26.0, *) {
      // The popover's own glass shows through.
      view.backgroundColor = .clear
    } else {
      view.backgroundColor = .secondaryBackground
    }
    view.addSubview(xButton)
    // The glass header centers its 24pt close icon 20pt from the edge, and its title 24pt in.
    let dividerHeight: CGFloat = usesGlass ? 0.5 : 1
    xButton.snp.makeConstraints { make in
      make.top.equalTo(view.snp.topMargin).offset(usesGlass ? 12 : 6)
      make.trailing.equalToSuperview().offset(usesGlass ? -18 : -6)
      make.width.height.equalTo(28)
    }
    view.addSubview(titleLabel)
    titleLabel.snp.makeConstraints { make in
      make.centerY.equalTo(xButton)
      make.leading.equalToSuperview().offset(usesGlass ? 24 : 16)
    }
    view.addSubview(topDivider)
    topDivider.snp.makeConstraints { make in
      make.top.equalTo(view.snp.topMargin).offset(headerHeight - dividerHeight)
      make.height.equalTo(dividerHeight)
      make.leading.trailing.equalToSuperview()
    }
    if let text = titleLabel.text, !text.isEmpty {
      xButton.isHidden = false
      topDivider.isHidden = false
    } else {
      xButton.isHidden = true
      topDivider.isHidden = true
    }

    view.addSubview(searchFieldBackground)
    searchFieldBackground.addSubview(searchIconView)
    searchFieldBackground.addSubview(searchField)
    if !segmentedControls.isEmpty {
      view.addSubview(listSwitch)
    }
    if isDetailSwitchDisplayed {
      view.addSubview(detailSwitch)
    }

    searchFieldBackground.snp.makeConstraints { make in
      if let text = titleLabel.text, !text.isEmpty {
        make.top.equalTo(topDivider.snp.bottom).offset(searchFieldTopSpacing)
      } else {
        make.top.equalTo(view.snp.topMargin).offset(8)
      }
      make.leading.equalToSuperview().offset(usesGlass ? 16 : 8)
      make.height.equalTo(searchFieldHeight)
      if !segmentedControls.isEmpty {
        make.trailing.equalTo(listSwitch.snp.leading).offset(-4)
      } else if isDetailSwitchDisplayed {
        make.trailing.equalTo(detailSwitch.snp.leading).offset(-6)
      } else {
        make.trailing.equalToSuperview().offset(usesGlass ? -16 : -8)
      }
    }
    searchIconView.snp.makeConstraints { make in
      make.centerY.equalToSuperview()
      make.leading.equalToSuperview().offset(usesGlass ? 10 : 7)
      make.size.equalTo(16)
    }
    searchField.snp.makeConstraints { make in
      make.top.bottom.equalToSuperview()
      make.leading.equalTo(searchIconView.snp.trailing).offset(6)
      make.trailing.equalToSuperview().offset(-4)
    }
    if !segmentedControls.isEmpty {
      listSwitch.snp.makeConstraints { make in
        make.centerY.equalTo(searchFieldBackground.snp.centerY)
        make.trailing.equalToSuperview().offset(-14)
        make.height.equalTo(32)
      }
    }
    if isDetailSwitchDisplayed {
      detailSwitch.snp.makeConstraints { make in
        make.centerY.equalTo(searchFieldBackground.snp.centerY)
        make.trailing.equalToSuperview().offset(-8)
        make.width.height.equalTo(searchFieldHeight)
      }
    }

    view.addSubview(collectionView)
    collectionView.snp.makeConstraints { make in
      make.top.equalTo(searchFieldBackground.snp.bottom).offset(listTopSpacing)
      // The glass rows' icons sit 16pt in, inside their 4pt selection rings.
      make.leading.trailing.equalToSuperview().inset(usesGlass ? 12 : 8)
      make.bottom.equalToSuperview()
    }

    view.addSubview(graySeparator)

    graySeparator.snp.makeConstraints { make in
      make.top.equalTo(collectionView)
      make.leading.trailing.equalToSuperview()
      make.height.equalTo(0.5)
    }

    collectionView.contentInset = UIEdgeInsets(
      top: 0, left: 0, bottom: view.safeAreaInsets.bottom + bottomInset, right: 0)
    collectionView.scrollIndicatorInsets = UIEdgeInsets(
      top: 0, left: 0, bottom: view.safeAreaInsets.bottom + bottomInset, right: 0)

    xButton.addAction(
      UIAction { [weak self] _ in
        guard let self = self else { return }
        if let selectedIndexPath = collectionView.indexPathsForSelectedItems?.first {
          collectionView.deselectItem(at: selectedIndexPath, animated: true)
        }

        self.delegate?.didCloseItemDisplay()
      }, for: .touchUpInside)

    listSwitch.addAction(
      UIAction { [weak self] _ in
        guard let self = self else { return }
        self.delegate?.didTapSegmentedControl(at: self.listSwitch.selectedSegmentIndex)
      }, for: .valueChanged)

    collectionView.contentInsetAdjustmentBehavior = .never
    collectionView.automaticallyAdjustsScrollIndicatorInsets = false
  }

  @objc func dismissWithEscape() {
    if let selectedIndexPath = collectionView.indexPathsForSelectedItems?.first {
      collectionView.deselectItem(at: selectedIndexPath, animated: true)
    }
    delegate?.didCloseItemDisplay()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    #if targetEnvironment(macCatalyst)
      searchField.becomeFirstResponder()
    #endif
  }

  override func viewDidLayoutSubviews() {
    updateCollectionViewLayout(
      isListView: isListView, animated: false)
  }
}

extension ItemDisplayViewController: UITextFieldDelegate {

  func textFieldShouldClear(_ textField: UITextField) -> Bool {
    // Clearing does not send editingChanged.
    filterContentForSearchText("")
    return true
  }

  func textFieldShouldReturn(_ textField: UITextField) -> Bool {
    textField.resignFirstResponder()
    return true
  }

  func filterContentForSearchText(_ searchText: String, reloadData: Bool = false) {
    var filteredItems = items
    if !searchText.isEmpty {
      filteredItems = filteredItems.compactMap {
        var section = $0
        switch section.identifier {
        case .noSection:
          break
        case let .section(name, image, disambiguator, isCollapsible, _):
          section.identifier = .section(
            name: name, image: image, disambiguator: disambiguator, isCollapsible: isCollapsible,
            isCollapsed: false)
        }
        section.items = section.items.filter {
          guard $0.titleString.lowercased().contains(searchText.lowercased()) else { return false }
          guard let flag = self.flag else { return true }
          return $0.flag.contains(flag)
        }
        guard section.items.count > 0 else { return nil }
        return section
      }
    } else {
      filteredItems = filteredItems.compactMap {
        guard $0.items.count > 0 else { return nil }
        var section = $0
        // Apply collapsed state - if section is collapsed, show empty items unless searching
        switch section.identifier {
        case .noSection:
          break  // No collapse state for noSection
        case .section(_, _, _, _, let isCollapsed):
          if isCollapsed {
            section.items = []
          } else {
            section.items = section.items.filter {
              guard let flag = self.flag else { return true }
              return $0.flag.contains(flag)
            }
          }
        }
        return section
      }
    }
    guard displayingItems != filteredItems else { return }

    displayingItems = filteredItems
    var snapshot = NSDiffableDataSourceSnapshot<
      ItemDisplaySectionIdentity, ItemDisplayCollectionViewCellViewModel
    >()
    for section in displayingItems {
      snapshot.appendSections([section.identifier])
      snapshot.appendItems(section.items, toSection: section.identifier)
    }

    if reloadData {
      collectionViewDiffableDataSource.applySnapshotUsingReloadData(snapshot)
    } else {
      collectionViewDiffableDataSource.apply(snapshot)
    }
  }

}

extension ItemDisplayViewController: UICollectionViewDelegateFlowLayout {
  func collectionView(
    _ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout,
    referenceSizeForHeaderInSection section: Int
  ) -> CGSize {
    guard let sectionIdentifier = collectionViewDiffableDataSource.sectionIdentifier(for: section)
    else { return .zero }
    switch sectionIdentifier {
    case .noSection:
      return .zero
    case .section(_, _, _, _, _):
      return CGSize(width: 0, height: 40)
    }
  }

  func collectionView(
    _ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout,
    sizeForItemAt indexPath: IndexPath
  ) -> CGSize {
    guard let itemSize = (collectionViewLayout as? UICollectionViewFlowLayout)?.itemSize else {
      return .zero
    }
    guard
      case .itemAcronymViewModel(let viewModel)? = collectionViewDiffableDataSource.itemIdentifier(
        for: indexPath),
      viewModel.isList
    else { return itemSize }
    let height =
      (showsDetails
        ? ItemDisplayCollectionViewAcronymListCell.detailedHeight(
          for: viewModel, width: itemSize.width) : nil) ?? itemSize.height
    return CGSize(
      width: itemSize.width,
      height: height
        + (viewModel.startsGroup ? ItemDisplayCollectionViewAcronymListCell.groupSpacing : 0))
  }
}

extension ItemDisplayViewController: UICollectionViewDelegate {
  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    if scrollView.contentOffset.y > 1 {
      graySeparator.isHidden = false
    } else {
      graySeparator.isHidden = true
    }
  }

  func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
    guard indexPath.section < displayingItems.count else { return }
    let section = displayingItems[indexPath.section]
    guard indexPath.item < section.items.count else { return }
    self.delegate?.didSelectItem(
      item: section.items[indexPath.item].itemIdentifier, section: section.identifier)
  }

  func collectionView(
    _ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
    point: CGPoint
  ) -> UIContextMenuConfiguration? {
    guard let indexPath = indexPaths.first, indexPath.section < displayingItems.count else {
      return nil
    }
    let section = displayingItems[indexPath.section]
    guard indexPath.item < section.items.count,
      let menu = delegate?.contextMenu(for: section.items[indexPath.item].itemIdentifier)
    else { return nil }
    return UIContextMenuConfiguration(actionProvider: { _ in menu })
  }

  func collectionView(
    _ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath,
    point: CGPoint
  ) -> UIContextMenuConfiguration? {
    return self.collectionView(
      collectionView, contextMenuConfigurationForItemsAt: [indexPath], point: point)
  }
}

extension ItemDisplayViewController {
  public func selectItem(at name: ItemViewModel.ItemIdentifier) {
    for (section, viewModel) in displayingItems.enumerated() {
      guard
        let firstIndex = viewModel.items.firstIndex(where: {
          $0.itemIdentifier == name
        })
      else {
        continue
      }
      collectionView.selectItem(
        at: IndexPath(item: firstIndex, section: section), animated: false,
        scrollPosition: [.left, .centeredVertically])
      break
    }
  }
  public func unselectAll() {
    collectionView.selectItem(
      at: nil, animated: false, scrollPosition: [.left, .centeredVertically])
  }
}

protocol ItemDisplayViewControllerSectionHeaderViewDelegate: AnyObject {
  func didTapSectionHeader(section: ItemDisplaySectionIdentity)
}

extension ItemDisplayViewController {
  private final class SectionHeaderView: UICollectionReusableView {
    struct ViewModel: Hashable & Equatable {
      var title: String
      var image: String?
      var isCollapsed: Bool
      var isCollapsible: Bool
    }

    weak var delegate: ItemDisplayViewControllerSectionHeaderViewDelegate?
    var sectionIdentifier: ItemDisplaySectionIdentity?

    public override init(frame: CGRect) {
      super.init(frame: frame)
      backgroundColor = .secondaryBackground
      let tapGesture = UITapGestureRecognizer(target: self, action: #selector(headerTapped))
      addGestureRecognizer(tapGesture)
      isUserInteractionEnabled = true

      // Add all views to hierarchy once
      addSubview(titleLabel)
      addSubview(imageView)
      addSubview(expandCollapseImageView)
    }
    required init?(coder: NSCoder) {
      fatalError()
    }

    @objc private func headerTapped() {
      guard let sectionIdentifier = sectionIdentifier else { return }
      delegate?.didTapSectionHeader(section: sectionIdentifier)
    }
    private lazy var titleLabel: UILabel = {
      let titleLabel = UILabel(frame: .zero)
      titleLabel.textColor = .secondaryText
      titleLabel.lineBreakMode = .byTruncatingTail
      titleLabel.numberOfLines = 1
      FontMetrics.default.scaleFont(.systemFont(ofSize: 14, weight: .semibold), bindTo: titleLabel)
      return titleLabel
    }()
    private lazy var imageView: UIImageView = {
      let imageView = UIImageView(frame: .zero)
      imageView.isUserInteractionEnabled = false
      imageView.tintColor = .secondaryText
      imageView.contentMode = .center
      return imageView
    }()

    private lazy var expandCollapseImageView: UIImageView = {
      let imageView = UIImageView(frame: .zero)
      imageView.isUserInteractionEnabled = false
      imageView.tintColor = .secondaryText
      imageView.contentMode = .center
      return imageView
    }()

    private var viewModel: ViewModel? = nil
    public static let reusableIdentifier = "SectionHeaderView"
    public func setViewModel(_ viewModel: ViewModel) {
      guard self.viewModel != viewModel else { return }
      self.viewModel = viewModel
      titleLabel.text = viewModel.title
      if titleLabel.superview == nil {
        addSubview(titleLabel)
      }

      // Configure section icon
      if let image = viewModel.image {
        imageView.image = UIImage(imageLiteralResourceName: image).withRenderingMode(
          .alwaysTemplate)
        imageView.isHidden = false
      } else {
        imageView.image = nil
        imageView.isHidden = true
      }

      // Configure expand/collapse chevron
      if viewModel.isCollapsible {
        let chevronImage = viewModel.isCollapsed ? "chevron-down-16" : "chevron-up-16"
        expandCollapseImageView.image = UIImage(imageLiteralResourceName: chevronImage)
          .withRenderingMode(.alwaysTemplate)
        expandCollapseImageView.isHidden = false
      } else {
        expandCollapseImageView.image = nil
        expandCollapseImageView.isHidden = true
      }

      // Configure section icon constraints
      imageView.snp.remakeConstraints { make in
        make.centerY.equalToSuperview()
        make.width.height.equalTo(16)
        make.leading.equalToSuperview().offset(4)
      }

      // Configure title label constraints
      titleLabel.snp.remakeConstraints { make in
        if imageView.isHidden {
          make.centerY.equalToSuperview()
          make.leading.equalToSuperview().offset(4)
        } else {
          make.centerY.equalToSuperview().offset(-1)  // To adjust the obvious off-center visually.
          make.leading.equalTo(imageView.snp.trailing).offset(4)
        }
      }

      // Configure chevron constraints
      expandCollapseImageView.snp.remakeConstraints { make in
        make.centerY.equalToSuperview()
        make.width.height.equalTo(16)
        make.leading.equalTo(titleLabel.snp.trailing).offset(4)
      }
    }
  }
}

extension ItemDisplayViewController: ItemDisplayCollectionViewAcronymListCellDelegate {
  func didTapTrash(itemIdentifier: ItemViewModel.ItemIdentifier) {
    delegate?.didTapTrash(item: itemIdentifier)
  }
}

extension ItemDisplayViewController: ItemDisplayViewControllerSectionHeaderViewDelegate {
  func didTapSectionHeader(section: ItemDisplaySectionIdentity) {
    delegate?.didTapSectionHeader(
      section: section, selectedSegmentIndex: listSwitch.selectedSegmentIndex)
  }
}
