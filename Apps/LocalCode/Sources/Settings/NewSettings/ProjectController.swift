import Combine
import Components
import FBShimmer
import Localization
import SnapKit
import Style
import UIKit

protocol ProjectControllerDelegate: AnyObject {
  func projectController(
    _ controller: ProjectController, didSelectThread thread: ProjectController.Thread)
  func projectController(
    _ controller: ProjectController, didSelectRenameProject projectPath: String)
  func projectController(
    _ controller: ProjectController, didSelectDeleteProject projectPath: String)
  func projectController(
    _ controller: ProjectController, didSelectRenameThread thread: ProjectController.Thread)
  func projectController(
    _ controller: ProjectController, didSelectDeleteThread thread: ProjectController.Thread)
  func projectController(
    _ controller: ProjectController, hasBrowserFor thread: ProjectController.Thread
  ) -> Bool
  func projectController(
    _ controller: ProjectController, didSelectCloseBrowserFor thread: ProjectController.Thread)
  func projectController(
    _ controller: ProjectController,
    didSelectExportModelContextFor thread: ProjectController.Thread)
  func projectController(
    _ controller: ProjectController, hasBrowserDataForProjectAt projectPath: String,
    completion: @escaping (Bool) -> Void)
  func projectController(
    _ controller: ProjectController, didSelectClearBrowserDataForProjectAt projectPath: String)
  func projectController(
    _ controller: ProjectController, didSelectRevealProject projectPath: String)
  func projectController(_ controller: ProjectController, didSelectWorkspaceFolder: String?)
  func projectControllerDidSelectInsideAppDocuments(_ controller: ProjectController)
  func projectControllerDidSelectRevealWorkspace(_ controller: ProjectController)
}

private enum ProjectSection: Hashable {
  case recents
  case project(path: String)
}

struct ProjectItem: Hashable {
  var projectPath: String
  var threadId: Int64
  var title: String?
  var updatedAt: Int64
  var model: String?
  var lastMessage: String?
  var hasUnreadResponse: Bool
  var hasIncompleteResponse: Bool
  var status: ProjectController.Thread.Status
  // Recent items render with a different cell, so they must not share identity with project items.
  var isRecent: Bool
  var newThread: Bool {
    return threadId == -1
  }
  /// A thread on one of the account's Macs, which only that Mac renames or deletes.
  var isOnMac: Bool {
    MacProject(path: projectPath) != nil
  }

  init(thread: ProjectController.Thread, isRecent: Bool) {
    projectPath = thread.projectPath
    threadId = thread.threadId
    title = thread.title
    updatedAt = thread.updatedAt
    model = thread.model
    lastMessage = thread.lastMessage
    hasUnreadResponse = thread.hasUnreadResponse
    hasIncompleteResponse = thread.hasIncompleteResponse
    status = thread.status
    self.isRecent = isRecent
  }

  var thread: ProjectController.Thread {
    return ProjectController.Thread(
      projectPath: projectPath, threadId: threadId, title: title,
      updatedAt: updatedAt, model: model, lastMessage: lastMessage,
      hasUnreadResponse: hasUnreadResponse, hasIncompleteResponse: hasIncompleteResponse,
      status: status)
  }
}

final class ProjectController {
  struct Thread: Hashable {
    enum Status: Hashable {
      case idle
      case inProgress
      case incomplete
      case new
    }

    let projectPath: String
    let threadId: Int64
    let title: String?
    let updatedAt: Int64
    let model: String?
    let lastMessage: String?
    let hasUnreadResponse: Bool
    let hasIncompleteResponse: Bool
    let status: Status

    init(
      projectPath: String, threadId: Int64, title: String? = nil, updatedAt: Int64 = 0,
      model: String? = nil, lastMessage: String? = nil, hasUnreadResponse: Bool = false,
      hasIncompleteResponse: Bool = false, status: Status = .idle
    ) {
      self.projectPath = projectPath
      self.threadId = threadId
      self.title = title
      self.updatedAt = updatedAt
      self.model = model
      self.lastMessage = lastMessage
      self.hasUnreadResponse = hasUnreadResponse
      self.hasIncompleteResponse = hasIncompleteResponse
      self.status = status
    }

    var newThread: Bool {
      return threadId == -1
    }
  }

  weak var delegate: ProjectControllerDelegate?

