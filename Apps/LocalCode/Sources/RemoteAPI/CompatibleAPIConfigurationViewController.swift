import Localization
import RemoteAPI
import SnapKit
import UIKit

final class CompatibleAPIConfigurationViewController: UIViewController {
  let baseURLField = UITextField()
  let modelField = UITextField()
  let apiKeyField = UITextField()
  let contextField = UITextField()
  let outputField = UITextField()
  let saveButton = UIButton(type: .system)
  let disconnectButton = UIButton(type: .system)
  let cancelButton = UIButton(type: .system)

  private lazy var scrollView = UIScrollView()

  init() {
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .overFullScreen
    modalTransitionStyle = .crossDissolve
    baseURLField.keyboardType = .URL
    baseURLField.placeholder = "https://example.com/v1"
    modelField.placeholder = LocalizedString.forKey("model_optional")
    apiKeyField.isSecureTextEntry = true
    apiKeyField.textContentType = .password
    contextField.keyboardType = .numberPad
    contextField.placeholder = String(
      RemoteModelLimits.openAICompatibleFallback.contextWindowTokens)
    outputField.keyboardType = .numberPad
    outputField.placeholder = String(RemoteModelLimits.openAICompatibleFallback.maximumOutputTokens)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = UIColor.black.withAlphaComponent(0.35)
    view.accessibilityViewIsModal = true
    let availableArea = UILayoutGuide()
    view.addLayoutGuide(availableArea)
    availableArea.snp.makeConstraints { make in
      make.top.leading.trailing.equalTo(view.safeAreaLayoutGuide)
      make.bottom.equalTo(view.keyboardLayoutGuide.snp.top)
    }
    let panel = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    panel.layer.cornerRadius = 14
    if #available(iOS 26.0, *) {
      panel.effect = UIGlassEffect(style: .regular)
      panel.layer.cornerRadius = 34
      panel.layer.cornerCurve = .continuous
    }
    panel.clipsToBounds = true
    view.addSubview(panel)
    panel.snp.makeConstraints { make in
      make.center.equalTo(availableArea)
      make.width.equalTo(480).priority(999)
      make.width.lessThanOrEqualTo(availableArea).offset(-40)
      make.top.greaterThanOrEqualTo(availableArea).offset(16)
      make.bottom.lessThanOrEqualTo(availableArea).offset(-16)
    }

