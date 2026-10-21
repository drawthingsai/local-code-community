import Components
import Localization
import SnapKit
import Style
import UIKit
import UserAccount

protocol AccountViewControllerDelegate: AnyObject {
  func accountViewController(
    _ viewController: AccountViewController,
    didRequestSignIn provider: AccountManager.SignInProvider)
  func accountViewController(_ viewController: AccountViewController, didRequestCopy value: String)
  func accountViewControllerDidRequestTopUp(_ viewController: AccountViewController)
  func accountViewControllerDidRequestDeleteAccount(_ viewController: AccountViewController)
  func accountViewControllerDidRequestSignOut(_ viewController: AccountViewController)
}

final class AccountViewController: UIViewController {
  enum State: Equatable {
    case signedOut(error: String?)
    case busy(message: String)
    case signedIn(
      snapshot: AccountClient.CreditSnapshot?, accountID: String?, apiKey: String?,
      error: String?)
  }

  weak var delegate: AccountViewControllerDelegate?
  var state: State = .signedOut(error: nil) {
    didSet {
      guard isViewLoaded, state != oldValue else { return }
      isAPIKeyVisible = false
      render()
    }
  }

  private var displayedAPIKey: String?
  private var isAPIKeyVisible = false
  private var copyResetTimer: Timer?

  deinit {
    copyResetTimer?.invalidate()
  }

  private lazy var stackView: UIStackView = {
    let stackView = UIStackView()
    stackView.axis = .vertical
    stackView.alignment = .fill
    return stackView
  }()

  private lazy var appIconView: UIView = {
    let view = UIView(frame: .zero)
    view.isUserInteractionEnabled = false
    let shadowView = PassThroughView()
    shadowView.layer.cornerRadius = 12
    shadowView.layer.shadowColor = UIColor.black.cgColor
    shadowView.layer.shadowRadius = 3.33
    shadowView.layer.shadowOffset = CGSize(width: 0, height: 1.67)
    shadowView.layer.shadowOpacity = 0.24
    shadowView.backgroundColor = .secondaryBackground
    view.addSubview(shadowView)
    shadowView.snp.makeConstraints { make in
      make.edges.equalToSuperview().inset(1)
    }
    let imageView = UIImageView(image: UIImage(imageLiteralResourceName: "keyboard-money"))
    imageView.contentMode = .scaleAspectFill
    imageView.layer.cornerRadius = 12
    imageView.clipsToBounds = true
    imageView.isUserInteractionEnabled = false
    view.addSubview(imageView)
    imageView.snp.makeConstraints { make in
      make.edges.equalToSuperview()
    }
    let borderView = BorderView.defaultBorderView(cornerRadius: 12)
    borderView.layer.borderWidth = 0.5
    borderView.isUserInteractionEnabled = false
    borderView.borderColor = .tertiaryBorder
    view.addSubview(borderView)
    borderView.snp.makeConstraints { make in
      make.edges.equalToSuperview()
    }
    return view
  }()

  private lazy var titleLabel: UILabel = {
    let label = UILabel()
    label.text = "Local Code"
    label.textColor = .secondaryText
    FontMetrics.default.scaleFont(.systemFont(ofSize: 14, weight: .semibold), bindTo: label)
    return label
  }()

