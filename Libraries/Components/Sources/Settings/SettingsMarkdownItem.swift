//Created 12/15/24

import Nantes
import Style
import UIKit

extension SettingsMarkdownItem {
  final class ViewModifier: SettingsViewModifying {
    typealias Item = SettingsMarkdownItem

    public var view: UIView?
    public var uriHandler: ((URL) -> Bool)?
    var leadingLabel: NantesLabel?

    init(_ uriHandler: ((URL) -> Bool)?) {
      self.uriHandler = uriHandler
    }

    func makeViews(from item: Item) -> ([UIView], any SettingsViewModifying) {
      let view = UIView()
      self.view = view
      let leadingLabel = NantesLabel(frame: .zero)
      leadingLabel.lineBreakMode = .byWordWrapping
      leadingLabel.numberOfLines = 0
      leadingLabel.delegate = self
      leadingLabel.linkAttributes = [.foregroundColor: UIColor.secondaryText]
      var attributedText = item.value.attributedString
      FontMetrics.default.scaleFont(.systemFont(ofSize: item.fontSize), bindTo: leadingLabel) {
        label, font in
        attributedText?.foregroundColor = UIColor.quaternaryText
        attributedText?.font = font
        label.attributedText = attributedText.map { NSAttributedString($0) }
      }
      view.addSubview(leadingLabel)
      leadingLabel.snp.makeConstraints { make in
        make.leading.equalToSuperview().offset(Theme.current.sectionContentMargin)
        make.trailing.equalToSuperview().inset(Theme.current.sectionContentMargin)
        make.top.equalToSuperview().offset(1.5 + item.extraTopPadding)
        make.bottom.equalToSuperview().offset(-1.5)
      }
      self.leadingLabel = leadingLabel
      view.isHidden = item.isHidden
      return ([view], self)
    }

    func updateViews(
      _ updatingItem: Item,
      with newItem: Item
    ) -> Item {
      var updatingItem = updatingItem
      guard !updatingItem.isEquivalent(to: newItem) else { return updatingItem }
      if updatingItem.fontSize != newItem.fontSize || updatingItem.value != newItem.value,
        let leadingLabel = leadingLabel
      {
        updatingItem.value = newItem.value
        updatingItem.fontSize = newItem.fontSize
        FontMetrics.default.clearBinding(to: leadingLabel)
        var attributedText = newItem.value.attributedString
        FontMetrics.default.scaleFont(.systemFont(ofSize: newItem.fontSize), bindTo: leadingLabel) {
          label, font in
          attributedText?.foregroundColor = UIColor.quaternaryText
          attributedText?.font = font
          label.attributedText = attributedText.map { NSAttributedString($0) }
        }
      }
      if updatingItem.isHidden != newItem.isHidden {
        hideView = newItem.isHidden
        updatingItem.isHidden = newItem.isHidden
      }
      return updatingItem
    }
  }
}

public struct SettingsMarkdownItem: SettingsViewObservable {
  public enum Value: Equatable {
    case markdown(String)
    case attributed(AttributedString)
    var attributedString: AttributedString? {
      switch self {
      case .attributed(let value):
        return value
      case .markdown(let value):
        return try? AttributedString(markdown: value)
      }
    }
  }
  public var value: Value
  public var fontSize: CGFloat
  public var isEnabled: Bool = true
  public var isHidden: Bool = false
  public var extraTopPadding: CGFloat

  public private(set) var viewModifying: any SettingsViewModifying
  public init(
    _ value: Value, fontSize: CGFloat = 11, extraTopPadding: CGFloat = 0,
    uriHandler: ((URL) -> Bool)? = nil
  ) {
    self.value = value
    self.fontSize = fontSize
    self.extraTopPadding = extraTopPadding
    viewModifying = ViewModifier(uriHandler)
  }

  public func isEquivalent(to other: any SettingsViewObservable) -> Bool {
    guard let other = other as? SettingsMarkdownItem else { return false }
    return value == other.value && fontSize == other.fontSize && isHidden == other.isHidden
      && isEnabled == other.isEnabled
  }
}

extension SettingsMarkdownItem.ViewModifier: NantesLabelDelegate {
  func attributedLabel(_ label: NantesLabel, didSelectLink link: URL) {
    // If it is empty, or it is handled, skip.
    guard uriHandler?(link) != true else {
      return
    }
    UIApplication.shared.open(link, options: [:], completionHandler: nil)
  }
}