    let titleLabel = UILabel()
    titleLabel.text = LocalizedString.forKey("remote_api")
    titleLabel.font = .preferredFont(forTextStyle: .headline)
    titleLabel.adjustsFontForContentSizeCategory = true
    titleLabel.textAlignment = .center
    titleLabel.numberOfLines = 0
    titleLabel.accessibilityTraits = .header
    let descriptionLabel = UILabel()
    descriptionLabel.text = LocalizedString.forKey("remote_api_configuration_detail")
    descriptionLabel.font = .preferredFont(forTextStyle: .footnote)
    descriptionLabel.adjustsFontForContentSizeCategory = true
    descriptionLabel.textAlignment = .center
    descriptionLabel.numberOfLines = 0
    let header = UIStackView(arrangedSubviews: [titleLabel, descriptionLabel])
    header.axis = .vertical
    header.spacing = 4
    header.isLayoutMarginsRelativeArrangement = true
    header.directionalLayoutMargins = .zero
    if #available(iOS 26.0, *) {
      titleLabel.textAlignment = .natural
      descriptionLabel.textAlignment = .natural
      descriptionLabel.textColor = .secondaryLabel
      descriptionLabel.font = .preferredFont(forTextStyle: .subheadline)
      header.spacing = 8
      header.directionalLayoutMargins = .init(top: 4, leading: 10, bottom: 4, trailing: 10)
    }

    let fields = UIStackView()
    fields.axis = .vertical
    fields.spacing = 16
    fields.addArrangedSubview(header)
    scrollView.keyboardDismissMode = .interactive
    scrollView.addSubview(fields)
    fields.snp.makeConstraints { make in
      make.edges.equalTo(scrollView.contentLayoutGuide).inset(20)
      make.width.equalTo(scrollView.frameLayoutGuide).offset(-40)
    }
    scrollView.snp.makeConstraints { make in
      make.height.equalTo(fields.snp.height).offset(40).priority(.low)
    }
    for (field, titleKey, tipKey) in [
      (baseURLField, "base_api_url", "remote_api_url_tip"),
      (modelField, "model_optional", "remote_api_model_tip"),
      (apiKeyField, "api_key", "remote_api_key_tip"),
      (contextField, "remote_api_fallback_context", "remote_api_context_tip"),
      (outputField, "remote_api_fallback_output", "remote_api_output_tip"),
    ] {
      let label = UILabel()
      label.text = LocalizedString.forKey(titleKey)
      label.font = .preferredFont(forTextStyle: .caption1)
      label.adjustsFontForContentSizeCategory = true
      label.numberOfLines = 0
      label.setContentCompressionResistancePriority(.required, for: .vertical)
      field.accessibilityLabel = label.text
      field.font = .preferredFont(forTextStyle: .body)
      field.adjustsFontForContentSizeCategory = true
      field.borderStyle = .roundedRect
      if #available(iOS 26.0, *) {
        field.borderStyle = .none
        field.backgroundColor = .tertiarySystemFill
        field.layer.cornerRadius = 12
        field.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 1))
        field.leftViewMode = .always
        field.rightView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 1))
        field.rightViewMode = .always
      }
      field.autocapitalizationType = .none
      field.autocorrectionType = .no
      field.snp.makeConstraints { make in make.height.greaterThanOrEqualTo(36) }
      let tip = UILabel()
      tip.text = LocalizedString.forKey(tipKey)
      tip.font = .preferredFont(forTextStyle: .caption1)
      tip.adjustsFontForContentSizeCategory = true
      tip.textColor = .secondaryLabel
      tip.numberOfLines = 0
      tip.setContentCompressionResistancePriority(.required, for: .vertical)
      field.accessibilityHint = tip.text
      let section = UIStackView(arrangedSubviews: [label, tip, field])
      section.axis = .vertical
      section.spacing = 4
      fields.addArrangedSubview(section)
    }

    let actions = UIStackView()
    actions.axis = .vertical
    if #available(iOS 26.0, *) {
      actions.spacing = 8
      actions.isLayoutMarginsRelativeArrangement = true
      actions.directionalLayoutMargins = .init(top: 12, leading: 16, bottom: 16, trailing: 16)
    }
    for (button, titleKey) in [
      (saveButton, "save"), (disconnectButton, "remote_api_disconnect"), (cancelButton, "cancel"),
    ] where !button.isHidden {
      if #available(iOS 26.0, *) {
        var configuration = UIButton.Configuration.filled()
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor =
          button === saveButton ? view.tintColor : .tertiarySystemFill
        configuration.baseForegroundColor =
          button === saveButton
          ? .white
          : button === disconnectButton ? .systemRed : .label
        let textStyle: UIFont.TextStyle = button === saveButton ? .headline : .body
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
          var attributes = $0
          attributes.font = .preferredFont(forTextStyle: textStyle)
          return attributes
        }
        button.configuration = configuration
      } else {
        let separator = UIView()
        separator.backgroundColor = .separator
        actions.addArrangedSubview(separator)
        separator.snp.makeConstraints { make in
          make.height.equalTo(1 / traitCollection.displayScale)
        }
      }
      button.setTitle(LocalizedString.forKey(titleKey), for: .normal)
      button.titleLabel?.font = .preferredFont(
        forTextStyle: button === saveButton ? .headline : .body)
      button.titleLabel?.adjustsFontForContentSizeCategory = true
      if button === disconnectButton { button.tintColor = .systemRed }
      actions.addArrangedSubview(button)
      button.snp.makeConstraints { make in make.height.greaterThanOrEqualTo(44) }
    }
    let content = UIStackView(arrangedSubviews: [scrollView, actions])
    content.axis = .vertical
    panel.contentView.addSubview(content)
    content.snp.makeConstraints { make in make.edges.equalToSuperview() }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    if let field = [baseURLField, modelField, apiKeyField, contextField, outputField]
      .first(where: { $0.isFirstResponder })
    {
      scrollView.scrollRectToVisible(field.convert(field.bounds, to: scrollView), animated: false)
    }
  }

  override func accessibilityPerformEscape() -> Bool {
    cancelButton.sendActions(for: .touchUpInside)
    return true
  }
}
