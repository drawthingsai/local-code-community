import Components
import Localization
import SnapKit
import Style
import UIKit

protocol TopUpViewControllerDelegate: AnyObject {
  func topUpViewControllerDidClose(_ viewController: TopUpViewController)
  func topUpViewControllerDidContinueGeneration(
    _ viewController: TopUpViewController)
  func topUpViewController(
    _ viewController: TopUpViewController, didChangeConsent hasConsent: Bool)
  func topUpViewController(
    _ viewController: TopUpViewController, didRequestPurchase productID: String,
    hasConsent: Bool)
}

final class TopUpViewController: UIViewController {
  struct Product {
    let id: String
    let amount: String
    let displayPrice: String?
  }

  weak var delegate: TopUpViewControllerDelegate?

  var balance: String {
    didSet { balanceLabel.text = LocalizedString.format(key: "top_up_balance", balance) }
  }
  private let products: [Product]
  private var hasConsent: Bool
  private let showsContinueGeneration: Bool
  var canContinueGeneration = false {
    didSet {
      guard isViewLoaded else { return }
      updatePurchaseStatus()
    }
  }

  enum PurchaseStatus {
    case ready
    case purchasing(String)
    case pending
    case succeeded(String)
    case error(String)
    #if DIRECT_DISTRIBUTION
      case completeOnStripe
    #endif
  }
  var purchaseStatus: PurchaseStatus = .ready {
    didSet {
      guard isViewLoaded else { return }
      updatePurchaseStatus()
    }
  }

  init(
    balance: String, products: [Product], hasConsent: Bool, showsContinueGeneration: Bool = false
  ) {
    self.balance = balance
    self.products = products
    self.hasConsent = hasConsent
    self.showsContinueGeneration = showsContinueGeneration
    super.init(nibName: nil, bundle: nil)
    preferredContentSize = CGSize(width: 430, height: 500)
  }

  required init?(coder: NSCoder) {
    fatalError()
  }