  let view = UIView(frame: .zero)
  private let userInterfaceIdiom: UIUserInterfaceIdiom
  private var isViewLoaded = false
  private var verticalScrollIndicatorController: VerticalScrollIndicatorController? = nil
  private var displayingSections: [ProjectSection] = []
  private(set) var threads = [Thread]()
  /// On a phone: each Mac project's section, after this device's own projects.
  struct MacSection: Equatable {
    let project: MacProject
    let title: String
    /// With `project.path` as their project path.
    let threads: [Thread]
  }
  var macSections = [MacSection]() {
    didSet {
      guard macSections != oldValue else { return }
      applyThreadsSnapshot(animated: true)
    }
  }
  /// `threads`, sent whole on every change, for the devices that watch this Mac's drawer.
  let listedThreads = CurrentValueSubject<[Thread], Never>([])
  var projects: [(path: String, title: String)] {
    orderedProjectPaths().map {
      (
        path: $0,
        title: Self.displayTitle(forProjectPath: $0, rootProjectPath: threads.first?.projectPath)
      )
    }
  }
  var isBotModeEnabled = false {
    didSet {
      guard isBotModeEnabled != oldValue, isViewLoaded else { return }
      emptyRecentsDetailLabel.text = emptyRecentsDetail
      var snapshot = collectionViewDiffableDataSource.snapshot()
      snapshot.reloadSections(snapshot.sectionIdentifiers)
      collectionViewDiffableDataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
        self?.applySelectedThread()
      }
    }
  }
  var isRecentThreadsSelected = false {
    didSet {
      guard isRecentThreadsSelected != oldValue, isViewLoaded else { return }
      collectionViewTopConstraint?.update(offset: isRecentThreadsSelected ? 0 : 12)
      collectionView.contentInset.top = isRecentThreadsSelected ? 12 : 0
      collectionView.contentOffset.y = -collectionView.contentInset.top
      applyThreadsSnapshot(animated: false)
    }
  }
  private var collectionViewTopConstraint: Constraint?
  var selectedThread: Thread? {
    didSet {
      guard selectedThread != oldValue else { return }
      applySelectedThread()
    }
  }
  var workspaceFolder: String? {
    didSet {
      guard workspaceFolder != oldValue else { return }
      makeWorkspaceFolderUIMenu()
    }
  }

  init(userInterfaceIdiom: UIUserInterfaceIdiom) {
    self.userInterfaceIdiom = userInterfaceIdiom
  }

  final class ObjCResponder: NSObject, UICollectionViewDelegate {
    weak var controller: ProjectController?

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
      controller?.collectionView(collectionView, didSelectItemAt: indexPath)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
      controller?.verticalScrollIndicatorController?.scrollViewDidScroll(scrollView)
    }
  }

  private lazy var objCResponder: ObjCResponder = {
    let objCResponder = ObjCResponder()
    objCResponder.controller = self
    return objCResponder
  }()

  private lazy var collectionView: UICollectionView = {
    let collectionView = UICollectionView(
      frame: .zero, collectionViewLayout: collectionViewLayout())
    collectionView.backgroundColor = .secondaryBackground
    collectionView.showsHorizontalScrollIndicator = false
    #if targetEnvironment(macCatalyst)
      collectionView.showsVerticalScrollIndicator = false
    #endif
    collectionView.contentInsetAdjustmentBehavior = .never
    collectionView.contentInset = UIEdgeInsets(
      top: isRecentThreadsSelected ? 12 : 0, left: 0, bottom: 8, right: 0)
    if #available(iOS 26.0, *) {
      collectionView.topEdgeEffect.isHidden = true
    }
    collectionView.delegate = objCResponder
    return collectionView
  }()
  private lazy var collectionViewDiffableDataSource =
    UICollectionViewDiffableDataSource<ProjectSection, ProjectItem>(
      collectionView: collectionView
    ) { [weak self] collectionView, indexPath, item in
      if item.isRecent {
        let cell =
          collectionView.dequeueReusableCell(
            withReuseIdentifier: RecentThreadCollectionViewCell.reusableIdentifier,
            for: indexPath) as! RecentThreadCollectionViewCell
        cell.delegate = self
        let isRootProject = Self.isRootProject(
          item.projectPath, rootProjectPath: self?.threads.first?.projectPath)
        let folder = URL(fileURLWithPath: item.projectPath, isDirectory: true)
          .lastPathComponent
        // The subtitle shows up to two lines, so line breaks in the message would leave them
        // half empty.
        let subtitle = (item.lastMessage ?? "").split(whereSeparator: \.isNewline).joined(
          separator: " ")
        cell.viewModel = RecentThreadCollectionViewCell.ViewModel(
          abbreviation: isRootProject ? "./" : Self.abbreviation(forFolder: folder),
          title: item.title ?? "", subtitle: subtitle,
          datetime: Self.formatRecentDatetime(
            Date(timeIntervalSince1970: TimeInterval(item.updatedAt) / 1_000)),
          folder: isRootProject ? "./" : folder, status: item.status)
        return cell
      }
      let cell =
        collectionView.dequeueReusableCell(
          withReuseIdentifier: ProjectThreadCollectionViewCell.reusableIdentifier,
          for: indexPath) as! ProjectThreadCollectionViewCell
      cell.delegate = self
      cell.item = item
      return cell
    }
  // Shown in place of the list while Recents has no threads.
  private lazy var emptyRecentsView: UIStackView = {
    let stack = UIStackView()
    stack.axis = .vertical
    stack.alignment = .center
    stack.spacing = 6
    stack.isUserInteractionEnabled = false
    stack.isHidden = true
    return stack
  }()
  private lazy var emptyRecentsImageView: UIImageView = {
    let imageView = UIImageView(
      image: UIImage(named: "clock-32")?.withRenderingMode(.alwaysTemplate))
    imageView.tintColor = .quaternaryText
    imageView.isAccessibilityElement = false
    return imageView
  }()
  private lazy var emptyRecentsTitleLabel: UILabel = {
    let label = UILabel(frame: .zero)
    label.text = LocalizedString.forKey("no_recent_threads")
    label.textColor = .secondaryText
    label.textAlignment = .center
    label.numberOfLines = 0
    FontMetrics.default.scaleFont(.systemFont(ofSize: 15, weight: .semibold), bindTo: label)
    return label
  }()
  private lazy var emptyRecentsDetailLabel: UILabel = {
    let label = UILabel(frame: .zero)
    label.text = emptyRecentsDetail
    label.textColor = .quaternaryText
    label.textAlignment = .center
    label.numberOfLines = 0
    FontMetrics.default.scaleFont(.systemFont(ofSize: 13), bindTo: label)
    return label
  }()
  private var emptyRecentsDetail: String {
    LocalizedString.forKey(
      isBotModeEnabled ? "no_recent_threads_bot_detail" : "no_recent_threads_detail")
  }
  private lazy var workspaceView: UIView = {
    let view = UIView(frame: .zero)
    view.backgroundColor = .secondaryBackground

    let topDivider = SettingsViewFactory.makeDividerView()
    topDivider.backgroundColor = .primaryBorder
    view.addSubview(topDivider)
    topDivider.snp.makeConstraints { make in
      make.top.leading.trailing.equalToSuperview()
      make.height.equalTo(1)
    }

    let titleIconView = UIImageView(
      image: #imageLiteral(resourceName: "keyboard-20").withRenderingMode(.alwaysTemplate))
    titleIconView.tintColor = .secondaryText
    titleIconView.contentMode = .scaleAspectFit
    view.addSubview(titleIconView)
    titleIconView.snp.makeConstraints { make in
      make.top.equalTo(topDivider.snp.bottom).offset(18)
      make.leading.equalToSuperview().offset(20)
      make.size.equalTo(20)
    }

    let titleLabel = UILabel(frame: .zero)
    titleLabel.text = LocalizedString.forKey("workspace")
    titleLabel.textColor = .secondaryText
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.numberOfLines = 1
    FontMetrics.default.scaleFont(.systemFont(ofSize: 13, weight: .semibold), bindTo: titleLabel)
    view.addSubview(titleLabel)
    titleLabel.snp.makeConstraints { make in
      make.leading.equalTo(titleIconView.snp.trailing).offset(4)
      make.trailing.lessThanOrEqualToSuperview().offset(-20)
      make.centerY.equalTo(titleIconView)
    }

    view.addSubview(workspaceButton)
    workspaceButton.snp.makeConstraints { make in
      make.top.equalTo(titleIconView.snp.bottom).offset(14)
      make.leading.trailing.equalToSuperview().inset(20)
      make.height.equalTo(Theme.current.buttonHeight)
      make.bottom.equalToSuperview()
    }

    return view
  }()
  private lazy var workspaceButton: UIButton = {
    let button = SettingsViewFactory.makeDropdownButton(titleLineBreakMode: .byTruncatingHead)
    button.setTitle(LocalizedString.forKey("inside_app_documents"), for: .normal)
    return button
  }()

  func loadViewIfNeeded() {
    guard !isViewLoaded else { return }
    isViewLoaded = true
    view.backgroundColor = .secondaryBackground
    collectionView.register(
      ProjectThreadCollectionViewCell.self,
      forCellWithReuseIdentifier: ProjectThreadCollectionViewCell.reusableIdentifier)
    collectionView.register(
      RecentThreadCollectionViewCell.self,
      forCellWithReuseIdentifier: RecentThreadCollectionViewCell.reusableIdentifier)
    collectionView.register(
      ProjectSectionHeaderView.self,
      forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
      withReuseIdentifier: ProjectSectionHeaderView.reusableIdentifier)
    collectionViewDiffableDataSource.supplementaryViewProvider = {
      [weak self]
      collectionView,
      kind, indexPath in
      guard let self,
        kind == UICollectionView.elementKindSectionHeader,
        indexPath.section < self.displayingSections.count,
        case .project(let projectPath) = self.displayingSections[indexPath.section]
      else {
        return UICollectionReusableView(frame: .zero)
      }
      let header =
        collectionView.dequeueReusableSupplementaryView(
          ofKind: kind,
          withReuseIdentifier: ProjectSectionHeaderView.reusableIdentifier,
          for: indexPath) as! ProjectSectionHeaderView
      header.delegate = self
      if let macSection = self.macSections.first(where: { $0.project.path == projectPath }) {
        header.configureForMac(title: macSection.title)
        return header
      }
      header.configure(
        projectPath: projectPath,
        title: Self.displayTitle(
          forProjectPath: projectPath, rootProjectPath: self.threads.first?.projectPath),
        canModify: indexPath.section != 0,
        revealTitle: Self.revealTitle, isBotModeEnabled: self.isBotModeEnabled)
      return header
    }

    view.addSubview(collectionView)
    view.addSubview(emptyRecentsView)
    view.addSubview(workspaceView)
    emptyRecentsView.addArrangedSubview(emptyRecentsImageView)
    emptyRecentsView.addArrangedSubview(emptyRecentsTitleLabel)
    emptyRecentsView.addArrangedSubview(emptyRecentsDetailLabel)
    emptyRecentsView.setCustomSpacing(10, after: emptyRecentsImageView)
    emptyRecentsView.snp.makeConstraints { make in
      make.centerX.equalToSuperview()
      make.centerY.equalTo(collectionView)
      make.width.lessThanOrEqualTo(216)
      make.leading.greaterThanOrEqualToSuperview().offset(24)
      make.trailing.lessThanOrEqualToSuperview().offset(-24)
    }
    collectionView.snp.makeConstraints { make in
      make.leading.equalToSuperview().offset(12)
      // Recents has no pinned headers, so it scrolls up to the top edge and keeps its 12pt top
      // spacing in the content inset instead.
      collectionViewTopConstraint =
        make.top.equalToSuperview().offset(isRecentThreadsSelected ? 0 : 12).constraint
      make.trailing.equalToSuperview()
      make.bottom.equalTo(workspaceView.snp.top)
    }
    workspaceView.snp.makeConstraints { make in
      make.leading.trailing.equalToSuperview()
      if userInterfaceIdiom == .phone {
        if UIScreen.main.isAllScreen {
          make.bottom.equalTo(view.snp.bottomMargin).offset(-4)
        } else {
          make.bottom.equalTo(view.snp.bottomMargin).offset(-8)
        }
      } else {
        make.bottom.equalToSuperview().offset(-20)
      }
    }
    #if targetEnvironment(macCatalyst)
      let verticalScrollIndicatorController = VerticalScrollIndicatorController(
        scrollView: collectionView)
      self.verticalScrollIndicatorController = verticalScrollIndicatorController
      view.addSubview(verticalScrollIndicatorController.view)
      verticalScrollIndicatorController.view.snp.makeConstraints { make in
        make.top.bottom.trailing.equalTo(collectionView)
        make.width.equalTo(12)
      }
    #endif
    workspaceButton.showsMenuAsPrimaryAction = true
    makeWorkspaceFolderUIMenu()

    applyThreadsSnapshot(animated: false)
  }

  func setThreads(_ threads: [Thread], animated: Bool) {
    guard threads != self.threads else { return }
    self.threads = threads
    listedThreads.send(threads)
    applyThreadsSnapshot(animated: animated)
  }

  private func applyThreadsSnapshot(animated: Bool) {
    guard isViewLoaded else { return }
    let isMoreRecent: (Thread, Thread) -> Bool = {
      if $0.updatedAt != $1.updatedAt {
        return $0.updatedAt > $1.updatedAt
      }
      return $0.threadId > $1.threadId
    }
    var snapshot = NSDiffableDataSourceSnapshot<ProjectSection, ProjectItem>()
    if isRecentThreadsSelected {
      displayingSections = [.recents]
      snapshot.appendSections([.recents])
      // The welcome thread is a built-in workspace item, not a recent conversation.
      snapshot.appendItems(
        threads.filter { !$0.newThread && $0.threadId != OnboardingState.threadIdentifier }
          .sorted(by: isMoreRecent).map {
            ProjectItem(thread: $0, isRecent: true)
          }, toSection: .recents)
      emptyRecentsView.isHidden = snapshot.numberOfItems > 0
    } else {
      emptyRecentsView.isHidden = true
      let projectPaths = orderedProjectPaths()
      displayingSections = projectPaths.map { .project(path: $0) }
      snapshot.appendSections(displayingSections)
      for projectPath in projectPaths {
        let threadItems = threads.filter {
          $0.projectPath == projectPath && !$0.newThread
        }.sorted {
          if ($0.threadId == OnboardingState.threadIdentifier)
            != ($1.threadId == OnboardingState.threadIdentifier)
          {
            return $0.threadId == OnboardingState.threadIdentifier
          }
          return isMoreRecent($0, $1)
        }.map {
          ProjectItem(thread: $0, isRecent: false)
        }
        snapshot.appendItems(
          threadItems + [
            ProjectItem(thread: Thread(projectPath: projectPath, threadId: -1), isRecent: false)
          ],
          toSection: .project(path: projectPath))
      }
      for macSection in macSections {
        let section = ProjectSection.project(path: macSection.project.path)
        displayingSections.append(section)
        snapshot.appendSections([section])
        snapshot.appendItems(
          macSection.threads.sorted(by: isMoreRecent).map {
            ProjectItem(thread: $0, isRecent: false)
          }
            + [
              ProjectItem(
                thread: Thread(projectPath: macSection.project.path, threadId: -1),
                isRecent: false)
            ], toSection: section)
      }
    }
    collectionViewDiffableDataSource.apply(snapshot, animatingDifferences: animated) {
      [weak self] in
      self?.applySelectedThread()
    }
  }

  private func applySelectedThread() {
    guard isViewLoaded else { return }
    let snapshot = collectionViewDiffableDataSource.snapshot()
    let selectedItem: ProjectItem?
    if let selectedThread {
      selectedItem =
        snapshot.itemIdentifiers.first {
          $0.projectPath == selectedThread.projectPath
            && $0.threadId == selectedThread.threadId
        }
        ?? snapshot.itemIdentifiers.first {
          $0.projectPath == selectedThread.projectPath && $0.newThread
        }
    } else {
      selectedItem = nil
    }
    guard let selectedItem else {
      collectionView.indexPathsForSelectedItems?.forEach {
        collectionView.deselectItem(at: $0, animated: false)
      }
      return
    }
    DispatchQueue.main.async { [weak self] in
      guard let self,
        let indexPath = self.collectionViewDiffableDataSource.indexPath(for: selectedItem)
      else { return }
      self.collectionView.indexPathsForSelectedItems?.forEach {
        if $0 != indexPath {
          self.collectionView.deselectItem(at: $0, animated: false)
        }
      }
      if self.collectionView.indexPathsForSelectedItems?.contains(indexPath) != true {
        let scrollPosition: UICollectionView.ScrollPosition =
          self.collectionView.indexPathsForVisibleItems.contains(indexPath) ? [] : .top
        self.collectionView.selectItem(
          at: indexPath, animated: false, scrollPosition: scrollPosition)
      }
    }
  }

  /// Scrolls the project's "Start a new thread" row to the top, under its header, as selecting a row
  /// out of view does. Like selecting, it waits for the next run loop, when the snapshot just
  /// applied has laid out.
  func scrollToProjectOnNextRunLoop(at projectPath: String) {
    guard isViewLoaded else { return }
    DispatchQueue.main.async { [weak self] in
      guard let self,
        let indexPath = self.collectionViewDiffableDataSource.indexPath(
          for: ProjectItem(
            thread: Thread(projectPath: projectPath, threadId: -1), isRecent: false))
      else { return }
      self.collectionView.scrollToItem(at: indexPath, at: .top, animated: false)
    }
  }

  private func orderedProjectPaths() -> [String] {
    var projectPaths = [String]()
    var seenProjectPaths = Set<String>()
    for thread in threads where seenProjectPaths.insert(thread.projectPath).inserted {
      projectPaths.append(thread.projectPath)
    }
    guard let rootProjectPath = projectPaths.first else { return [] }
    return projectPaths.sorted { lhs, rhs in
      if (lhs == rootProjectPath) != (rhs == rootProjectPath) {
        return lhs == rootProjectPath
      }
      return Self.displayTitle(forProjectPath: lhs, rootProjectPath: rootProjectPath)
        .localizedStandardCompare(
          Self.displayTitle(forProjectPath: rhs, rootProjectPath: rootProjectPath))
        == .orderedAscending
    }
  }

  private func collectionView(
    _ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath
  ) {
    guard let item = collectionViewDiffableDataSource.itemIdentifier(for: indexPath) else { return }
    delegate?.projectController(self, didSelectThread: item.thread)
  }

  static func displayTitle(forProjectPath projectPath: String, rootProjectPath: String?)
    -> String
  {
    if isRootProject(projectPath, rootProjectPath: rootProjectPath) {
      return "./"
    }
    return "./" + URL(fileURLWithPath: projectPath, isDirectory: true).lastPathComponent
  }

  private static func isRootProject(_ projectPath: String, rootProjectPath: String?) -> Bool {
    guard let rootProjectPath else { return false }
    // Restored bookmarks can use a different symlink spelling for the workspace root.
    return URL(fileURLWithPath: projectPath, isDirectory: true)
      .standardizedFileURL.resolvingSymlinksInPath().path
      == URL(fileURLWithPath: rootProjectPath, isDirectory: true)
      .standardizedFileURL.resolvingSymlinksInPath().path
  }

  /// Two-letter initials in the style of avatar-initials libraries: split words on whitespace,
  /// punctuation (`-`, `_`, `.`), and camelCase boundaries, then take the first letter of the
  /// first two words. A single word yields its first two letters.
  private static func abbreviation(forFolder folder: String) -> String {
    let characters = Array(folder)
    var words = [String]()
    var word = ""
    for (index, character) in characters.enumerated() {
      guard character.isLetter || character.isNumber else {
        if !word.isEmpty {
          words.append(word)
          word = ""
        }
        continue
      }
      if let previous = word.last, character.isUppercase {
        let nextIsLowercase = index + 1 < characters.count && characters[index + 1].isLowercase
        // "musicStudio" splits before "S"; "HTTPServer" splits before the "S" of "Server".
        if previous.isLowercase || previous.isNumber || (previous.isUppercase && nextIsLowercase) {
          words.append(word)
          word = ""
        }
      }
      word.append(character)
    }
    if !word.isEmpty {
      words.append(word)
    }
    let abbreviation: String
    if words.count >= 2 {
      abbreviation = String(words[0].prefix(1)) + String(words[1].prefix(1))
    } else {
      abbreviation = String((words.first ?? folder).prefix(2))
    }
    return abbreviation.uppercased()
  }

  /// Matches `formatDatetime`, but drops the time once the thread is not from today.
  private static func formatRecentDatetime(_ datetime: Date) -> String {
    let calendar = Calendar.autoupdatingCurrent
    let now = Date()
    if calendar.isDate(datetime, inSameDayAs: now) {
      return datetime.formatted(date: .omitted, time: .shortened)
    }
    if calendar.isDate(datetime, equalTo: now, toGranularity: .year) {
      return datetime.formatted(.dateTime.month(.abbreviated).day())
    }
    return datetime.formatted(.dateTime.year().month(.abbreviated).day())
  }

  private func makeWorkspaceFolderUIMenu() {
    guard isViewLoaded else { return }
    var actions: [UIAction] = [
      UIAction(title: LocalizedString.forKey("select_a_folder_dot"), state: .off) { [weak self] _ in
        guard let self else { return }
        self.delegate?.projectController(self, didSelectWorkspaceFolder: self.workspaceFolder)
      },
      UIAction(
        title: LocalizedString.forKey("inside_app_documents"),
        state: workspaceFolder == nil ? .on : .off
      ) { [weak self] _ in
        guard let self else { return }
        self.delegate?.projectControllerDidSelectInsideAppDocuments(self)
      },
    ]
    actions.append(
      UIAction(title: Self.revealTitle, state: .off) { [weak self] _ in
        guard let self else { return }
        self.delegate?.projectControllerDidSelectRevealWorkspace(self)
      })
    if let workspaceFolder {
      workspaceButton.setTitle(workspaceFolder, for: .normal)
    } else {
      workspaceButton.setTitle(LocalizedString.forKey("inside_app_documents"), for: .normal)
    }
    workspaceButton.menu = UIMenu(children: actions)
  }

  static var revealTitle: String {
    #if targetEnvironment(macCatalyst)
      return LocalizedString.forKey("reveal_in_finder_dot")
    #else
      return LocalizedString.forKey("reveal_in_files_dot")
    #endif
  }

  private func collectionViewLayout() -> UICollectionViewLayout {
    UICollectionViewCompositionalLayout { [weak self] sectionIndex, _ in
      let isRecents =
        self.map {
          sectionIndex < $0.displayingSections.count
            && $0.displayingSections[sectionIndex] == .recents
        } ?? false
      // Recent cells size to their text (76pt with a one-line subtitle, 92pt with two lines).
      let height: NSCollectionLayoutDimension = isRecents ? .estimated(76) : .absolute(40)
      let itemSize = NSCollectionLayoutSize(
        widthDimension: .fractionalWidth(1), heightDimension: height)
      let item = NSCollectionLayoutItem(layoutSize: itemSize)
      let groupSize = NSCollectionLayoutSize(
        widthDimension: .fractionalWidth(1), heightDimension: height)
      let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item])
      let section = NSCollectionLayoutSection(group: group)
      section.interGroupSpacing = 4
      // The last section only needs 4pt; the content inset adds the rest above the workspace view.
      let isLastSection = self.map { sectionIndex == $0.displayingSections.count - 1 } ?? true
      section.contentInsets = NSDirectionalEdgeInsets(
        top: 0, leading: 0, bottom: isLastSection ? 4 : 16, trailing: 12)
      guard !isRecents else { return section }
      let headerSize = NSCollectionLayoutSize(
        widthDimension: .fractionalWidth(1), heightDimension: .absolute(36))
      let header = NSCollectionLayoutBoundarySupplementaryItem(
        layoutSize: headerSize,
        elementKind: UICollectionView.elementKindSectionHeader,
        alignment: .top)
      header.pinToVisibleBounds = true
      section.boundarySupplementaryItems = [header]
      return section
    }
  }
}

