import Components
import Localization
import ModelZoo
import SQLiteDflat
import SnapKit
import Style
import UIKit

protocol ServeSectionsControllerDelegate: AnyObject {
  func serveSectionsController(
    _ controller: ServeSectionsController, didChangeResponsesAPIEnabled isEnabled: Bool)
  func serveSectionsController(_ controller: ServeSectionsController, didSelectPort port: Int)
  func serveSectionsController(_ controller: ServeSectionsController, didSelectIP ip: String)
  func serveSectionsController(
    _ controller: ServeSectionsController, didTapModelSelector sourceView: UIView)
}

/// The Serve page of the rail, on the Mac. What's being served shows beside it, over the chat.
final class ServeSectionsController {
  let view = UIView(frame: .zero)
  weak var delegate: ServeSectionsControllerDelegate?
  var isResponsesAPIEnabled = false {
    didSet {
      guard isResponsesAPIEnabled != oldValue else { return }
      updateSections()
    }
  }
  var port = ServeController.defaultPort {
    didSet {
      guard port != oldValue else { return }
      updateSections()
    }
  }
  /// 127.0.0.1 or 0.0.0.0.
  var ip = "127.0.0.1" {
    didSet {
      guard ip != oldValue else { return }
      updateSections()
    }
  }
  /// The file of the model being served.
  var model: String? {
    didSet {
      guard model != oldValue else { return }
      updateSections()
    }
  }
  private let workspace: SQLiteWorkspace
  private var isViewLoaded = false
  private var displayingSections = [any SettingsViewObservable]()
  private var sectionViewModifiers = [any SettingsViewModifying]()

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
    view.addSubview(stackView)
    stackView.snp.makeConstraints { make in
      make.top.leading.trailing.equalToSuperview().inset(
        Theme.current.individualStackViewItemSpacing)
    }
    for section in makeSections() {
      let (sectionViews, sectionViewModifier) = section.viewModifying.makeViews(from: section)
      sectionViews.forEach { stackView.addArrangedSubview($0) }
      displayingSections.append(section)
      sectionViewModifiers.append(sectionViewModifier)
    }
  }

  private func updateSections() {
    guard isViewLoaded else { return }
    for (index, section) in makeSections().enumerated() {
      displayingSections[index] = sectionViewModifiers[index].updateViews(
        displayingSections[index], with: section)
    }
  }

  private func makeSections() -> [SettingsSectionItem] {
    [responsesAPISection(), modelSection()]
  }

  private func responsesAPISection() -> SettingsSectionItem {
    // Port and IP as Draw Things offers them for its API server.
    var portItem = SettingsEditableButtonItem(
      value: port, title: LocalizedString.forKey("port"), buttonTitle: "\(port)",
      extraTopPadding: Theme.current.stackViewItemSpacing
    ) { [weak self] port in
      guard let self, let port = Int(port) else { return }
      self.delegate?.serveSectionsController(self, didSelectPort: port)
    }
    portItem.isHidden = !isResponsesAPIEnabled
    var ipItem = SettingsButtonItem(
      value: ip, title: LocalizedString.forKey("ip"), showsMenuAsPrimaryAction: true,
      extraTopPadding: Theme.current.stackViewItemSpacing,
      makeButtonsUI: { [weak self] ip, button in
        let actions = [
          ("127.0.0.1", LocalizedString.forKey("localhost_ip_detail")),
          ("0.0.0.0", LocalizedString.forKey("global_ip_detail")),
        ].map { value, title in
          UIAction(title: title, state: ip == value ? .on : .off) { [weak self] _ in
            guard let self else { return }
            self.delegate?.serveSectionsController(self, didSelectIP: value)
          }
        }
        button?.setTitle(actions[ip == "0.0.0.0" ? 1 : 0].title, for: .normal)
        button?.menu = UIMenu(children: actions)
      })
    ipItem.isHidden = !isResponsesAPIEnabled
    return SettingsSectionItem(
      settingsItems: [
        SettingsSwitchItem(
          value: isResponsesAPIEnabled, title: LocalizedString.forKey("enable"),
          handleValueChange: { [weak self] value in
            guard let self else { return }
            self.delegate?.serveSectionsController(self, didChangeResponsesAPIEnabled: value)
          }),
        portItem,
        ipItem,
      ], title: LocalizedString.forKey("responses_api"),
      detail: LocalizedString.format(
        key: "responses_api_detail", ServeController.baseURL(port: port)),
      lookUpKey: "local_code_responses_api_detail_hidden", workspace: workspace)
  }

  // A section of its own with a full-width selector, like the model in Draw Things' settings.
  private func modelSection() -> SettingsSectionItem {
    SettingsSectionItem(
      settingsItems: [
        SettingsButtonItem(
          value: model ?? "", showsTooltip: true,
          buttonAction: { [weak self] sourceView, _ in
            guard let self else { return }
            self.delegate?.serveSectionsController(self, didTapModelSelector: sourceView)
          },
          makeButtonsUI: { model, button in
            button?.setTitle(
              model.isEmpty
                ? LocalizedString.forKey("unspecified")
                : LLMZoo.humanReadableNameForModel(model), for: .normal)
          })
      ], title: LocalizedString.forKey("model"),
      detail: LocalizedString.forKey("serve_model_detail"),
      lookUpKey: "local_code_serve_model_detail_hidden", workspace: workspace)
  }
}

extension ServeSectionsController: LightweightViewControllable {}
