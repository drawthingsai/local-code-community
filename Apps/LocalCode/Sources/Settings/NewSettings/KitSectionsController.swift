import Components
import Localization
import SQLiteDflat
import SnapKit
import Style
import UIKit

private enum KitSection: CaseIterable, Hashable {
  case drawThings
  case permittedDirectories
  case messagesPermission
  case mailPermission
  case photosPermission
  case calendarPermission
  case notesPermission
}

enum PermissionState: Equatable {
  case notDetermined
  case authorized
  case denied
  /// Denied in system Settings, which Local Code cannot change.
  case deniedBySystem

  var title: String {
    switch self {
    case .notDetermined: return LocalizedString.forKey("not_determined")
    case .authorized: return LocalizedString.forKey("authorized")
    case .denied, .deniedBySystem: return LocalizedString.forKey("denied")
    }
  }
}

protocol KitSectionsControllerDelegate: AnyObject {
  func kitSectionsControllerDidSelectDrawThingsModelsInApp(_ controller: KitSectionsController)
  func kitSectionsController(
    _ controller: KitSectionsController, didSelectDrawThingsModelsFolder currentFolder: String?)
  func kitSectionsController(
    _ controller: KitSectionsController, didPermitEnabledChange value: Bool)
  func kitSectionsController(
    _ controller: KitSectionsController, didSetDirectoryEnabled value: Bool, path: String)
  func kitSectionsController(_ controller: KitSectionsController, didRemoveDirectory path: String)
  func kitSectionsController(
    _ controller: KitSectionsController, didSelectPermission permission: PermissionState,
    for directory: AppDataDirectory)
  func kitSectionsController(
    _ controller: KitSectionsController, didSelectPermission permission: PermissionState,
    for resource: ProtectedResource)
}

final class KitSectionsController {
  let view = UIView(frame: .zero)
  weak var delegate: KitSectionsControllerDelegate?
  private let workspace: SQLiteWorkspace
  private var isViewLoaded = false
  private var verticalScrollIndicatorController: VerticalScrollIndicatorController? = nil
  private let sections: [KitSection] = [
    .drawThings, .permittedDirectories, .messagesPermission, .mailPermission, .photosPermission,
    .calendarPermission, .notesPermission,
  ]
  private var displayingSections: [KitSection: any SettingsViewObservable] = [:]
  private var sectionViewModifiers: [KitSection: any SettingsViewModifying] = [:]
  var drawThingsModelsFolder: String? {
    didSet {
      guard drawThingsModelsFolder != oldValue else { return }
      updateKitSections()
    }
  }
  var isPermitEnabled = true {
    didSet {
      guard isPermitEnabled != oldValue else { return }
      updateKitSections()
    }
  }
  var permittedDirectories = [String]() {
    didSet {
      guard permittedDirectories != oldValue else { return }
      updateKitSections()
    }
  }
  var disabledPermittedDirectories = Set<String>() {
    didSet {
      guard disabledPermittedDirectories != oldValue else { return }
      updateKitSections()
    }
  }
  /// Missing folders are not determined.
  var appDataPermissions = [AppDataDirectory: PermissionState]() {
    didSet {
      guard appDataPermissions != oldValue else { return }
      updateKitSections()
    }
  }
  /// Missing resources are not determined.
  var protectedResourcePermissions = [ProtectedResource: PermissionState]() {
    didSet {
      guard protectedResourcePermissions != oldValue else { return }
      updateKitSections()
    }
  }

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

  private func makeSection(_ section: KitSection) -> SettingsSectionItem {
    switch section {
    case .drawThings:
      return drawThingsSection()
    case .permittedDirectories:
      return permittedDirectoriesSection()
    case .messagesPermission:
      return appDataPermissionSection(.messages)
    case .mailPermission:
      return appDataPermissionSection(.mail)
    case .photosPermission:
      return protectedResourcePermissionSection(.photos)
    case .calendarPermission:
      return protectedResourcePermissionSection(.calendar)
    case .notesPermission:
      return appDataPermissionSection(.notes)
    }
  }

  private func permittedDirectoriesSection() -> SettingsSectionItem {
    var directories = SettingsPermittedDirectoriesItem(
      value: Dictionary(
        uniqueKeysWithValues: permittedDirectories.map {
          ($0, !disabledPermittedDirectories.contains($0))
        }),
      setEnabled: { [weak self] path, value in
        guard let self else { return }
        self.delegate?.kitSectionsController(self, didSetDirectoryEnabled: value, path: path)
      },
      remove: { [weak self] path in
        guard let self else { return }
        self.delegate?.kitSectionsController(self, didRemoveDirectory: path)
      })
    directories.isHidden = !isPermitEnabled || permittedDirectories.isEmpty
    var section = SettingsSectionItem(
      settingsItems: [
        SettingsSwitchItem(value: isPermitEnabled, title: LocalizedString.forKey("enable")) {
          [weak self] value in
          guard let self else { return }
          self.delegate?.kitSectionsController(self, didPermitEnabledChange: value)
        },
        directories,
      ], title: LocalizedString.forKey("permitted_folders"),
      detail: LocalizedString.forKey("permitted_folders_detail"),
      lookUpKey: "local_code_permitted_folders_detail_hidden", workspace: workspace)
    // With Enable off the switch stays visible even with no folders, because permit refuses
    // every request until it is turned back on.
    section.isHidden = isPermitEnabled && permittedDirectories.isEmpty
    return section
  }

