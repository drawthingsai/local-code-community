import Advance
import Components
import Localization
import SnapKit
import Style
import UIKit

protocol EmbeddedDownloadControllerDelegate: AnyObject {
  func didTapCloseDownload()
  func didTapRetryDownload()
}

final class EmbeddedDownloadController {
  struct DownloadItem {
    let name: String
    let subtitle: String
    let file: String
    let sha256: String?
    let huggingFaceLink: String?

    init(
      name: String, subtitle: String, file: String, sha256: String?,
      huggingFaceLink: String? = nil
    ) {
      self.name = name
      self.subtitle = subtitle
      self.file = file
      self.sha256 = sha256
      self.huggingFaceLink = huggingFaceLink
    }
  }

  var view: UIView { bannerController.view }
  let bannerController: ChatBannerController
  weak var delegate: EmbeddedDownloadControllerDelegate?
  var isVisible: Bool { bannerController.isVisible }
  private let downloadItemController: DownloadItemController
  private var monkeyAnimationController: MonkeyAnimationController?
  private var finishCompletion: (() -> Void)?
  private(set) var displayedProgress: Double = 0
  private lazy var progressAnimator = Animator(initialValue: displayedProgress)

  var viewModel: DownloadItemController.ViewModel {
    didSet {
      retryButton.isHidden = viewModel.mode != .error
      setDisplayedProgress(displayedProgress)
      if monkeyAnimationController?.isRunning != true {
        progressAnimator.animate(to: realProgress, duration: 0.1, timingFunction: .linear)
      }
    }
  }

  var realProgress: Double {
    let progress =
      viewModel.progress
      ?? (viewModel.totalBytes > 0
        ? Double(viewModel.finishedBytes) / Double(viewModel.totalBytes) : 0)
    return progress.isFinite ? min(1, max(0, progress)) : 0
  }

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

  private lazy var retryButton: UIButton = {
    let button = UIButton(type: .custom)
    var configuration = UIButton.Configuration.plain()
    configuration.baseForegroundColor = .senaryText
    configuration.image = UIImage(systemName: "arrow.clockwise")
    configuration.contentInsets = .zero
    button.configuration = configuration
    button.accessibilityLabel = LocalizedString.forKey("restart_download")
    return button
  }()

  init(viewModel: DownloadItemController.ViewModel) {
    self.viewModel = viewModel
    downloadItemController = DownloadItemController(
      viewModel: viewModel, headerTrailingInset: 92, contentInset: 28, progressBarInset: 16,
      fullyRoundedProgressBar: true, usesAnimation: false)
    let cardView = downloadItemController.view
    cardView.layer.cornerRadius = 32
    bannerController = ChatBannerController(contentView: cardView)
    displayedProgress = realProgress
    monkeyAnimationController = MonkeyAnimationController(downloadController: self)
    if let monkeyView = monkeyAnimationController?.view {
      cardView.addSubview(monkeyView)
      monkeyView.snp.makeConstraints { make in
        make.edges.equalTo(downloadItemController.progressBarView)
      }
    }
    cardView.addSubview(closeButton)
    cardView.addSubview(retryButton)
    closeButton.snp.makeConstraints { make in
      make.top.trailing.equalToSuperview().inset(16)
      make.size.equalTo(32)
    }
    retryButton.snp.makeConstraints { make in
      make.centerY.equalTo(closeButton)
      make.trailing.equalTo(closeButton.snp.leading).offset(-4)
      make.size.equalTo(32)
    }
    retryButton.isHidden = viewModel.mode != .error

    progressAnimator.onChange = { [weak self] in self?.setDisplayedProgress($0) }
    setDisplayedProgress(displayedProgress)
    closeButton.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        if let completion = self.finishCompletion {
          self.finishCompletion = nil
          self.monkeyAnimationController?.cancel()
          completion()
        } else {
          self.delegate?.didTapCloseDownload()
        }
      }, for: .touchUpInside)
    retryButton.addAction(
      UIAction { [weak self] _ in self?.delegate?.didTapRetryDownload() }, for: .touchUpInside)
  }

  func setVisible(_ visible: Bool, animated: Bool, completion: @escaping () -> Void = {}) {
    bannerController.setVisible(visible, animated: animated, completion: completion)
  }

  func beginMonkeyAnimation() {
    progressAnimator.cancelRunningAnimation()
  }

  func endMonkeyAnimation() {
    progressAnimator.value = displayedProgress
    progressAnimator.animate(to: realProgress, duration: 0.1, timingFunction: .linear)
  }

  func setDisplayedProgress(_ progress: Double) {
    displayedProgress = min(realProgress, max(0, progress.isFinite ? progress : 0))
    var model = viewModel
    model.progress = displayedProgress
    model.downloadedBytes =
      model.totalBytes > 0
      ? (displayedProgress >= 1
        ? model.totalBytes : Int64(Double(model.totalBytes) * displayedProgress)) : 0
    model.transferredBytes = nil
    downloadItemController.viewModel = model
    monkeyAnimationController?.update()
  }

  func finish(success: Bool, completion: @escaping () -> Void) {
    guard success else {
      monkeyAnimationController?.cancel()
      completion()
      return
    }
    var model = viewModel
    model.progress = 1
    model.downloadedBytes = model.totalBytes
    model.transferredBytes = model.totalBytes
    viewModel = model
    if let monkeyAnimationController {
      finishCompletion = completion
      monkeyAnimationController.finish { [weak self] in
        let completion = self?.finishCompletion
        self?.finishCompletion = nil
        completion?()
      }
    } else {
      completion()
    }
  }

  static func finalizeDownoladItems(list: [DownloadItem]) -> [DownloadItem] {
    var seen = Set<String>()
    var finalized = [DownloadItem]()
    finalized.reserveCapacity(list.count)
    for item in list where !seen.contains(item.file) {
      seen.insert(item.file)
      finalized.append(item)
    }
    return finalized
  }
}