extension ProjectController: LightweightViewControllable {}

extension ProjectController: ProjectSectionHeaderViewDelegate {
  func projectSectionHeaderViewDidSelectRename(_ headerView: ProjectSectionHeaderView) {
    guard let projectPath = headerView.projectPath else { return }
    delegate?.projectController(self, didSelectRenameProject: projectPath)
  }

  func projectSectionHeaderViewDidSelectDelete(_ headerView: ProjectSectionHeaderView) {
    guard let projectPath = headerView.projectPath else { return }
    delegate?.projectController(self, didSelectDeleteProject: projectPath)
  }

  func projectSectionHeaderViewDidSelectReveal(_ headerView: ProjectSectionHeaderView) {
    guard let projectPath = headerView.projectPath else { return }
    delegate?.projectController(self, didSelectRevealProject: projectPath)
  }

  func projectSectionHeaderView(
    _ headerView: ProjectSectionHeaderView, hasBrowserData completion: @escaping (Bool) -> Void
  ) {
    guard let projectPath = headerView.projectPath, let delegate else {
      completion(false)
      return
    }
    delegate.projectController(
      self, hasBrowserDataForProjectAt: projectPath, completion: completion)
  }

  func projectSectionHeaderViewDidSelectClearBrowserData(_ headerView: ProjectSectionHeaderView) {
    guard let projectPath = headerView.projectPath else { return }
    delegate?.projectController(self, didSelectClearBrowserDataForProjectAt: projectPath)
  }
}