  private lazy var versionLabel: UILabel = {
    let label = UILabel()
    label.textColor = .quaternaryText
    if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
      label.text = "V\(version)"
    }
    FontMetrics.default.scaleFont(.systemFont(ofSize: 11), bindTo: label)
    return label
  }()

  private lazy var headerView: UIView = {
    let view = UIView()
    view.addSubview(appIconView)
    view.addSubview(titleLabel)
    view.addSubview(versionLabel)
    let divider = SettingsViewFactory.makeDividerView()
    view.addSubview(divider)
    divider.snp.makeConstraints { make in
      make.height.equalTo(0.5)
      make.leading.trailing.bottom.equalToSuperview()
    }
    appIconView.snp.makeConstraints { make in
      make.leading.equalToSuperview().inset(16)
      make.top.bottom.equalToSuperview().inset(11)
      make.size.equalTo(40)
    }
    titleLabel.snp.makeConstraints { make in
      make.leading.equalTo(appIconView.snp.trailing).offset(8)
      make.trailing.lessThanOrEqualToSuperview().inset(16)
      make.centerY.equalTo(appIconView).offset(-10)
    }
    versionLabel.snp.makeConstraints { make in
      make.leading.equalTo(titleLabel)
      make.trailing.lessThanOrEqualToSuperview().inset(16)
      make.centerY.equalTo(appIconView).offset(12)
    }
    return view
  }()

  private lazy var appleButton: UIButton = {
    let button = UIButton(type: .custom)
    var configuration = UIButton.Configuration.bordered()
    configuration.titleAlignment = .center
    configuration.background.cornerRadius = 16
    configuration.imagePadding = 8
    configuration.image = UIImage(imageLiteralResourceName: "apple-20")
      .withTintColor(.nonaryText)
    configuration.baseForegroundColor = .nonaryText
    configuration.background.backgroundColor = .primaryFill
    configuration.background.strokeWidth = 0
    configuration.title = LocalizedString.forKey("sign_in_with_apple")
    button.configuration = configuration
    button.tintAdjustmentMode = .normal
    button.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        self.delegate?.accountViewController(self, didRequestSignIn: .apple)
      }, for: .touchUpInside)
    FontMetrics.default.scaleFont(.systemFont(ofSize: 16, weight: .semibold), bindTo: button)
    return button
  }()

  private lazy var googleButton: UIButton = {
    let button = UIButton(type: .custom)
    var configuration = UIButton.Configuration.plain()
    configuration.titleAlignment = .center
    configuration.imagePadding = 4
    configuration.image = UIImage(imageLiteralResourceName: "google-20").withTintColor(
      .secondaryText)
    configuration.baseForegroundColor = .secondaryText
    configuration.background.backgroundColor = .clear
    configuration.contentInsets = .zero
    configuration.title = LocalizedString.forKey("sign_in_with_google")
    button.configuration = configuration
    button.tintAdjustmentMode = .normal
    button.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        self.delegate?.accountViewController(self, didRequestSignIn: .google)
      }, for: .touchUpInside)
    FontMetrics.default.scaleFont(.systemFont(ofSize: 12, weight: .medium), bindTo: button)
    return button
  }()

  private lazy var signInView: UIView = {
    let view = UIView()
    let stackView = UIStackView(arrangedSubviews: [appleButton, googleButton])
    stackView.axis = .vertical
    stackView.alignment = .fill
    stackView.distribution = .fill
    stackView.spacing = 8
    view.addSubview(stackView)
    stackView.snp.makeConstraints { make in
      make.edges.equalToSuperview().inset(16)
    }
    appleButton.snp.makeConstraints { make in
      make.height.equalTo(48)
    }
    googleButton.snp.makeConstraints { make in
      make.height.equalTo(24)
    }
    return view
  }()

  private lazy var activityIndicator: UIActivityIndicatorView = {
    let indicator = UIActivityIndicatorView(style: .medium)
    indicator.hidesWhenStopped = true
    return indicator
  }()

  private lazy var busyLabel: UILabel = {
    let label = UILabel()
    label.textAlignment = .center
    label.textColor = .secondaryText
    label.numberOfLines = 0
    FontMetrics.default.scaleFont(.systemFont(ofSize: 12), bindTo: label)
    return label
  }()

  private lazy var busyView: UIView = {
    let view = UIView()
    view.addSubview(activityIndicator)
    view.addSubview(busyLabel)
    activityIndicator.snp.makeConstraints { make in
      make.top.equalToSuperview().inset(16)
      make.centerX.equalToSuperview()
    }
    busyLabel.snp.makeConstraints { make in
      make.top.equalTo(activityIndicator.snp.bottom).offset(8)
      make.leading.trailing.equalToSuperview().inset(16)
      make.bottom.equalToSuperview().inset(16)
    }
    return view
  }()

  private lazy var balanceView: AccountBalanceView = {
    let view = AccountBalanceView()
    view.onTopUp = { [weak self] in
      guard let self else { return }
      delegate?.accountViewControllerDidRequestTopUp(self)
    }
    return view
  }()

  private lazy var accountIDTitleLabel: UILabel = {
    let label = UILabel()
    label.text = LocalizedString.forKey("account_id")
    label.textColor = .quaternaryText
    FontMetrics.default.scaleFont(.systemFont(ofSize: 11), bindTo: label)
    return label
  }()

  private lazy var accountIDLabel: UILabel = {
    let label = UILabel()
    label.textColor = .secondaryText
    label.lineBreakMode = .byTruncatingMiddle
    FontMetrics.default.scaleFont(.systemFont(ofSize: 16, weight: .light), bindTo: label)
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return label
  }()

  private lazy var accountIDCopiedLabel: UILabel = {
    let label = UILabel()
    label.text = LocalizedString.forKey("copied")
    label.textColor = .shadePalette(for: .green)
    label.alpha = 0
    FontMetrics.default.scaleFont(.systemFont(ofSize: 11), bindTo: label)
    label.setContentCompressionResistancePriority(.required, for: .horizontal)
    return label
  }()

  private lazy var apiKeyTitleLabel: UILabel = {
    let label = UILabel()
    label.text = LocalizedString.forKey("api_key")
    label.textColor = .quaternaryText
    FontMetrics.default.scaleFont(.systemFont(ofSize: 11), bindTo: label)
    return label
  }()

  private lazy var apiKeyLabel: UITextView = {
    let label = UITextView(frame: .zero)
    label.textColor = .secondaryText
    label.isEditable = false
    label.isSelectable = false
    label.isScrollEnabled = false
    label.backgroundColor = .clear
    label.textContainerInset = .zero
    label.textContainer.lineFragmentPadding = 0
    label.textContainer.maximumNumberOfLines = 1
    label.textContainer.lineBreakMode = .byTruncatingMiddle
    FontMetrics.default.scaleFont(.systemFont(ofSize: 16, weight: .light), bindTo: label) {
      $0.font = $1
    }
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return label
  }()

  private lazy var apiKeyCopiedLabel: UILabel = {
    let label = UILabel()
    label.text = LocalizedString.forKey("copied")
    label.textColor = .shadePalette(for: .green)
    label.alpha = 0
    FontMetrics.default.scaleFont(.systemFont(ofSize: 11), bindTo: label)
    label.setContentCompressionResistancePriority(.required, for: .horizontal)
    return label
  }()

  private lazy var eyeButton: UIButton = {
    let button = UIButton(type: .custom)
    var configuration = UIButton.Configuration.plain()
    configuration.baseForegroundColor = .secondaryText
    configuration.image = UIImage(imageLiteralResourceName: "eye-24").withTintColor(.secondaryText)
    button.configuration = configuration
    button.configurationUpdateHandler = {
      guard var configuration = $0.configuration else { return }
      let imageName = $0.state.contains(.selected) ? "eye-slash-24" : "eye-24"
      configuration.image = UIImage(imageLiteralResourceName: imageName).withTintColor(
        .secondaryText)
      configuration.background.backgroundColor = .clear
      $0.configuration = configuration
    }
    button.addAction(
      UIAction { [weak self] _ in
        guard let self, displayedAPIKey?.isEmpty == false else { return }
        isAPIKeyVisible.toggle()
        updateAPIKeyPresentation()
      }, for: .touchUpInside)
    return button
  }()

  private lazy var credentialsView: UIView = {
    let view = UIView()
    let accountIDIcon = UIImageView(
      image: UIImage(imageLiteralResourceName: "id-card-filled-16").withTintColor(.quaternaryText))
    let apiKeyIcon = UIImageView(
      image: UIImage(systemName: "key.fill")?.withTintColor(
        .quaternaryText, renderingMode: .alwaysOriginal))
    apiKeyIcon.contentMode = .scaleAspectFit
    apiKeyIcon.transform = CGAffineTransform(rotationAngle: .pi / 4)
    view.addSubview(accountIDIcon)
    view.addSubview(apiKeyIcon)
    view.addSubview(accountIDTitleLabel)
    view.addSubview(accountIDLabel)
    view.addSubview(accountIDCopiedLabel)
    view.addSubview(apiKeyTitleLabel)
    view.addSubview(apiKeyLabel)
    view.addSubview(apiKeyCopiedLabel)
    view.addSubview(eyeButton)
    accountIDIcon.snp.makeConstraints { make in
      make.leading.equalToSuperview().inset(16)
      make.centerY.equalTo(accountIDTitleLabel)
      make.size.equalTo(16)
    }
    accountIDTitleLabel.snp.makeConstraints { make in
      make.top.equalToSuperview().inset(16)
      make.leading.equalTo(accountIDIcon.snp.trailing).offset(4)
      make.trailing.lessThanOrEqualTo(accountIDCopiedLabel.snp.leading).offset(-8)
    }
    accountIDCopiedLabel.snp.makeConstraints { make in
      make.trailing.equalToSuperview().inset(16)
      make.firstBaseline.equalTo(accountIDTitleLabel)
    }
    accountIDLabel.snp.makeConstraints { make in
      make.top.equalTo(accountIDTitleLabel.snp.bottom).offset(4)
      make.leading.trailing.equalToSuperview().inset(16)
    }
    apiKeyIcon.snp.makeConstraints { make in
      make.leading.equalTo(accountIDIcon)
      make.centerY.equalTo(apiKeyTitleLabel)
      make.size.equalTo(16)
    }
    apiKeyTitleLabel.snp.makeConstraints { make in
      make.top.equalTo(accountIDLabel.snp.bottom).offset(12)
      make.leading.equalTo(accountIDTitleLabel)
      make.trailing.lessThanOrEqualTo(apiKeyCopiedLabel.snp.leading).offset(-8)
    }
    apiKeyCopiedLabel.snp.makeConstraints { make in
      make.trailing.equalToSuperview().inset(16)
      make.firstBaseline.equalTo(apiKeyTitleLabel)
    }
    eyeButton.snp.makeConstraints { make in
      make.trailing.equalToSuperview().inset(16)
      make.top.equalTo(apiKeyTitleLabel.snp.bottom).offset(1)
      make.width.equalTo(30)
      make.height.greaterThanOrEqualTo(30)
      make.bottom.equalToSuperview().inset(12)
    }
    apiKeyLabel.snp.makeConstraints { make in
      make.leading.equalTo(accountIDLabel)
      make.trailing.equalTo(eyeButton.snp.leading).offset(-8)
      make.centerY.equalTo(eyeButton)
      make.height.greaterThanOrEqualTo(24)
      make.top.greaterThanOrEqualTo(apiKeyTitleLabel.snp.bottom).offset(4)
      make.bottom.lessThanOrEqualToSuperview().inset(12)
    }
    let divider = SettingsViewFactory.makeDividerView()
    view.addSubview(divider)
    divider.snp.makeConstraints { make in
      make.height.equalTo(0.5)
      make.leading.trailing.bottom.equalToSuperview()
    }
    return view
  }()

  private lazy var errorLabel: UILabel = {
    let label = UILabel()
    label.textColor = .systemRed
    label.numberOfLines = 0
    FontMetrics.default.scaleFont(.systemFont(ofSize: 11), bindTo: label)
    return label
  }()

  private lazy var errorView: UIView = {
    let view = UIView()
    view.addSubview(errorLabel)
    errorLabel.snp.makeConstraints { make in
      make.edges.equalToSuperview().inset(12)
    }
    return view
  }()

  private lazy var signOutButton: UIButton = {
    let button = UIButton(type: .custom)
    var configuration = UIButton.Configuration.plain()
    configuration.title = LocalizedString.forKey("sign_out")
    configuration.baseBackgroundColor = .clear
    configuration.baseForegroundColor = .secondaryText
    configuration.image = UIImage(imageLiteralResourceName: "door-open-24").withTintColor(
      .secondaryText)
    configuration.imagePadding = 8
    configuration.contentInsets = .init(top: 10, leading: 16, bottom: 10, trailing: 16)
    button.configuration = configuration
    button.contentHorizontalAlignment = .leading
    FontMetrics.default.scaleFont(.systemFont(ofSize: 16), bindTo: button)
    button.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        delegate?.accountViewControllerDidRequestSignOut(self)
      }, for: .touchUpInside)
    return button
  }()

  private lazy var deleteAccountButton: UIButton = {
    let button = UIButton(type: .custom)
    var configuration = UIButton.Configuration.plain()
    configuration.title = LocalizedString.forKey("delete_account")
    configuration.baseBackgroundColor = .clear
    configuration.baseForegroundColor = .secondaryText
    configuration.image = UIImage(imageLiteralResourceName: "trash-24").withTintColor(
      .secondaryText)
    configuration.imagePadding = 8
    configuration.contentInsets = .init(top: 10, leading: 16, bottom: 10, trailing: 16)
    button.configuration = configuration
    button.contentHorizontalAlignment = .leading
    FontMetrics.default.scaleFont(.systemFont(ofSize: 16), bindTo: button)
    button.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        delegate?.accountViewControllerDidRequestDeleteAccount(self)
      }, for: .touchUpInside)
    return button
  }()

  private lazy var deleteAccountView: UIView = {
    let view = UIView()
    let divider = SettingsViewFactory.makeDividerView()
    view.addSubview(divider)
    divider.snp.makeConstraints { make in
      make.height.equalTo(0.5)
      make.leading.trailing.equalToSuperview()
      make.bottom.equalToSuperview({ $0.snp.top })
    }
    view.addSubview(deleteAccountButton)
    deleteAccountButton.snp.makeConstraints { make in
      make.edges.equalToSuperview()
      make.height.greaterThanOrEqualTo(44)
    }
    return view
  }()

  private lazy var signOutView: UIView = {
    let view = UIView()
    let divider = SettingsViewFactory.makeDividerView()
    view.addSubview(divider)
    divider.snp.makeConstraints { make in
      make.height.equalTo(0.5)
      make.leading.trailing.equalToSuperview()
      make.bottom.equalToSuperview({ $0.snp.top })
    }
    view.addSubview(signOutButton)
    signOutButton.snp.makeConstraints { make in
      make.edges.equalToSuperview()
      make.height.greaterThanOrEqualTo(44)
    }
    return view
  }()

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear
    view.layer.shadowColor = UIColor.black.cgColor
    view.layer.shadowOpacity = 0.2
    view.layer.shadowRadius = 32
    let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
    view.addSubview(blurView)
    blurView.snp.makeConstraints { make in
      make.edges.equalToSuperview()
    }
    blurView.layer.cornerRadius = 12
    blurView.clipsToBounds = true
    blurView.contentView.backgroundColor = .secondaryBackground.withAlphaComponent(0.8)
    view.addSubview(stackView)
    stackView.snp.makeConstraints { make in
      make.top.equalToSuperview()
      make.leading.trailing.equalToSuperview()
      make.bottom.lessThanOrEqualToSuperview()
    }
    [
      headerView, signInView, busyView, credentialsView, balanceView, errorView,
      deleteAccountView, signOutView,
    ].forEach(stackView.addArrangedSubview)
    accountIDLabel.isUserInteractionEnabled = true
    accountIDLabel.addGestureRecognizer(
      UITapGestureRecognizer(target: self, action: #selector(copyAccountID)))
    accountIDLabel.accessibilityCustomActions = [
      UIAccessibilityCustomAction(
        name: LocalizedString.forKey("copy"), target: self, selector: #selector(copyAccountID))
    ]
    apiKeyLabel.addGestureRecognizer(
      UITapGestureRecognizer(target: self, action: #selector(copyAPIKey)))
    apiKeyLabel.accessibilityCustomActions = [
      UIAccessibilityCustomAction(
        name: LocalizedString.forKey("copy"), target: self, selector: #selector(copyAPIKey))
    ]
    render()
  }

  @objc private func copyAccountID() -> Bool {
    guard case .signedIn(_, let accountID?, _, _) = state, !accountID.isEmpty else {
      return false
    }
    delegate?.accountViewController(self, didRequestCopy: accountID)
    showCopyConfirmation(accountIDCopiedLabel)
    return true
  }

  @objc private func copyAPIKey() -> Bool {
    guard case .signedIn(_, _, let apiKey?, _) = state, !apiKey.isEmpty else { return false }
    delegate?.accountViewController(self, didRequestCopy: apiKey)
    showCopyConfirmation(apiKeyCopiedLabel)
    return true
  }

  private func showCopyConfirmation(_ label: UILabel) {
    copyResetTimer?.invalidate()
    UIView.animate(
      withDuration: 0.2, delay: 0,
      options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction]
    ) {
      self.accountIDCopiedLabel.alpha = label === self.accountIDCopiedLabel ? 1 : 0
      self.apiKeyCopiedLabel.alpha = label === self.apiKeyCopiedLabel ? 1 : 0
    }
    copyResetTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak label] _ in
      UIView.animate(
        withDuration: 0.2, delay: 0,
        options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction]
      ) {
        label?.alpha = 0
      }
    }
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    copyResetTimer?.invalidate()
    copyResetTimer = nil
    accountIDCopiedLabel.layer.removeAllAnimations()
    apiKeyCopiedLabel.layer.removeAllAnimations()
    accountIDCopiedLabel.alpha = 0
    apiKeyCopiedLabel.alpha = 0
    isAPIKeyVisible = false
    updateAPIKeyPresentation()
  }

  private func render() {
    copyResetTimer?.invalidate()
    copyResetTimer = nil
    accountIDCopiedLabel.layer.removeAllAnimations()
    apiKeyCopiedLabel.layer.removeAllAnimations()
    accountIDCopiedLabel.alpha = 0
    apiKeyCopiedLabel.alpha = 0
    signInView.isHidden = true
    busyView.isHidden = true
    balanceView.isHidden = true
    credentialsView.isHidden = true
    errorView.isHidden = true
    deleteAccountView.isHidden = true
    signOutView.isHidden = true
    activityIndicator.stopAnimating()
    displayedAPIKey = nil
    switch state {
    case .signedOut(let error):
      signInView.isHidden = false
      errorLabel.text = error
      errorView.isHidden = error == nil
    case .busy(let message):
      busyLabel.text = message
      busyView.isHidden = false
      activityIndicator.startAnimating()
    case .signedIn(let snapshot, let accountID, let apiKey, let error):
      balanceView.balance =
        snapshot.map { Self.credit($0.balanceMicroUsd) }
        ?? LocalizedString.forKey("credit_unavailable")
      accountIDLabel.text = accountID ?? "—"
      displayedAPIKey = apiKey
      balanceView.isHidden = false
      credentialsView.isHidden = false
      errorLabel.text = error
      errorView.isHidden = error == nil
      deleteAccountView.isHidden = false
      signOutView.isHidden = false
    }
    updateAPIKeyPresentation()
    view.layoutIfNeeded()
    let size = stackView.systemLayoutSizeFitting(
      CGSize(width: preferredContentSize.width, height: UIView.layoutFittingCompressedSize.height),
      withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
    let height = ceil(size.height)
    guard preferredContentSize.height != height else { return }
    preferredContentSize.height = height
  }

  private func updateAPIKeyPresentation() {
    let hasAPIKey = displayedAPIKey?.isEmpty == false
    eyeButton.isEnabled = hasAPIKey
    eyeButton.isSelected = hasAPIKey && isAPIKeyVisible
    eyeButton.accessibilityLabel = LocalizedString.forKey(
      isAPIKeyVisible ? "hide_api_key" : "show_api_key")
    if hasAPIKey && isAPIKeyVisible {
      apiKeyLabel.text = displayedAPIKey
    } else if hasAPIKey {
      apiKeyLabel.text = "••••••••••••••••••••"
    } else {
      apiKeyLabel.text = LocalizedString.forKey("remote_api_not_configured")
    }
  }

  static func credit(_ microUsd: Int64) -> String {
    let dollars = Decimal(microUsd) / Decimal(1_000_000)
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = "USD"
    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = 6
    return formatter.string(from: dollars as NSDecimalNumber) ?? "\(microUsd) µUSD"
  }
}
