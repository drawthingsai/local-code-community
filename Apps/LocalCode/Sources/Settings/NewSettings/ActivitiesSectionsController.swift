import Components
import Localization
import SQLiteDflat
import SnapKit
import Style
import UIKit

private enum ActivitiesSection: CaseIterable, Hashable {
  case browserTabs
  case processes
}

protocol ActivitiesSectionsControllerDelegate: AnyObject {
  func activitiesSectionsController(
    _ controller: ActivitiesSectionsController, didOpenBrowserTab id: String)
  func activitiesSectionsControllerDidOpenNewBrowserTab(_ controller: ActivitiesSectionsController)
  func activitiesSectionsController(
    _ controller: ActivitiesSectionsController, didCloseBrowserTab id: String)
  func activitiesSectionsController(
    _ controller: ActivitiesSectionsController, didSelectStopProcess id: Int)
}

/// The Activities page of the rail: what agents keep running, browser tabs and shell commands.
final class ActivitiesSectionsController {
  let view = UIView(frame: .zero)
  weak var delegate: ActivitiesSectionsControllerDelegate?
  private let workspace: SQLiteWorkspace
  private var isViewLoaded = false
  private var verticalScrollIndicatorController: VerticalScrollIndicatorController? = nil
  private let sections: [ActivitiesSection] = [.browserTabs, .processes]
  private var displayingSections: [ActivitiesSection: any SettingsViewObservable] = [:]
  private var sectionViewModifiers: [ActivitiesSection: any SettingsViewModifying] = [:]
  /// The open chat's tabs.
  private var currentBrowserTabs = [SettingsBrowserTabsItem.Tab]()
  /// Every other chat's tabs.
  private var otherBrowserTabs = [SettingsBrowserTabsItem.Tab]()
  /// The open chat's running commands.
  private var currentProcesses = [SettingsProcessesItem.Process]()
  /// Every other chat's running commands.
  private var otherProcesses = [SettingsProcessesItem.Process]()

  private lazy var scrollView: UIScrollView = {
    let scrollView = UIScrollView(frame: .zero)
    scrollView.alwaysBounceVertical = true
    scrollView.contentInsetAdjustmentBehavior = .never
    #if targetEnvironment(macCatalyst)
      scrollView.showsVerticalScrollIndicator = false
    #endif
    scrollView.showsHorizontalScrollIndicator = false
    scrollView.automaticallyAdjustsScrollIndicatorInsets = false
    scrollView.contentInset = UIEdgeInsets(
      top: Theme.current.individualStackViewItemSpacing, left: 0,
      bottom: Theme.current.individualStackViewItemSpacing, right: 0)
    return scrollView
  }()
  private lazy var stackView: UIStackView = {
    let stackView = UIStackView(frame: .zero)
    stackView.axis = .vertical
    stackView.alignment = .fill
    stackView.spacing = Theme.current.individualStackViewItemSpacing
    return stackView
  }()

  init(workspace: SQLiteWorkspace) {
    self.workspace = workspace
  }

  func setBrowserTabs(
    current: [SettingsBrowserTabsItem.Tab], others: [SettingsBrowserTabsItem.Tab]
  ) {
    guard current != currentBrowserTabs || others != otherBrowserTabs else { return }
    currentBrowserTabs = current
    otherBrowserTabs = others
    updateSections()
  }

  func setProcesses(
    current: [SettingsProcessesItem.Process], others: [SettingsProcessesItem.Process]
  ) {
    guard current != currentProcesses || others != otherProcesses else { return }
    currentProcesses = current
    otherProcesses = others
    updateSections()
  }

  func loadViewIfNeeded() {
    guard !isViewLoaded else { return }
    isViewLoaded = true
    view.backgroundColor = .secondaryBackground

    view.addSubview(scrollView)
    scrollView.addSubview(stackView)
    scrollView.snp.makeConstraints { make in
      make.edges.equalToSuperview()
    }
    stackView.snp.makeConstraints { make in
      make.leading.trailing.equalTo(scrollView.contentLayoutGuide).inset(
        Theme.current.individualStackViewItemSpacing)
      make.top.bottom.equalTo(scrollView.contentLayoutGuide)
      make.width.equalTo(scrollView.frameLayoutGuide).offset(
        -Theme.current.individualStackViewItemSpacing * 2)
    }
    #if targetEnvironment(macCatalyst)
      let verticalScrollIndicatorController = VerticalScrollIndicatorController(
        scrollView: scrollView)
      scrollView.delegate = verticalScrollIndicatorController.objCResponder
      self.verticalScrollIndicatorController = verticalScrollIndicatorController
      view.addSubview(verticalScrollIndicatorController.view)
      verticalScrollIndicatorController.view.snp.makeConstraints { make in
        make.top.bottom.trailing.equalTo(scrollView)
        make.width.equalTo(12)
      }
    #endif

    for section in sections {
      let sectionItem = makeSection(section)
      let (sectionViews, sectionViewModifier) = sectionItem.viewModifying.makeViews(
        from: sectionItem)
      sectionViews.forEach { stackView.addArrangedSubview($0) }
      displayingSections[section] = sectionItem
      sectionViewModifiers[section] = sectionViewModifier
    }
  }

  private func makeSection(_ section: ActivitiesSection) -> SettingsSectionItem {
    switch section {
    case .browserTabs:
      return browserTabsSection()
    case .processes:
      return processesSection()
    }
  }

  private func updateSections() {
    guard isViewLoaded else { return }
    for section in sections {
      let sectionItem = makeSection(section)
      guard let displayingSection = displayingSections[section],
        let viewModifier = sectionViewModifiers[section]
      else { continue }
      displayingSections[section] = viewModifier.updateViews(displayingSection, with: sectionItem)
    }
  }

  private func browserTabsSection() -> SettingsSectionItem {
    SettingsSectionItem(
      settingsItems: [
        SettingsBrowserTabsItem(
          currentTabs: currentBrowserTabs, otherTabs: otherBrowserTabs,
          open: { [weak self] id in
            guard let self else { return }
            self.delegate?.activitiesSectionsController(self, didOpenBrowserTab: id)
          },
          openNew: { [weak self] in
            guard let self else { return }
            self.delegate?.activitiesSectionsControllerDidOpenNewBrowserTab(self)
          },
          close: { [weak self] id in
            guard let self else { return }
            self.delegate?.activitiesSectionsController(self, didCloseBrowserTab: id)
          })
      ], title: LocalizedString.forKey("browser_tabs"),
      detail: LocalizedString.forKey("browser_tabs_detail"),
      lookUpKey: "local_code_browser_tabs_detail_hidden", workspace: workspace)
  }

  private func processesSection() -> SettingsSectionItem {
    SettingsSectionItem(
      settingsItems: [
        SettingsProcessesItem(
          currentProcesses: currentProcesses, otherProcesses: otherProcesses,
          stop: { [weak self] id in
            guard let self else { return }
            self.delegate?.activitiesSectionsController(self, didSelectStopProcess: id)
          })
      ], title: LocalizedString.forKey("processes"),
      detail: LocalizedString.forKey("processes_detail"),
      lookUpKey: "local_code_processes_detail_hidden", workspace: workspace)
  }
}

extension ActivitiesSectionsController: LightweightViewControllable {}