extension ProjectController: ProjectThreadCollectionViewCellDelegate {
  func projectThreadCollectionViewCellDidSelectRename(
    _ cell: ProjectThreadCollectionViewCell
  ) {
    guard let item = cell.item, !item.newThread else { return }
    delegate?.projectController(self, didSelectRenameThread: item.thread)
  }

  func projectThreadCollectionViewCellDidSelectDelete(
    _ cell: ProjectThreadCollectionViewCell
  ) {
    guard let item = cell.item, !item.newThread else { return }
    delegate?.projectController(self, didSelectDeleteThread: item.thread)
  }

  func projectThreadCollectionViewCellHasBrowser(_ cell: ProjectThreadCollectionViewCell) -> Bool {
    guard let item = cell.item, !item.newThread else { return false }
    return delegate?.projectController(self, hasBrowserFor: item.thread) ?? false
  }

  func projectThreadCollectionViewCellDidSelectCloseBrowser(
    _ cell: ProjectThreadCollectionViewCell
  ) {
    guard let item = cell.item, !item.newThread else { return }
    delegate?.projectController(self, didSelectCloseBrowserFor: item.thread)
  }

  func projectThreadCollectionViewCellDidSelectExportModelContext(
    _ cell: ProjectThreadCollectionViewCell
  ) {
    guard let item = cell.item, !item.newThread else { return }
    delegate?.projectController(self, didSelectExportModelContextFor: item.thread)
  }
}