  private lazy var closeButton: UIButton = {
    let button = UIButton(type: .custom)
    var configuration = UIButton.Configuration.filled()
    configuration.cornerStyle = .capsule
    configuration.background.backgroundColor = .clear
    configuration.baseForegroundColor = .senaryText
    configuration.image = #imageLiteral(resourceName: "close-16").withRenderingMode(
      .alwaysTemplate)
    configuration.contentInsets = .zero
    button.configuration = configuration
    button.configurationUpdateHandler = {
      guard var configuration = $0.configuration else { return }
      configuration.background.backgroundColor =
        $0.isHighlighted || $0.state.contains(.focused) ? .quinaryBackground : .clear
      $0.configuration = configuration
    }
    button.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        delegate?.topUpViewControllerDidClose(self)
      }, for: .touchUpInside)
    return button
  }()

  private lazy var titleLabel: UILabel = {
    let label = UILabel()
    label.text = LocalizedString.forKey("top_up")
    label.textColor = .primaryText
    FontMetrics.default.scaleFont(.systemFont(ofSize: 15, weight: .medium), bindTo: label)
    return label
  }()

  private lazy var subtitleLabel: UILabel = {
    let label = UILabel()
    label.text = LocalizedString.forKey("top_up_description")
    label.textColor = .tertiaryText
    label.numberOfLines = 0
    FontMetrics.default.scaleFont(.systemFont(ofSize: 14, weight: .light), bindTo: label)
    return label
  }()

  private lazy var consentCheckView = UIImageView()
  private lazy var scrollView = UIScrollView()

  private lazy var consentView: UIView = {
    let view = BorderView.defaultBorderView()
    view.layer.cornerRadius = 16
    view.backgroundColor = .tertiaryBackground
    let label = UILabel()
    label.textColor = .tertiaryText
    label.numberOfLines = 0
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.minimumLineHeight = 20
    label.attributedText = NSAttributedString(
      string: LocalizedString.forKey("consumption_request_consent"),
      attributes: [
        .font: UIFont.systemFont(ofSize: 14, weight: .light),
        .paragraphStyle: paragraphStyle,
      ])
    updateConsentCheck()
    view.addSubview(consentCheckView)
    view.addSubview(label)
    consentCheckView.snp.makeConstraints { make in
      make.leading.equalToSuperview().inset(20)
      make.top.equalTo(label)
      make.bottom.lessThanOrEqualToSuperview().inset(16)
      make.size.equalTo(24)
    }
    label.snp.makeConstraints { make in
      make.leading.equalToSuperview().inset(52)
      make.trailing.equalToSuperview().inset(12)
      make.top.bottom.equalToSuperview().inset(16)
    }
    let button = UIButton()
    button.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        hasConsent.toggle()
        updateConsentCheck()
        delegate?.topUpViewController(self, didChangeConsent: hasConsent)
      }, for: .touchUpInside)
    view.addSubview(button)
    button.snp.makeConstraints { make in
      make.edges.equalToSuperview()
    }
    return view
  }()

  private lazy var cashIconView: UIView = {
    let view = BorderView.defaultBorderView()
    view.backgroundColor = .quaternaryBackground
    view.layer.cornerRadius = 12
    let imageView = UIImageView(image: UIImage(imageLiteralResourceName: "cash-24"))
    view.addSubview(imageView)
    imageView.snp.makeConstraints { make in
      make.center.equalToSuperview()
    }
    return view
  }()

  private lazy var balanceLabel: UILabel = {
    let label = UILabel()
    label.text = LocalizedString.format(key: "top_up_balance", balance)
    label.textColor = .secondaryText
    label.numberOfLines = 0
    FontMetrics.default.scaleFont(.systemFont(ofSize: 18, weight: .medium), bindTo: label)
    return label
  }()

  private lazy var descriptionLabel: UILabel = {
    let label = UILabel()
    label.text = LocalizedString.forKey("cash_description")
    label.textColor = .tertiaryText
    label.numberOfLines = 0
    FontMetrics.default.scaleFont(.systemFont(ofSize: 11), bindTo: label)
    return label
  }()

  private lazy var statusLabel: UILabel = {
    let label = UILabel()
    label.text = LocalizedString.forKey("add_more_funds")
    label.textColor = .secondaryText
    label.numberOfLines = 0
    FontMetrics.default.scaleFont(.systemFont(ofSize: 14), bindTo: label)
    return label
  }()

  private lazy var productStackView: UIStackView = {
    let stackView = UIStackView()
    stackView.axis = .horizontal
    stackView.alignment = .fill
    stackView.distribution = .fillEqually
    stackView.spacing = 8
    for product in products {
      let button = UIButton(type: .custom)
      var configuration = UIButton.Configuration.filled()
      configuration.title = product.amount
      if let displayPrice = product.displayPrice, displayPrice != product.amount {
        configuration.subtitle = displayPrice
        configuration.titlePadding = 0
      }
      configuration.titleAlignment = .center
      configuration.background.cornerRadius = 8
      configuration.background.backgroundColor = .tertiaryFill
      configuration.background.strokeColor = .primaryBorder
      configuration.background.strokeWidth = 1
      configuration.baseForegroundColor = .tertiaryText
      configuration.contentInsets = .init(top: 4, leading: 8, bottom: 4, trailing: 8)
      button.configuration = configuration
      FontMetrics.default.scaleFont(.systemFont(ofSize: 14, weight: .medium), bindTo: button)
      button.addAction(
        UIAction { [weak self] _ in
          guard let self else { return }
          delegate?.topUpViewController(
            self, didRequestPurchase: product.id, hasConsent: hasConsent)
        }, for: .touchUpInside)
      stackView.addArrangedSubview(button)
    }
    return stackView
  }()

  private lazy var walletView: UIView = {
    let view = BorderView.defaultBorderView()
    view.layer.cornerRadius = 16
    view.backgroundColor = .tertiaryBackground
    view.addSubview(cashIconView)
    view.addSubview(balanceLabel)
    view.addSubview(descriptionLabel)
    view.addSubview(statusLabel)
    let purchaseStack = UIStackView(arrangedSubviews: [productStackView, purchaseStatusView])
    purchaseStack.axis = .vertical
    purchaseStack.spacing = 8
    view.addSubview(purchaseStack)
    cashIconView.snp.makeConstraints { make in
      make.leading.top.equalToSuperview().inset(24)
      make.size.equalTo(48)
    }
    balanceLabel.snp.makeConstraints { make in
      make.leading.equalTo(cashIconView.snp.trailing).offset(12)
      make.trailing.equalToSuperview().inset(20)
      make.top.equalTo(cashIconView).offset(2)
    }
    descriptionLabel.snp.makeConstraints { make in
      make.leading.equalTo(balanceLabel)
      make.trailing.equalToSuperview().inset(20)
      make.top.equalTo(balanceLabel.snp.bottom)
    }
    statusLabel.snp.makeConstraints { make in
      make.leading.equalTo(cashIconView)
      make.trailing.equalToSuperview().inset(24)
      make.top.equalTo(descriptionLabel.snp.bottom).offset(20)
      make.top.greaterThanOrEqualTo(cashIconView.snp.bottom).offset(20)
    }
    purchaseStack.snp.makeConstraints { make in
      make.top.equalTo(statusLabel.snp.bottom).offset(8)
      make.leading.trailing.bottom.equalToSuperview().inset(12)
    }
    productStackView.snp.makeConstraints { make in
      make.height.greaterThanOrEqualTo(40)
    }
    return view
  }()

  private lazy var purchaseStatusLabel: UILabel = {
    let label = UILabel()
    label.textColor = .septenaryText
    label.numberOfLines = 0
    label.textAlignment = .left
    FontMetrics.default.scaleFont(.systemFont(ofSize: 12, weight: .medium), bindTo: label)
    return label
  }()

  private lazy var purchaseStatusIconView = UIImageView()

  private lazy var purchaseStatusIndicator: UIActivityIndicatorView = {
    let indicator = UIActivityIndicatorView(style: .medium)
    indicator.color = .septenaryText
    indicator.hidesWhenStopped = true
    return indicator
  }()

  private lazy var purchaseStatusView: BorderView = {
    let view = BorderView.defaultBorderView()
    view.layer.cornerRadius = 8
    view.backgroundColor = .duodenaryFill
    view.borderColor = .primaryBorder
    view.isHidden = true
    view.addSubview(purchaseStatusIconView)
    view.addSubview(purchaseStatusIndicator)
    view.addSubview(purchaseStatusLabel)
    purchaseStatusIconView.snp.makeConstraints { make in
      make.leading.equalToSuperview().inset(8)
      make.centerY.equalToSuperview()
      make.size.equalTo(24)
    }
    purchaseStatusIndicator.snp.makeConstraints { make in
      make.leading.equalToSuperview().inset(8)
      make.centerY.equalToSuperview()
    }
    purchaseStatusLabel.snp.makeConstraints { make in
      make.leading.equalTo(purchaseStatusIconView.snp.trailing).offset(4)
      make.trailing.equalToSuperview().inset(8)
      make.top.bottom.equalToSuperview().inset(4)
    }
    return view
  }()

  private lazy var doneButton: UIButton = {
    let button = UIButton(type: .custom)
    var configuration = UIButton.Configuration.filled()
    configuration.title = LocalizedString.forKey(showsContinueGeneration ? "cancel" : "done")
    configuration.titleAlignment = .center
    configuration.background.cornerRadius = 8
    configuration.background.backgroundColor = showsContinueGeneration ? .nonaryFill : .primaryFill
    configuration.baseForegroundColor = showsContinueGeneration ? .octonaryText : .nonaryText
    if showsContinueGeneration {
      configuration.background.strokeWidth = 1
      configuration.background.strokeColor = .primaryBorder
    }
    configuration.contentInsets = .init(top: 8, leading: 16, bottom: 8, trailing: 16)
    button.configuration = configuration
    FontMetrics.default.scaleFont(.systemFont(ofSize: 14, weight: .medium), bindTo: button)
    button.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        delegate?.topUpViewControllerDidClose(self)
      }, for: .touchUpInside)
    return button
  }()

  private lazy var continueGenerationButton: UIButton = {
    let button = UIButton(type: .custom)
    var configuration = UIButton.Configuration.filled()
    configuration.title = LocalizedString.forKey("continue")
    configuration.background.backgroundColor = .primaryFill
    configuration.baseForegroundColor = .nonaryText
    configuration.background.cornerRadius = 8
    configuration.contentInsets = .init(top: 8, leading: 16, bottom: 8, trailing: 16)
    button.configuration = configuration
    button.titleLabel?.numberOfLines = 0
    FontMetrics.default.scaleFont(.systemFont(ofSize: 14, weight: .medium), bindTo: button)
    button.isHidden = !showsContinueGeneration
    button.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        delegate?.topUpViewControllerDidContinueGeneration(self)
      }, for: .touchUpInside)
    return button
  }()

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .secondaryBackground
    view.addSubview(closeButton)
    view.addSubview(titleLabel)
    let titleDivider = SettingsViewFactory.makeDividerView()
    view.addSubview(titleDivider)
    view.addSubview(scrollView)
    #if DIRECT_DISTRIBUTION
      // The consent covers App Store consumption requests, which Stripe purchases don't have.
      let contentStack = UIStackView(arrangedSubviews: [subtitleLabel, walletView])
    #else
      let contentStack = UIStackView(arrangedSubviews: [subtitleLabel, consentView, walletView])
    #endif
    contentStack.axis = .vertical
    contentStack.spacing = 16
    scrollView.addSubview(contentStack)
    let bottomDivider = SettingsViewFactory.makeDividerView()
    bottomDivider.backgroundColor = .primaryBorder
    view.addSubview(bottomDivider)
    let buttonStack = UIStackView(arrangedSubviews: [doneButton, continueGenerationButton])
    buttonStack.axis = .horizontal
    buttonStack.spacing = 12
    buttonStack.alignment = .fill
    view.addSubview(buttonStack)

    closeButton.snp.makeConstraints { make in
      make.top.equalTo(view.snp.topMargin).offset(10)
      make.trailing.equalToSuperview().inset(14)
      make.size.equalTo(32)
    }
    titleLabel.snp.makeConstraints { make in
      make.leading.equalToSuperview().inset(24)
      make.centerY.equalTo(closeButton)
    }
    titleDivider.snp.makeConstraints { make in
      make.top.equalToSuperview().offset(52)
      make.leading.trailing.equalToSuperview()
      make.height.equalTo(1)
    }
    scrollView.snp.makeConstraints { make in
      make.top.equalTo(titleDivider.snp.bottom)
      make.leading.trailing.equalToSuperview()
      make.bottom.equalTo(bottomDivider.snp.top)
    }
    contentStack.snp.makeConstraints { make in
      make.top.equalTo(scrollView.contentLayoutGuide).offset(20)
      make.bottom.equalTo(scrollView.contentLayoutGuide).inset(16)
      make.leading.trailing.equalTo(scrollView.contentLayoutGuide).inset(24)
      make.width.equalTo(scrollView.frameLayoutGuide).offset(-48)
    }
    bottomDivider.snp.makeConstraints { make in
      make.leading.trailing.equalToSuperview()
      make.bottom.equalTo(buttonStack.snp.top).offset(-16)
      make.height.equalTo(1)
    }
    buttonStack.snp.makeConstraints { make in
      make.leading.greaterThanOrEqualToSuperview().inset(16)
      make.trailing.equalToSuperview().inset(16)
      make.bottom.equalTo(view.safeAreaLayoutGuide).inset(16)
      make.height.greaterThanOrEqualTo(40)
    }
    updatePurchaseStatus()
  }

  private func updatePurchaseStatus() {
    var message: String?
    var isBusy = false
    var isSuccess = false
    var isError = false
    var iconName: String?
    switch purchaseStatus {
    case .ready: break
    case .purchasing(let productID):
      let amount =
        products.first(where: { $0.id == productID })?.amount ?? LocalizedString.forKey("credit")
      message = LocalizedString.format(key: "adding_x_to_balance", amount)
      isBusy = true
    case .pending:
      message = LocalizedString.forKey("purchase_pending_approval")
      iconName = "credit-card-filled-24"
    case .succeeded(let productID):
      let amount =
        products.first(where: { $0.id == productID })?.amount ?? LocalizedString.forKey("credit")
      message = LocalizedString.format(key: "purchase_success_message", amount)
      isSuccess = true
      iconName = "check-circle-filled-24"
    case .error(let error):
      message = error
      isError = true
      iconName = "warning-filled-24"
    #if DIRECT_DISTRIBUTION
      case .completeOnStripe:
        message = LocalizedString.forKey("complete_purchase_on_stripe")
        iconName = "credit-card-filled-24"
    #endif
    }
    purchaseStatusLabel.text = message
    let statusColor: UIColor =
      isError
      ? .shadePalette(for: .red)
      : isSuccess ? .shadePalette(for: .green) : .septenaryText
    purchaseStatusLabel.textColor = statusColor
    purchaseStatusView.backgroundColor =
      isError
      ? .overlayPalette(for: .red)
      : isSuccess ? .overlayPalette(for: .green) : .duodenaryFill
    purchaseStatusView.borderColor =
      isError
      ? .tintPalette(for: .red)
      : isSuccess ? .tintPalette(for: .green) : .primaryBorder
    purchaseStatusIconView.image = iconName.map {
      UIImage(imageLiteralResourceName: $0).withTintColor(statusColor)
    }
    purchaseStatusIconView.isHidden = isBusy || iconName == nil
    if isBusy {
      purchaseStatusIndicator.startAnimating()
    } else {
      purchaseStatusIndicator.stopAnimating()
    }
    purchaseStatusView.isHidden = message == nil
    productStackView.isUserInteractionEnabled = !isBusy
    productStackView.alpha = isBusy ? 0.5 : 1
    continueGenerationButton.isEnabled = canContinueGeneration && !isBusy
  }

  private func updateConsentCheck() {
    consentCheckView.image =
      hasConsent
      ? UIImage(imageLiteralResourceName: "check-circle-filled-24").withTintColor(.primaryText)
      : UIImage(imageLiteralResourceName: "circle-24")
  }
}