  private func appDataPermissionSection(_ directory: AppDataDirectory) -> SettingsSectionItem {
    let title: String
    let detail: String
    let lookUpKey: String
    switch directory {
    case .messages:
      title = LocalizedString.forKey("messages_permission")
      detail = LocalizedString.forKey("messages_permission_detail")
      lookUpKey = "local_code_messages_permission_detail_hidden"
    case .mail:
      title = LocalizedString.forKey("mail_permission")
      detail = LocalizedString.forKey("mail_permission_detail")
      lookUpKey = "local_code_mail_permission_detail_hidden"
    case .notes:
      title = LocalizedString.forKey("notes_permission")
      detail = LocalizedString.forKey("notes_permission_detail")
      lookUpKey = "local_code_notes_permission_detail_hidden"
    }
    return SettingsSectionItem(
      settingsItems: [
        SettingsButtonItem(
          value: appDataPermissions[directory] ?? .notDetermined,
          showsMenuAsPrimaryAction: true,
          makeButtonsUI: { [weak self] permission, button in
            button?.menu = UIMenu(
              children: [PermissionState.authorized, .denied, .notDetermined].map { option in
                UIAction(title: option.title, state: permission == option ? .on : .off) {
                  [weak self] _ in
                  guard let self else { return }
                  self.delegate?.kitSectionsController(
                    self, didSelectPermission: option, for: directory)
                }
              })
            button?.setTitle(permission.title, for: .normal)
          })
      ], title: title, detail: detail, lookUpKey: lookUpKey, workspace: workspace)
  }

  private func protectedResourcePermissionSection(_ resource: ProtectedResource)
    -> SettingsSectionItem
  {
    let title: String
    let detail: String
    let lookUpKey: String
    switch resource {
    case .calendar:
      title = LocalizedString.forKey("calendar_permission")
      detail = LocalizedString.forKey("calendar_permission_detail")
      lookUpKey = "local_code_calendar_permission_detail_hidden"
    case .photos:
      title = LocalizedString.forKey("photos_permission")
      detail = LocalizedString.forKey("photos_permission_detail")
      lookUpKey = "local_code_photos_permission_detail_hidden"
    }
    return SettingsSectionItem(
      settingsItems: [
        SettingsButtonItem(
          value: protectedResourcePermissions[resource] ?? .notDetermined,
          showsMenuAsPrimaryAction: true,
          makeButtonsUI: { [weak self] permission, button in
            // Local Code can ask for access once, and block its own command after access is
            // granted, but only system Settings can revoke access.
            let options: [(title: String, permission: PermissionState)]
            switch permission {
            case .notDetermined:
              options = [
                (LocalizedString.forKey("authorize"), .authorized),
                (PermissionState.notDetermined.title, .notDetermined),
              ]
            case .authorized, .denied:
              options = [
                (PermissionState.authorized.title, .authorized),
                (PermissionState.denied.title, .denied),
              ]
            case .deniedBySystem:
              options = [(PermissionState.deniedBySystem.title, .deniedBySystem)]
            }
            button?.menu = UIMenu(
              children: options.map { option in
                UIAction(
                  title: option.title, state: permission == option.permission ? .on : .off
                ) { [weak self] _ in
                  guard let self else { return }
                  self.delegate?.kitSectionsController(
                    self, didSelectPermission: option.permission, for: resource)
                }
              })
            button?.setTitle(permission.title, for: .normal)
          })
      ], title: title, detail: detail, lookUpKey: lookUpKey, workspace: workspace)
  }

  private func updateKitSections() {
    guard isViewLoaded else { return }
    for section in sections {
      let sectionItem = makeSection(section)
      guard let displayingSection = displayingSections[section],
        let viewModifier = sectionViewModifiers[section]
      else { continue }
      displayingSections[section] = viewModifier.updateViews(displayingSection, with: sectionItem)
    }
  }

  private func drawThingsSection() -> SettingsSectionItem {
    SettingsSectionItem(
      settingsItems: [
        SettingsButtonItem(
          value: drawThingsModelsFolder, title: LocalizedString.forKey("model_folder"),
          showsMenuAsPrimaryAction: true, showsTooltip: true,
          makeButtonsUI: { [weak self] folder, button in
            button?.configuration?.titleLineBreakMode = .byTruncatingHead
            button?.menu = UIMenu(children: [
              UIAction(
                title: LocalizedString.forKey("in_local_code_app"),
                state: folder == nil ? .on : .off
              ) { [weak self] _ in
                guard let self else { return }
                self.delegate?.kitSectionsControllerDidSelectDrawThingsModelsInApp(self)
              },
              UIAction(title: LocalizedString.forKey("select_a_folder_dot")) { [weak self] _ in
                guard let self else { return }
                self.delegate?.kitSectionsController(
                  self, didSelectDrawThingsModelsFolder: self.drawThingsModelsFolder)
              },
            ])
            button?.setTitle(folder ?? LocalizedString.forKey("in_local_code_app"), for: .normal)
          })
      ], title: "Draw Things", detail: LocalizedString.forKey("draw_things_detail"),
      lookUpKey: "local_code_draw_things_detail_hidden", workspace: workspace)
  }
}

extension KitSectionsController: LightweightViewControllable {}