extension ProjectController: RecentThreadCollectionViewCellDelegate {
  func recentThreadCollectionViewCellDidSelectRename(
    _ cell: RecentThreadCollectionViewCell
  ) {
    guard let indexPath = collectionView.indexPath(for: cell),
      let item = collectionViewDiffableDataSource.itemIdentifier(for: indexPath)
    else { return }
    delegate?.projectController(self, didSelectRenameThread: item.thread)
  }

  func recentThreadCollectionViewCellDidSelectDelete(
    _ cell: RecentThreadCollectionViewCell
  ) {
    guard let indexPath = collectionView.indexPath(for: cell),
      let item = collectionViewDiffableDataSource.itemIdentifier(for: indexPath)
    else { return }
    delegate?.projectController(self, didSelectDeleteThread: item.thread)
  }

  func recentThreadCollectionViewCellDidSelectReveal(
    _ cell: RecentThreadCollectionViewCell
  ) {
    guard let indexPath = collectionView.indexPath(for: cell),
      let item = collectionViewDiffableDataSource.itemIdentifier(for: indexPath)
    else { return }
    delegate?.projectController(self, didSelectRevealProject: item.projectPath)
  }

  func recentThreadCollectionViewCellHasBrowser(_ cell: RecentThreadCollectionViewCell) -> Bool {
    guard let indexPath = collectionView.indexPath(for: cell),
      let item = collectionViewDiffableDataSource.itemIdentifier(for: indexPath)
    else { return false }
    return delegate?.projectController(self, hasBrowserFor: item.thread) ?? false
  }

  func recentThreadCollectionViewCellDidSelectCloseBrowser(
    _ cell: RecentThreadCollectionViewCell
  ) {
    guard let indexPath = collectionView.indexPath(for: cell),
      let item = collectionViewDiffableDataSource.itemIdentifier(for: indexPath)
    else { return }
    delegate?.projectController(self, didSelectCloseBrowserFor: item.thread)
  }

  func recentThreadCollectionViewCellDidSelectExportModelContext(
    _ cell: RecentThreadCollectionViewCell
  ) {
    guard let indexPath = collectionView.indexPath(for: cell),
      let item = collectionViewDiffableDataSource.itemIdentifier(for: indexPath)
    else { return }
    delegate?.projectController(self, didSelectExportModelContextFor: item.thread)
  }
}
