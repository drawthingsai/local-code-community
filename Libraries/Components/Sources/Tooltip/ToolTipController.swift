import Style
import UIKit

public final class ToolTipController {
  private let toolTipView: UIView
  private let toolTipLabel: UILabel
  public enum Position {
    case top
    case leading
    case trailing
    case bottom
  }
  public var toolTip: String {
    get { toolTipLabel.text ?? "" }
    set { toolTipLabel.text = newValue }
  }
  private let control: UIView
  private let containerView: UIView
  private let position: Position
  private let borderMargins: CGFloat
  private let maxWidth: CGFloat
  private let ancestorOf: Int
  private var cooldown: TimeInterval = 0
  private var longPressGestureRecognizer: UILongPressGestureRecognizer? = nil
  private var hoverGestureRecognizer: UIHoverGestureRecognizer? = nil
  private var hoverGestureCount: Int = 0
  private static func toolTipView(text: String) -> (UILabel, UIView) {
    let label = UILabel(frame: .zero)
    label.text = text
    FontMetrics.default.scaleFont(.systemFont(ofSize: 12), bindTo: label)
    label.textColor = .primaryTextColor
    label.lineBreakMode = .byWordWrapping
    label.numberOfLines = 0
    let toolTipView = UIView(frame: .zero)
    toolTipView.addSubview(label)
    label.snp.makeConstraints { make in
      make.leading.trailing.equalToSuperview().inset(8)
      make.top.bottom.equalToSuperview().inset(4)
    }
    toolTipView.backgroundColor = .buttonBackgroundColor
    toolTipView.layer.cornerRadius = 6
    toolTipView.layer.shadowColor = UIColor.black.cgColor
    toolTipView.layer.shadowOpacity = 0.3
    toolTipView.layer.shadowRadius = 4
    toolTipView.layer.shadowOffset = .zero
    toolTipView.alpha = 0
    return (label, toolTipView)
  }

