import Localization
import SnapKit
import Style
import UIKit

protocol ProjectBarControllerDelegate: AnyObject {
  func projectBarControllerDidTapSettings(_ controller: ProjectBarController)
  func projectBarController(
    _ controller: ProjectBarController, didTapProjectSelector sourceView: UIView)
  func projectBarControllerDidTapNewChat(_ controller: ProjectBarController)
}

final class ProjectBarController {
  weak var delegate: ProjectBarControllerDelegate?

  let view: UIView
  var projectName: String? {
    didSet {
      guard var configuration = projectButton.configuration else { return }
      configuration.title = projectName ?? LocalizedString.forKey("projects")
      projectButton.configuration = configuration
      newChatButton.isEnabled = projectName != nil
    }
  }

  private let userInterfaceIdiom: UIUserInterfaceIdiom

  private lazy var settingsButton: UIButton = {
    let button = UIButton(type: .custom)
    button.accessibilityLabel = LocalizedString.forKey("settings")
    var configuration: UIButton.Configuration
    if #available(iOS 26.0, *) {
      configuration = .glass()
    } else {
      configuration = .filled()
    }
    configuration.cornerStyle = .capsule
    configuration.baseForegroundColor = .primaryText
    configuration.image = #imageLiteral(resourceName: "hamburger").withRenderingMode(
      .alwaysTemplate)
    configuration.contentInsets = NSDirectionalEdgeInsets(
      top: 14, leading: 14, bottom: 14, trailing: 14)
    if #unavailable(iOS 26.0) {
      configuration.background.backgroundColor = .tertiaryFill
    }
    button.configuration = configuration
    button.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        self.delegate?.projectBarControllerDidTapSettings(self)
      }, for: .touchUpInside)
    return button
  }()

  private lazy var projectButton: UIButton = {
    let button = UIButton(type: .custom)
    var configuration: UIButton.Configuration
    if #available(iOS 26.0, *) {
      configuration = .glass()
    } else {
      configuration = .filled()
    }
    configuration.cornerStyle = .capsule
    configuration.title = projectName ?? LocalizedString.forKey("projects")
    configuration.baseForegroundColor = .primaryText
    configuration.image = #imageLiteral(resourceName: "chevron-down-16").withRenderingMode(
      .alwaysTemplate)
    configuration.imagePlacement = .trailing
    configuration.imagePadding = 4
    configuration.contentInsets = NSDirectionalEdgeInsets(
      top: 12, leading: 20, bottom: 12, trailing: 16)
    configuration.titleLineBreakMode = .byTruncatingTail
    if #unavailable(iOS 26.0) {
      configuration.background.backgroundColor = .tertiaryFill
    }
    button.configuration = configuration
    button.contentHorizontalAlignment = .leading
    FontMetrics.default.scaleFont(.systemFont(ofSize: 16, weight: .medium), bindTo: button)
    button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    button.addAction(
      UIAction { [weak self, weak button] _ in
        guard let self, let button else { return }
        self.delegate?.projectBarController(self, didTapProjectSelector: button)
      }, for: .touchUpInside)
    return button
  }()

  private lazy var newChatButton: UIButton = {
    let button = UIButton(type: .custom)
    button.accessibilityLabel = LocalizedString.forKey("new_chat")
    var configuration: UIButton.Configuration
    if #available(iOS 26.0, *) {
      configuration = .glass()
    } else {
      configuration = .filled()
    }
    configuration.cornerStyle = .capsule
    configuration.baseForegroundColor = .primaryText
    configuration.image = #imageLiteral(resourceName: "chat-new-24").withRenderingMode(
      .alwaysTemplate)
    configuration.contentInsets = NSDirectionalEdgeInsets(
      top: 14, leading: 14, bottom: 14, trailing: 14)
    if #unavailable(iOS 26.0) {
      configuration.background.backgroundColor = .tertiaryFill
    }
    button.configuration = configuration
    button.isEnabled = projectName != nil
    button.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        self.delegate?.projectBarControllerDidTapNewChat(self)
      }, for: .touchUpInside)
    return button
  }()

  init(userInterfaceIdiom: UIUserInterfaceIdiom) {
    self.userInterfaceIdiom = userInterfaceIdiom
    view = UIView(frame: .zero)
    let stackView = UIStackView(frame: .zero)
    stackView.axis = .horizontal
    stackView.spacing = 16
    stackView.alignment = .center
    stackView.distribution = .fill
    let stackContainer: UIView
    if #available(iOS 26.0, *) {
      // Group the glass buttons so they share sampling and can merge / morph with each other.
      let containerEffect = UIGlassContainerEffect()
      containerEffect.spacing = 4
      let effectView = UIVisualEffectView(effect: containerEffect)
      effectView.contentView.addSubview(stackView)
      stackView.snp.makeConstraints { make in
        make.edges.equalToSuperview()
      }
      stackContainer = effectView
    } else {
      stackContainer = stackView
    }
    view.addSubview(stackContainer)
    stackContainer.snp.makeConstraints { make in
      make.edges.equalToSuperview()
      make.height.equalTo(52)
    }
    if userInterfaceIdiom == .phone {
      // The project button sits centered over the bar and fits its title; the glass buttons
      // keep the ends.
      stackView.addArrangedSubview(settingsButton)
      stackView.addArrangedSubview(UIView(frame: .zero))
      stackView.addArrangedSubview(newChatButton)
      settingsButton.snp.makeConstraints { make in
        make.width.height.equalTo(52)
      }
      newChatButton.snp.makeConstraints { make in
        make.width.height.equalTo(52)
      }
      let host = (stackContainer as? UIVisualEffectView)?.contentView ?? view
      host.addSubview(projectButton)
      projectButton.setContentHuggingPriority(.required, for: .horizontal)
      projectButton.snp.makeConstraints { make in
        make.center.equalToSuperview()
        make.height.equalTo(52)
        make.leading.greaterThanOrEqualTo(settingsButton.snp.trailing).offset(12)
        make.trailing.lessThanOrEqualTo(newChatButton.snp.leading).offset(-12)
      }
      return
    }
    stackView.addArrangedSubview(projectButton)
    stackView.setCustomSpacing(12, after: projectButton)
    stackView.addArrangedSubview(newChatButton)
    newChatButton.snp.makeConstraints { make in
      make.width.height.equalTo(52)
    }
    projectButton.snp.makeConstraints { make in
      make.height.equalTo(52)
      make.width.lessThanOrEqualTo(360)
    }
  }
}
