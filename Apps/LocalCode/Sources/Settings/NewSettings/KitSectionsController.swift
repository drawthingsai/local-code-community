import Components
import Localization
import SQLiteDflat
import SnapKit
import Style
import UIKit

private enum KitSection: Hashable {
  case drawThings
  case permittedDirectories
  case messagesPermission
  case mailPermission
  case photosPermission
  case calendarPermission
  case notesPermission
  case messaging(MessagingPlatform)
}

/// A chat app's settings, as Kit shows them.
struct MessagingSettings: Equatable {
  var isEnabled = false
  var pairedAccountCount = 0
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
  func kitSectionsController(
    _ controller: KitSectionsController, didSetEnabled value: Bool, for platform: MessagingPlatform)
  func kitSectionsController(
    _ controller: KitSectionsController, didSelectSetBotTokenFor platform: MessagingPlatform)
  func kitSectionsController(
    _ controller: KitSectionsController, didSelectReconnect platform: MessagingPlatform)
  func kitSectionsController(
    _ controller: KitSectionsController, didForgetPairedAccountsFor platform: MessagingPlatform)
}

final class KitSectionsController {
  let view = UIView(frame: .zero)
  weak var delegate: KitSectionsControllerDelegate?
  private let workspace: SQLiteWorkspace
  private var isViewLoaded = false
  private var verticalScrollIndicatorController: VerticalScrollIndicatorController? = nil
  private let sections: [KitSection] =
    [
      .drawThings, .permittedDirectories, .messagesPermission, .mailPermission, .photosPermission,
      .calendarPermission, .notesPermission,
    ]
    + MessagingPlatform.allCases.filter(MessagingBridge.isAvailable).map { .messaging($0) }
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
  /// Missing platforms are off.
  var messagingSettings = [MessagingPlatform: MessagingSettings]() {
    didSet {
      guard messagingSettings != oldValue else { return }
      updateKitSections()
    }
  }
  var messagingStatus = MessagingBridge.Status(pairingCode: "") {
    didSet {
      guard messagingStatus != oldValue else { return }
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
    case .messaging(let platform):
      return messagingSection(platform)
    }
  }

  private func messagingSection(_ platform: MessagingPlatform) -> SettingsSectionItem {
    let detail: String
    let lookUpKey: String
    switch platform {
    case .iMessage:
      detail = LocalizedString.forKey("imessage_detail")
      lookUpKey = "local_code_imessage_detail_hidden"
    case .telegram:
      detail = LocalizedString.forKey("telegram_detail")
      lookUpKey = "local_code_telegram_detail_hidden"
    case .discord:
      detail = LocalizedString.forKey("discord_detail")
      lookUpKey = "local_code_discord_detail_hidden"
    }
    let settings = messagingSettings[platform] ?? MessagingSettings()
    let status: String
    var warning: SettingsWarning?
    var pairingCode = SettingsPlainTextItem(
      leadingText: LocalizedString.forKey("pairing_code"),
      trailingText: messagingStatus.pairingCode)
    pairingCode.isHidden = true
    switch messagingStatus.connections[platform] {
    case nil:
      if !settings.isEnabled {
        status = LocalizedString.forKey("off")
      } else if platform == .iMessage {
        status = LocalizedString.forKey("needs_messages_permission")
      } else {
        status = LocalizedString.forKey("needs_a_bot_token")
      }
    case .connecting:
      status = LocalizedString.forKey("connecting")
    case .connected(let name):
      if !name.isEmpty {
        status = LocalizedString.format(key: "connected_as", name)
      } else if platform == .iMessage {
        // Nothing to answer until the account writes to itself.
        status = LocalizedString.forKey("message_yourself_to_start")
      } else {
        status = LocalizedString.forKey("connected")
      }
      pairingCode.isHidden = !platform.needsPairing
    case .failed(let reason):
      status = LocalizedString.forKey("not_connected")
      warning = SettingsWarning(text: reason, severity: .error)
    }
    // Setting a token replaces the one before, so this is a plain button rather than a menu.
    var botToken = SettingsButtonItem(
      value: platform,
      buttonImage: UIImage(systemName: "key")?.withRenderingMode(.alwaysTemplate),
      buttonAction: { [weak self] _, platform in
        guard let self else { return }
        self.delegate?.kitSectionsController(self, didSelectSetBotTokenFor: platform)
      },
      makeButtonsUI: { _, button in
        button?.setTitle(LocalizedString.forKey("set_bot_token_dot"), for: .normal)
      })
    botToken.isHidden = !platform.needsPairing
    var pairedAccounts = SettingsButtonItem(
      value: settings.pairedAccountCount, title: LocalizedString.forKey("paired_accounts"),
      showsMenuAsPrimaryAction: true,
      makeButtonsUI: { [weak self] count, button in
        button?.menu = UIMenu(children: [
          UIAction(
            title: LocalizedString.forKey("forget_paired_accounts"), attributes: .destructive
          ) { [weak self] _ in
            guard let self else { return }
            self.delegate?.kitSectionsController(self, didForgetPairedAccountsFor: platform)
          }
        ])
        button?.setTitle(String(count), for: .normal)
      })
    pairedAccounts.isHidden = !platform.needsPairing || settings.pairedAccountCount == 0
    return SettingsSectionItem(
      settingsItems: [
        SettingsSwitchItem(value: settings.isEnabled, title: LocalizedString.forKey("enable")) {
          [weak self] value in
          guard let self else { return }
          self.delegate?.kitSectionsController(self, didSetEnabled: value, for: platform)
        },
        botToken,
        SettingsButtonItem(
          value: status, title: LocalizedString.forKey("status"), warning: warning,
          showsMenuAsPrimaryAction: true,
          makeButtonsUI: { [weak self] status, button in
            button?.menu = UIMenu(children: [
              UIAction(title: LocalizedString.forKey("reconnect")) { [weak self] _ in
                guard let self else { return }
                self.delegate?.kitSectionsController(self, didSelectReconnect: platform)
              }
            ])
            button?.setTitle(status, for: .normal)
          }),
        pairingCode,
        pairedAccounts,
      ], title: platform.title, detail: detail, lookUpKey: lookUpKey, workspace: workspace)
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
    return SettingsSectionItem(
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