  public init(
    view: UIView, containerView: UIView, toolTip: String, position: Position,
    borderMargins: CGFloat = 12, maxWidth: CGFloat = 144, ancestorOf: Int = 0
  ) {
    (toolTipLabel, toolTipView) = Self.toolTipView(text: toolTip)
    self.control = view
    self.containerView = containerView
    self.position = position
    self.borderMargins = borderMargins
    self.maxWidth = maxWidth
    self.ancestorOf = ancestorOf
    let longPressGestureRecognizer = UILongPressGestureRecognizer(
      target: self, action: #selector(longPress(_:)))
    longPressGestureRecognizer.minimumPressDuration = 0
    longPressGestureRecognizer.cancelsTouchesInView = false
    view.addGestureRecognizer(longPressGestureRecognizer)
    self.longPressGestureRecognizer = longPressGestureRecognizer
    let hoverGestureRecognizer = UIHoverGestureRecognizer(
      target: self, action: #selector(hover(_:)))
    hoverGestureRecognizer.cancelsTouchesInView = false
    control.addGestureRecognizer(hoverGestureRecognizer)
    self.hoverGestureRecognizer = hoverGestureRecognizer
  }

  deinit {
    if let longPressGestureRecognizer = longPressGestureRecognizer {
      control.removeGestureRecognizer(longPressGestureRecognizer)
    }
    if let hoverGestureRecognizer = hoverGestureRecognizer {
      control.removeGestureRecognizer(hoverGestureRecognizer)
    }
    if toolTipView.superview != nil {
      let toolTipView = toolTipView
      UIView.animate(
        withDuration: 0.1, delay: 0, options: [.beginFromCurrentState, .curveEaseInOut]
      ) {
        toolTipView.alpha = 0
      } completion: { _ in
        toolTipView.removeFromSuperview()
      }
    }
  }

  public init(
    control: UIControl, containerView: UIView, toolTip: String, position: Position,
    borderMargins: CGFloat = 12, maxWidth: CGFloat = 144, ancestorOf: Int = 0
  ) {
    (toolTipLabel, toolTipView) = Self.toolTipView(text: toolTip)
    self.control = control
    self.containerView = containerView
    self.position = position
    self.borderMargins = borderMargins
    self.maxWidth = maxWidth
    self.ancestorOf = ancestorOf
    control.addAction(
      UIAction { [weak self] _ in
        guard let self = self else { return }
        self.didTouchDown()
      }, for: .touchDown)
    control.addAction(
      UIAction { [weak self] _ in
        guard let self = self else { return }
        self.didTouchUp()
      }, for: [.touchUpInside, .touchUpOutside, .touchCancel, .menuActionTriggered])
    let hoverGestureRecognizer = UIHoverGestureRecognizer(
      target: self, action: #selector(hover(_:)))
    hoverGestureRecognizer.cancelsTouchesInView = false
    control.addGestureRecognizer(hoverGestureRecognizer)
    self.hoverGestureRecognizer = hoverGestureRecognizer
  }

  @objc
  private func longPress(_ gestureRecognizer: UIGestureRecognizer) {
    switch gestureRecognizer.state {
    case .began:
      didTouchDown()
    case .ended, .cancelled:
      didTouchUp()
    case .failed, .changed, .possible:
      break
    @unknown default:
      break
    }
  }

  @objc
  private func hover(_ gestureRecognizer: UIGestureRecognizer) {
    switch gestureRecognizer.state {
    case .began, .changed:
      didHoverIn()
    case .ended, .cancelled:
      didHoverOut()
    case .failed, .possible:
      break
    @unknown default:
      break
    }
  }

  private func didHoverIn() {
    hoverGestureCount += 1
    // Check after a second.
    let hoverGestureCount = hoverGestureCount
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(800)) { [weak self] in
      guard let self = self, hoverGestureCount == self.hoverGestureCount else { return }
      self.didTouchDown()
    }
  }

  private func didHoverOut() {
    hoverGestureCount += 1
    let hoverGestureCount = hoverGestureCount
    DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(1)) { [weak self] in
      guard let self = self, hoverGestureCount == self.hoverGestureCount else { return }
      self.didTouchUp()
    }
  }

  private func addSubview(_ view: UIView) {
    var containerView = containerView
    guard ancestorOf > 0 else {
      containerView.addSubview(view)
      return
    }
    for _ in 0..<ancestorOf {
      guard let superview = containerView.superview else { break }
      containerView = superview
    }
    containerView.addSubview(view)
  }

  private func didTouchDown() {
    // Ignore touch down if it is within the cooldown period.
    guard CACurrentMediaTime() >= cooldown else { return }
    addSubview(toolTipView)
    toolTipView.snp.makeConstraints { make in
      make.width.lessThanOrEqualTo(maxWidth)
      switch position {
      case .top:
        make.bottom.equalTo(control.snp.top).offset(-8)
        make.centerX.equalTo(control).priority(.low)
        make.leading.greaterThanOrEqualTo(containerView.snp.leading).offset(borderMargins).priority(
          .medium)
        make.trailing.lessThanOrEqualTo(containerView.snp.trailing).offset(-borderMargins).priority(
          .medium)
      case .leading:
        make.trailing.equalTo(control.snp.leading).offset(-8)
        make.centerY.equalTo(control).priority(.low)
        make.top.greaterThanOrEqualTo(containerView.snp.top).offset(borderMargins).priority(.medium)
        make.bottom.lessThanOrEqualTo(containerView.snp.bottom).offset(-borderMargins).priority(
          .medium)
      case .trailing:
        make.leading.equalTo(control.snp.trailing).offset(8)
        make.centerY.equalTo(control).priority(.low)
        make.top.greaterThanOrEqualTo(containerView.snp.top).offset(borderMargins).priority(.medium)
        make.bottom.lessThanOrEqualTo(containerView.snp.bottom).offset(-borderMargins).priority(
          .medium)
      case .bottom:
        make.top.equalTo(control.snp.bottom).offset(8)
        make.centerX.equalTo(control).priority(.low)
        make.leading.greaterThanOrEqualTo(containerView.snp.leading).offset(borderMargins).priority(
          .medium)
        make.trailing.lessThanOrEqualTo(containerView.snp.trailing).offset(-borderMargins).priority(
          .medium)
      }
    }
    UIView.animate(
      withDuration: 0.1, delay: 0,
      options: [.beginFromCurrentState, .curveEaseInOut, .allowUserInteraction]
    ) {
      self.toolTipView.alpha = 1
    }
  }

  private func didTouchUp() {
    cooldown = CACurrentMediaTime() + 1  // Have a 1s cooldown time to not trigger touch down.
    UIView.animate(
      withDuration: 0.1, delay: 0,
      options: [.beginFromCurrentState, .curveEaseInOut, .allowUserInteraction]
    ) {
      self.toolTipView.alpha = 0
    } completion: { _ in
      self.toolTipView.removeFromSuperview()
    }
  }
}
