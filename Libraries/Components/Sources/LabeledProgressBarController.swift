import Localization
import SnapKit
import Style
import UIKit

public final class LabeledProgressBarController {
  public struct ViewModel: Equatable {
    public var leadingLabel: String
    public var trailingLabel: String
    public var progress: Double
    public init(leadingLabel: String, trailingLabel: String, progress: Double) {
      self.leadingLabel = leadingLabel
      self.trailingLabel = trailingLabel
      self.progress = progress
    }
    public init(label: String, progress: Double) {
      self.leadingLabel = label
      self.progress = progress
      trailingLabel = ""
    }
  }

  private let labelHorizontalInset: CGFloat
  private let labelFontSize: CGFloat
  private let centerYOffset: CGFloat
  private lazy var progressLabel: UILabel = {
    let label = UILabel(frame: .zero)
    label.textColor = .quaternaryText
    label.textAlignment = .natural
    label.numberOfLines = 1
    label.lineBreakMode = .byTruncatingTail
    FontMetrics.default.scaleFont(
      .systemFont(ofSize: labelFontSize, weight: .regular), bindTo: label)
    return label
  }()
  private lazy var onProgressBarProgressLabel: UILabel = {
    let label = UILabel(frame: .zero)
    label.textColor = .nonaryText
    label.textAlignment = .natural
    label.numberOfLines = 1
    label.lineBreakMode = .byTruncatingTail
    FontMetrics.default.scaleFont(
      .systemFont(ofSize: labelFontSize, weight: .regular), bindTo: label)
    return label
  }()
  private lazy var progressCancelButton: UIButton = {
    let button = UIButton(type: .custom)
    var configuration = UIButton.Configuration.plain()
    configuration.baseBackgroundColor = .clear
    configuration.image = #imageLiteral(resourceName: "cancel").withTintColor(.senaryText)
    configuration.background.cornerRadius = 8
    button.configuration = configuration
    button.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        self.didTapCancel?()
      }, for: .touchUpInside)
    return button
  }()
  private lazy var onProgressBarProgressCancelButton: UIButton = {
    let button = UIButton(type: .custom)
    var configuration = UIButton.Configuration.plain()
    configuration.baseBackgroundColor = .clear
    configuration.image = #imageLiteral(resourceName: "cancel").withTintColor(.nonaryText)
    configuration.background.cornerRadius = 8
    button.configuration = configuration
    button.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        self.didTapCancel?()
      }, for: .touchUpInside)
    return button
  }()
  private lazy var onProgressBarTrailingLabel: UILabel = {
    let label = UILabel(frame: .zero)
    label.textColor = .nonaryText
    label.textAlignment = .natural
    label.numberOfLines = 1
    label.lineBreakMode = .byTruncatingTail
    FontMetrics.default.scaleFont(
      .monospacedDigitSystemFont(ofSize: labelFontSize, weight: .regular), bindTo: label)
    return label
  }()
  private lazy var trailingLabel: UILabel = {
    let label = UILabel(frame: .zero)
    label.textColor = .quaternaryText
    label.textAlignment = .natural
    label.numberOfLines = 1
    label.lineBreakMode = .byTruncatingTail
    FontMetrics.default.scaleFont(
      .monospacedDigitSystemFont(ofSize: labelFontSize, weight: .regular), bindTo: label)
    return label
  }()

  public let view: UIView
  private let onProgressBar: UIView
  private let onProgressBackground: UIView

  public var didTapCancel: (() -> Void)? {
    didSet {
      guard (didTapCancel == nil && oldValue != nil) || (didTapCancel != nil && oldValue == nil)
      else { return }
      if didTapCancel != nil {
        onProgressBackground.insertSubview(progressCancelButton, belowSubview: onProgressBar)
        progressCancelButton.snp.remakeConstraints { make in
          make.size.equalTo(16)
          make.centerY.equalToSuperview()
          make.trailing.equalToSuperview().offset(-8)
        }
        onProgressBar.addSubview(onProgressBarProgressCancelButton)
        onProgressBarProgressCancelButton.snp.remakeConstraints { make in
          make.edges.equalTo(progressCancelButton)
        }
        trailingLabel.snp.remakeConstraints { make in
          make.centerY.equalToSuperview().offset(centerYOffset)
          make.trailing.equalTo(progressCancelButton.snp.leading).offset(-8)
        }
      } else {
        progressCancelButton.removeFromSuperview()
        onProgressBarProgressCancelButton.removeFromSuperview()
        trailingLabel.snp.remakeConstraints { make in
          make.centerY.equalToSuperview().offset(centerYOffset)
          make.trailing.equalToSuperview().offset(-labelHorizontalInset)
        }
      }
    }
  }
  public var viewModel: ViewModel {
    didSet {
      guard viewModel != oldValue else { return }
      if viewModel.leadingLabel != oldValue.leadingLabel {
        progressLabel.text = viewModel.leadingLabel
        onProgressBarProgressLabel.text = viewModel.leadingLabel
      }
      if viewModel.trailingLabel != oldValue.trailingLabel {
        trailingLabel.text = viewModel.trailingLabel
        onProgressBarTrailingLabel.text = viewModel.trailingLabel
      }
      // Text might need to layout, to avoid animate, layout first before changing onProgressBar constraints.
      if viewModel.progress != oldValue.progress {
        view.layoutIfNeeded()
        onProgressBar.snp.remakeConstraints { make in
          make.top.bottom.leading.equalToSuperview()
          make.width.equalToSuperview().multipliedBy(viewModel.progress)
        }
        let view = view
        guard view.window != nil else { return }
        UIView.animate(
          withDuration: 0.1, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
          view.layoutIfNeeded()
        }
      }
    }
  }

  public init(
    viewModel: ViewModel, defaultHeight: CGFloat = 32, labelHorizontalInset: CGFloat = 12,
    labelFontSize: CGFloat = 14, centerYOffset: CGFloat = -1, didTapCancel: (() -> Void)? = nil,
    fullyRoundedProgressBar: Bool = false
  ) {
    self.labelHorizontalInset = labelHorizontalInset
    self.labelFontSize = labelFontSize
    self.centerYOffset = centerYOffset
    self.viewModel = viewModel
    self.didTapCancel = didTapCancel
    view = UIView(frame: .zero)
    view.layer.masksToBounds = true
    onProgressBackground = UIView(frame: .zero)
    onProgressBar = UIView(frame: .zero)

    onProgressBackground.layer.cornerRadius = fullyRoundedProgressBar ? defaultHeight / 2 : 8
    onProgressBackground.backgroundColor = .quinaryBackground
    onProgressBackground.layer.masksToBounds = true
    view.addSubview(onProgressBackground)
    onProgressBackground.snp.makeConstraints { make in
      make.edges.equalToSuperview()
      make.height.equalTo(defaultHeight).priority(.high)
    }
    onProgressBackground.addSubview(progressLabel)
    onProgressBar.backgroundColor = .primaryFill
    onProgressBar.clipsToBounds = true
    onProgressBackground.addSubview(onProgressBar)
    onProgressBar.snp.makeConstraints { make in
      make.top.bottom.leading.equalToSuperview()
      make.width.equalToSuperview().multipliedBy(viewModel.progress)
    }
    onProgressBar.addSubview(onProgressBarProgressLabel)
    onProgressBarProgressLabel.snp.makeConstraints { make in
      make.edges.equalTo(progressLabel)
    }
    if didTapCancel != nil {
      onProgressBackground.insertSubview(progressCancelButton, belowSubview: onProgressBar)
      progressCancelButton.snp.makeConstraints { make in
        make.size.equalTo(16)
        make.centerY.equalToSuperview()
        make.trailing.equalToSuperview().offset(-8)
      }
      onProgressBar.addSubview(onProgressBarProgressCancelButton)
      onProgressBarProgressCancelButton.snp.makeConstraints { make in
        make.edges.equalTo(progressCancelButton)
      }
    }
    onProgressBackground.insertSubview(trailingLabel, belowSubview: onProgressBar)
    onProgressBar.addSubview(onProgressBarTrailingLabel)
    progressLabel.snp.makeConstraints { make in
      make.centerY.equalToSuperview().offset(centerYOffset)
      make.leading.equalToSuperview().offset(labelHorizontalInset)
      make.trailing.equalToSuperview().offset(-44).priority(.high)
      make.trailing.lessThanOrEqualTo(trailingLabel.snp.leading).offset(-labelHorizontalInset)
        .priority(.high.advanced(by: 1))
    }
    trailingLabel.snp.makeConstraints { make in
      make.centerY.equalToSuperview().offset(centerYOffset)
      if didTapCancel != nil {
        make.trailing.equalTo(progressCancelButton.snp.leading).offset(-8)
      } else {
        make.trailing.equalToSuperview().offset(-labelHorizontalInset)
      }
    }
    onProgressBarTrailingLabel.snp.makeConstraints { make in
      make.edges.equalTo(trailingLabel)
    }
    progressLabel.text = viewModel.leadingLabel
    onProgressBarProgressLabel.text = viewModel.leadingLabel
    trailingLabel.text = viewModel.trailingLabel
    onProgressBarTrailingLabel.text = viewModel.trailingLabel
  }
}
