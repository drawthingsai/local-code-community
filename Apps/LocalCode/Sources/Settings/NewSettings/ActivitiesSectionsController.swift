import Components
import Localization
import SQLiteDflat
import SnapKit
import Style
import UIKit

private enum ActivitiesSection: CaseIterable, Hashable {
  case deviceLink
  case browserTabs
  case processes
}

/// What Activities shows for links: on a Mac, whether it serves; this device's connection; and
/// the devices it works with, a phone's Macs or a Mac's phones and iPads.
struct DeviceLinkActivity: Equatable {
  /// Whether this Mac serves its threads; nil on devices that can't serve.
  var isServing: Bool?
  var status: String
  /// Another device disconnected this one; it can ask to connect again.
  var canRejoin = false
  var devices: [SettingsLinkedDevicesItem.Device]
}

protocol ActivitiesSectionsControllerDelegate: AnyObject {
  func activitiesSectionsController(
    _ controller: ActivitiesSectionsController, didChangeServing isServing: Bool)
  /// This device was disconnected and its user asked to connect again.
  func activitiesSectionsControllerDidSelectRejoin(_ controller: ActivitiesSectionsController)
  func activitiesSectionsController(
    _ controller: ActivitiesSectionsController, didSelect action: SettingsLinkedDevicesItem.Action,
    forDevice deviceID: String)
  func activitiesSectionsController(
    _ controller: ActivitiesSectionsController, didOpenBrowserTab id: String)
  func activitiesSectionsController(
    _ controller: ActivitiesSectionsController, didCloseBrowserTab id: String)
  func activitiesSectionsController(
    _ controller: ActivitiesSectionsController, didSelectStopProcess id: Int)
}

/// The Activities page of the rail: links to other devices, and what agents keep
/// running, browser tabs and shell commands.
final class ActivitiesSectionsController {
  let view = UIView(frame: .zero)
  weak var delegate: ActivitiesSectionsControllerDelegate?
  private let workspace: SQLiteWorkspace
  private var isViewLoaded = false
  private var verticalScrollIndicatorController: VerticalScrollIndicatorController? = nil
  private let sections: [ActivitiesSection] = [.deviceLink, .browserTabs, .processes]
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
  private var deviceLink = DeviceLinkActivity(isServing: nil, status: "", devices: [])

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

  func setDeviceLink(_ deviceLink: DeviceLinkActivity) {
    guard deviceLink != self.deviceLink else { return }
    self.deviceLink = deviceLink
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
    case .deviceLink:
      return deviceLinkSection()
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

  private func deviceLinkSection() -> SettingsSectionItem {
    var serve = SettingsSwitchItem(
      value: deviceLink.isServing ?? false, title: LocalizedString.forKey("device_link_serve"),
      handleValueChange: { [weak self] value in
        guard let self else { return }
        self.delegate?.activitiesSectionsController(self, didChangeServing: value)
      })
    serve.isHidden = deviceLink.isServing == nil
    return SettingsSectionItem(
      settingsItems: [
        serve,
        SettingsPlainTextItem(
          leadingText: LocalizedString.forKey("device_link_status"),
          trailingText: deviceLink.status,
          fontSize: 13),
        rejoinItem(),
        SettingsLinkedDevicesItem(
          devices: deviceLink.devices,
          perform: { [weak self] action, id in
            guard let self else { return }
            self.delegate?.activitiesSectionsController(self, didSelect: action, forDevice: id)
          }),
      ], title: LocalizedString.forKey("device_link"),
      detail: LocalizedString.forKey(
        deviceLink.isServing == nil ? "device_link_devices_detail" : "device_link_serve_detail"),
      lookUpKey: "local_code_device_link_detail_hidden", workspace: workspace)
  }

  /// Connect, for a device another one disconnected; hidden otherwise.
  private func rejoinItem() -> SettingsActionItem<String> {
    var item = SettingsActionItem(
      value: LocalizedString.forKey("device_link_connect"),
      buttonAction: { [weak self] _, _ in
        guard let self else { return }
        self.delegate?.activitiesSectionsControllerDidSelectRejoin(self)
      },
      makeButtonsUI: { title, button in
        var configuration = UIButton.Configuration.borderless()
        configuration.titleAlignment = .leading
        configuration.contentInsets = NSDirectionalEdgeInsets(
          top: 0, leading: 12, bottom: 8, trailing: 0)
        configuration.baseBackgroundColor = .clear
        configuration.baseForegroundColor = .secondaryText
        configuration.title = title
        configuration.image = #imageLiteral(resourceName: "arrow-right-16").withRenderingMode(
          .alwaysTemplate)
        configuration.imagePlacement = .trailing
        configuration.imagePadding = 4
        button.contentHorizontalAlignment = .leading
        button.configuration = configuration
        FontMetrics.default.scaleFont(.systemFont(ofSize: 11, weight: .regular), bindTo: button)
      })
    item.isHidden = !deviceLink.canRejoin
    return item
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
