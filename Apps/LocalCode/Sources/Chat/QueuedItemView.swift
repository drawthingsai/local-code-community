import Components
import Localization
import ProjectHistoryManager
import SnapKit
import Style
import UIKit

protocol QueuedItemViewDelegate: AnyObject {
  func queuedItemView(_ view: QueuedItemView, didTapSteerQueuedItem queuedItem: ProjectQueuedItem)
  func queuedItemView(_ view: QueuedItemView, didTapDeleteQueuedItem queuedItem: ProjectQueuedItem)
}

/// A prompt queued behind the running turn, with steer and delete buttons. Shared by the iPhone
/// and iPad chat screens.
final class QueuedItemView: UIView {
  weak var delegate: QueuedItemViewDelegate?
  var queuedItem: ProjectQueuedItem {
    didSet {
      guard queuedItem != oldValue else { return }
      label.text = (queuedItem.text ?? "").components(separatedBy: .newlines).joined(
        separator: " ")
    }
  }
  /// A steered item waits for the running turn to stop, showing a spinner in place of its buttons.
  var isSteering = false {
    didSet {
      guard isSteering != oldValue else { return }
      steerButton.isHidden = isSteering
      deleteButton.isHidden = isSteering
      if isSteering {
        activityIndicator.startAnimating()
      } else {
        activityIndicator.stopAnimating()
      }
    }
  }

  private lazy var label: UILabel = {
    let label = UILabel(frame: .zero)
    label.textColor = .secondaryText
    label.numberOfLines = 1
    label.lineBreakMode = .byTruncatingTail
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    FontMetrics.default.scaleFont(
      .systemFont(ofSize: 15, weight: .regular), bindTo: label)
    return label
  }()
  private lazy var steerButton: UIButton = {
    let button = UIButton(type: .custom)
    var configuration = UIButton.Configuration.filled()
    configuration.cornerStyle = .capsule
    configuration.background.backgroundColor = .clear
    configuration.baseForegroundColor = .senaryText
    configuration.title = LocalizedString.forKey("steer")
    configuration.contentInsets = NSDirectionalEdgeInsets(
      top: 0, leading: 8, bottom: 0, trailing: 8)
    button.configuration = configuration
    button.configurationUpdateHandler = {
      guard var configuration = $0.configuration else { return }
      configuration.background.backgroundColor = $0.isHighlighted ? .quinaryBackground : .clear
      $0.configuration = configuration
    }
    FontMetrics.default.scaleFont(.systemFont(ofSize: 12, weight: .medium), bindTo: button)
    button.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        self.delegate?.queuedItemView(self, didTapSteerQueuedItem: self.queuedItem)
      }, for: .touchUpInside)
    return button
  }()
  private lazy var deleteButton: UIButton = {
    let button = UIButton(type: .custom)
    var configuration = UIButton.Configuration.filled()
    configuration.cornerStyle = .capsule
    configuration.background.backgroundColor = .clear
    configuration.baseForegroundColor = .senaryText
    configuration.contentInsets = NSDirectionalEdgeInsets(
      top: 8, leading: 8, bottom: 8, trailing: 8)
    configuration.image = #imageLiteral(resourceName: "trash-16").withRenderingMode(
      .alwaysTemplate)
    button.configuration = configuration
    button.configurationUpdateHandler = {
      guard var configuration = $0.configuration else { return }
      configuration.background.backgroundColor = $0.isHighlighted ? .quinaryBackground : .clear
      $0.configuration = configuration
    }
    button.accessibilityLabel = LocalizedString.forKey("delete")
    button.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        self.delegate?.queuedItemView(self, didTapDeleteQueuedItem: self.queuedItem)
      }, for: .touchUpInside)
    return button
  }()
  private lazy var activityIndicator: UIActivityIndicatorView = {
    let activityIndicator = UIActivityIndicatorView(style: .medium)
    activityIndicator.hidesWhenStopped = true
    return activityIndicator
  }()

  init(queuedItem: ProjectQueuedItem, buttonSize: CGFloat) {
    self.queuedItem = queuedItem
    super.init(frame: .zero)
    addSubview(label)
    addSubview(steerButton)
    addSubview(deleteButton)
    addSubview(activityIndicator)
    label.snp.makeConstraints { make in
      make.leading.equalToSuperview()
      make.trailing.equalTo(steerButton.snp.leading).offset(-8)
      make.centerY.equalToSuperview()
    }
    steerButton.snp.makeConstraints { make in
      make.trailing.equalTo(deleteButton.snp.leading).offset(-4)
      make.centerY.equalToSuperview()
      make.height.equalTo(buttonSize)
    }
    deleteButton.snp.makeConstraints { make in
      make.top.bottom.trailing.equalToSuperview()
      make.size.equalTo(buttonSize)
    }
    activityIndicator.snp.makeConstraints { make in
      make.center.equalTo(deleteButton)
    }
    label.text = (queuedItem.text ?? "").components(separatedBy: .newlines).joined(
      separator: " ")
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}
