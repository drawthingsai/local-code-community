import Dflat
import UIKit

public final class ToolTipAndDetailAppearanceController {
  public private(set) var isHidden: Bool
  private let touchTarget: UIView
  private let detail: UIView
  public var iconView: UIImageView? = nil {
    didSet {
      iconView?.isHighlighted = !isHidden
    }
  }
  private let toolTip: String
  private let lookUpKey: String
  private let animateHidden: Bool
  private let defaultToHidden: Bool
  private var workspace: Workspace
  private var subscription: Workspace.Subscription? = nil
  private lazy var toolTipInteraction: UIToolTipInteraction = {
    UIToolTipInteraction(defaultToolTip: toolTip)
  }()
  public var animateAlongIsHiddenChange: ((Bool) -> Void)? = nil
  public init(
    _ touchTarget: UIView, detail: UIView, toolTip: String, lookUpKey: String, workspace: Workspace,
    animateHidden: Bool = true, defaultToHidden: Bool = false
  ) {
    dispatchPrecondition(condition: .onQueue(.main))
    isHidden = workspace.dictionary[lookUpKey, Bool.self] ?? defaultToHidden
    self.touchTarget = touchTarget
    self.detail = detail
    self.toolTip = toolTip
    self.lookUpKey = lookUpKey
    self.workspace = workspace
    self.animateHidden = animateHidden
    self.defaultToHidden = defaultToHidden
    let tapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(tap))
    touchTarget.addGestureRecognizer(tapGestureRecognizer)
    touchTarget.isUserInteractionEnabled = true
    detail.isHidden = isHidden
    detail.alpha = isHidden ? 0 : 1
    if isHidden {
      touchTarget.addInteraction(toolTipInteraction)
    }
    subscription = workspace.dictionary.subscribe(lookUpKey, of: Bool.self) { [weak self] value in
      guard let self = self else { return }
      self.newHiddenValue(value)
    }
  }
}

extension ToolTipAndDetailAppearanceController {
  private func newHiddenValue(_ value: SubscribedDictionaryValue<Bool>) {
    dispatchPrecondition(condition: .onQueue(.main))
    switch value {
    case .deleted:
      setHidden(false, animated: animateHidden)
    case .initial(let value):
      setHidden(value ?? defaultToHidden, animated: false)
    case .updated(let value):
      setHidden(value, animated: animateHidden)
    }
  }
  @objc
  private func tap() {
    workspace.dictionary[lookUpKey, Bool.self] = !isHidden
  }

  private func setHidden(_ isHidden: Bool, animated: Bool) {
    guard isHidden != self.isHidden else { return }
    self.isHidden = isHidden
    iconView?.isHighlighted = !isHidden
    if animated {
      UIView.animate(
        withDuration: 0.2, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState]
      ) {
        self.detail.isHidden = isHidden
        self.detail.alpha = isHidden ? 0 : 1
        self.detail.superview?.layoutIfNeeded()
        self.animateAlongIsHiddenChange?(isHidden)
      }
    } else {
      detail.isHidden = isHidden
      detail.alpha = isHidden ? 0 : 1
      animateAlongIsHiddenChange?(isHidden)
    }
    if isHidden {
      touchTarget.addInteraction(toolTipInteraction)
    } else {
      touchTarget.removeInteraction(toolTipInteraction)
    }
  }
}
