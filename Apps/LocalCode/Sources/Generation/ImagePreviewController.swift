import Components
import Localization
import SnapKit
import Style
import UIKit

final class ImagePreviewController {
  struct ViewModel {
    var images: [UIImage] = []
    var title: String
    var prompt: String
    var progress: LabeledProgressBarController.ViewModel
  }

  var view: UIView { bannerController.view }
  let bannerController: ChatBannerController
  var didTapClose: (() -> Void)?
  private let progressBarController: LabeledProgressBarController
  private var frameIndex = 0
  private var animationBlock: DispatchWorkItem?

  var viewModel: ViewModel {
    didSet {
      if !oldValue.images.elementsEqual(viewModel.images, by: { $0 === $1 }) {
        if !viewModel.images.isEmpty {
          let image = viewModel.images[frameIndex % viewModel.images.count]
          backgroundImageView.image = image
          imageView.image = image
        } else {
          backgroundImageView.image = nil
          imageView.image = nil
        }
        shimmerView.isHidden = !viewModel.images.isEmpty
        if viewModel.images.count <= 1 {
          stopAnimatingPreview()
        }
        animatePreview()
      }
      if oldValue.title != viewModel.title {
        titleLabel.text = viewModel.title
      }
      if oldValue.prompt != viewModel.prompt {
        subtitleLabel.text = viewModel.prompt
      }
      progressBarController.viewModel = viewModel.progress
    }
  }

  private lazy var backgroundImageView: UIImageView = {
    let imageView = UIImageView(image: viewModel.images.first)
    imageView.contentMode = .scaleAspectFill
    imageView.clipsToBounds = true
    return imageView
  }()

  private lazy var imageView: UIImageView = {
    let imageView = UIImageView(image: viewModel.images.first)
    imageView.contentMode = .scaleAspectFit
    return imageView
  }()

  private lazy var shimmerView: OrganicShimmerView = {
    let view = OrganicShimmerView(frame: .zero)
    view.isHidden = !viewModel.images.isEmpty
    return view
  }()

  private lazy var previewView: View = {
    let view = View(frame: .zero)
    view.backgroundColor = .quinaryBackground
    view.layer.cornerRadius = 16
    view.clipsToBounds = true
    let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
    view.addSubview(backgroundImageView)
    view.addSubview(blurView)
    view.addSubview(shimmerView)
    view.addSubview(imageView)
    backgroundImageView.snp.makeConstraints { make in
      make.edges.equalToSuperview()
    }
    blurView.snp.makeConstraints { make in
      make.edges.equalToSuperview()
    }
    shimmerView.snp.makeConstraints { make in
      make.edges.equalToSuperview()
    }
    imageView.snp.makeConstraints { make in
      make.edges.equalToSuperview()
    }
    return view
  }()

  private lazy var titleLabel: UILabel = {
    let label = UILabel(frame: .zero)
    label.text = viewModel.title
    label.textColor = .primaryText
    label.lineBreakMode = .byTruncatingTail
    FontMetrics.default.scaleFont(.systemFont(ofSize: 14, weight: .medium), bindTo: label)
    return label
  }()

  private lazy var subtitleLabel: UILabel = {
    let label = UILabel(frame: .zero)
    label.text = viewModel.prompt
    label.textColor = .septenaryText
    label.numberOfLines = 0
    label.lineBreakMode = .byTruncatingTail
    label.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    FontMetrics.default.scaleFont(.systemFont(ofSize: 11, weight: .light), bindTo: label)
    return label
  }()

  private lazy var detailsStackView: UIStackView = {
    let stackView = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
    stackView.axis = .vertical
    stackView.spacing = 4
    return stackView
  }()

  private lazy var closeButton: UIButton = {
    let button = UIButton(type: .custom)
    var configuration = UIButton.Configuration.plain()
    configuration.baseForegroundColor = .senaryText
    configuration.image = #imageLiteral(resourceName: "new-x").withRenderingMode(.alwaysTemplate)
    configuration.contentInsets = .zero
    button.configuration = configuration
    button.accessibilityLabel = LocalizedString.forKey("cancel")
    return button
  }()

  init(viewModel: ViewModel) {
    self.viewModel = viewModel
    progressBarController = LabeledProgressBarController(
      viewModel: viewModel.progress, fullyRoundedProgressBar: true)
    let cardView = BorderView.defaultBorderView(cornerRadius: 32)
    cardView.backgroundColor = .tertiaryBackground
    cardView.clipsToBounds = true
    bannerController = ChatBannerController(contentView: cardView)

    previewView.controller = self
    cardView.addSubview(previewView)
    cardView.addSubview(detailsStackView)
    cardView.addSubview(progressBarController.view)
    cardView.addSubview(closeButton)
    previewView.snp.makeConstraints { make in
      make.leading.top.bottom.equalToSuperview().inset(16)
      make.size.equalTo(120)
    }
    closeButton.snp.makeConstraints { make in
      make.top.trailing.equalToSuperview().inset(16)
      make.size.equalTo(32)
    }
    progressBarController.view.snp.makeConstraints { make in
      make.leading.equalTo(previewView.snp.trailing).offset(12)
      make.trailing.bottom.equalToSuperview().inset(16)
      make.height.equalTo(32)
    }
    detailsStackView.snp.makeConstraints { make in
      make.top.equalTo(previewView).offset(4)
      make.leading.equalTo(previewView.snp.trailing).offset(24)
      make.trailing.equalTo(closeButton.snp.leading).offset(-12)
      make.bottom.lessThanOrEqualTo(progressBarController.view.snp.top).offset(-6)
    }

    closeButton.addAction(
      UIAction { [weak self] _ in self?.didTapClose?() }, for: .touchUpInside)
    animatePreview()
  }

  deinit {
    animationBlock?.cancel()
  }

  private func animatePreview() {
    shimmerView.isShimmering = viewModel.images.isEmpty
    guard animationBlock == nil, viewModel.images.count > 1 else { return }
    let animationBlock = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.animationBlock = nil
      guard self.previewView.window != nil, self.viewModel.images.count > 1 else { return }
      self.frameIndex += 1
      let image = self.viewModel.images[self.frameIndex % self.viewModel.images.count]
      self.backgroundImageView.image = image
      self.imageView.image = image
      self.animatePreview()
    }
    self.animationBlock = animationBlock
    // Match Draw Things' live preview cadence for video frames and image batches.
    DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(1), execute: animationBlock)
  }

  func stopAnimatingPreview() {
    shimmerView.isShimmering = false
    animationBlock?.cancel()
    animationBlock = nil
  }

  /// Frames advance only while the card is in a window, as the shimmer does. Switching chats
  /// detaches the card.
  private func didMoveToWindow() {
    if previewView.window != nil {
      animatePreview()
    } else {
      animationBlock?.cancel()
      animationBlock = nil
    }
  }

  private final class View: UIView {
    weak var controller: ImagePreviewController?

    override func didMoveToWindow() {
      super.didMoveToWindow()
      controller?.didMoveToWindow()
    }
  }
}
