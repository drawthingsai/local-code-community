//Created 11/13/23

import Dflat
import Style
import UIKit

final class ImageLeadingSegmentedControl: UISegmentedControl {
  let imageViews: [UIImageView]
  let imagePadding: CGFloat
  var titles: [String]
  init(actions: [UIAction], imagePadding: CGFloat) {
    let images: [UIImage?] = actions.map(\.image)
    var imageViews = [UIImageView]()
    if images.contains(where: { $0 != nil }) {
      for image in images {
        imageViews.append(UIImageView(image: image))
      }
    }
    self.imagePadding = imagePadding
    self.imageViews = imageViews
    titles = actions.map(\.title)
    let items = actions.map {
      $0.image = nil
      return $0
    }
    super.init(items: items)
    // Below are string "UISegment"
    let mysteriousSecret = [
      106_488_807, 106_488_825, 106_488_809, 106_488_861, 106_488_861,
      106_488_837, 106_488_863, 106_488_846, 106_488_854,
    ].enumerated().map({
      (($1 + 32 - $0) ^ 106_488_914) - $0
    }).map { String(UnicodeScalar($0)!) }.joined()
    let klass: AnyClass = NSClassFromString(mysteriousSecret)!
    let segments = subviews.filter { $0.isKind(of: klass) }
    // TODO: fix this selected color as well
    for (i, (segment, imageView)) in zip(segments, imageViews).enumerated() {
      imageView.tintColor = i == selectedSegmentIndex ? .primaryText : .senaryText
      segment.addSubview(imageView)
      imageView.sizeToFit()
      setContentOffset(
        CGSize(width: (imageView.frame.width + imagePadding) / 2, height: 0), forSegmentAt: i)
    }
  }

  required public init?(coder: NSCoder) {
    fatalError()
  }
  override public func setImage(_ image: UIImage?, forSegmentAt segment: Int) {
    guard segment >= 0 && segment < imageViews.count else { return }
    imageViews[segment].image = image
    super.setImage(image, forSegmentAt: segment)
  }
  override public func setTitle(_ title: String?, forSegmentAt segment: Int) {
    guard segment >= 0 && segment < titles.count else { return }
    titles[segment] = title ?? ""
    super.setTitle(title, forSegmentAt: segment)
  }
  override public var selectedSegmentIndex: Int {
    get { super.selectedSegmentIndex }
    set {
      super.selectedSegmentIndex = newValue
      for (i, imageView) in imageViews.enumerated() {
        imageView.tintColor = i == newValue ? .primaryText : .senaryText
      }
    }
  }
  override public func layoutSubviews() {
    super.layoutSubviews()
    for (title, imageView) in zip(titles, imageViews) {
      guard let segment = imageView.superview, let label = segment.value(forKey: "label") as? UIView
      else { continue }
      segment.layoutIfNeeded()
      let previousTransform = label.transform
      label.transform = .identity
      let labelXY: CGPoint
      let titleIsEmpty = title.isEmpty
      if titleIsEmpty {
        labelXY = label.convert(CGPoint(x: label.bounds.midX, y: label.bounds.midY), to: segment)
      } else {
        labelXY = label.convert(CGPoint(x: label.bounds.minX, y: label.bounds.midY), to: segment)
      }
      label.transform = previousTransform
      imageView.sizeToFit()
      // Why titleIsEmpty is complicated? Because we setContentOffset for the label regardless of whether it is empty or not. Now we need to recover those bits.
      imageView.frame = CGRectIntegral(
        CGRect(
          origin: CGPoint(
            x: titleIsEmpty
              ? labelXY.x - imageView.frame.width - imagePadding / 2
              : labelXY.x - imagePadding - imageView.frame.width,
            y: labelXY.y - imageView.frame.height / 2),
          size: imageView.frame.size))
    }
  }
}

extension SettingsSegmentedControlItem {
  final class ViewModifier: SettingsViewModifying {
    public typealias Item = SettingsSegmentedControlItem
    public var view: UIView?
    public var segmentedControl: UISegmentedControl?
    public var actions: [UIAction]
    public var titleLabel: UILabel?

    public init(actions: [UIAction]) {
      self.actions = actions
    }

    public func makeViews(from item: Item) -> ([UIView], any SettingsViewModifying) {
      let view = UIView()
      self.view = view
      let segmentedControl: UISegmentedControl
      if actions.contains(where: { $0.image != nil && !$0.title.isEmpty }) {
        segmentedControl = ImageLeadingSegmentedControl(
          actions: actions, imagePadding: Theme.current.textImagePadding)
      } else {
        segmentedControl = UISegmentedControl(frame: .zero, actions: actions)
      }
      let label = UILabel(frame: .zero)
      label.text = item.title
      label.textColor = Theme.current.secondaryContentColor
      FontMetrics.default.scaleFont(Theme.current.secondaryContentFont, bindTo: label)
      self.titleLabel = label
      view.addSubview(label)
      label.snp.makeConstraints { make in
        make.top.equalToSuperview().offset(1.5 + item.extraTopPadding)
        make.leading.equalToSuperview().offset(Theme.current.sectionContentMargin)
      }
      self.segmentedControl = segmentedControl
      segmentedControl.selectedSegmentIndex = item.value
      segmentedControl.selectedSegmentTintColor = .senaryFill
      view.addSubview(segmentedControl)
      segmentedControl.backgroundColor = .quaternaryFillA
      segmentedControl.setTitleTextAttributes(
        [.foregroundColor: UIColor.primaryText], for: .selected)
      FontMetrics.default.scaleFont(
        .systemFont(ofSize: 14, weight: .medium), bindTo: segmentedControl
      ) {
        $0.setTitleTextAttributes([.font: $1, .foregroundColor: UIColor.senaryText], for: .normal)
      }
      segmentedControl.snp.makeConstraints { make in
        make.height.equalTo(Theme.current.segmentedControlHeight)
        make.left.right.bottom.equalToSuperview()
        if let _ = item.title {
          make.top.equalTo(label.snp.bottom).offset(1.5 + Theme.current.stackViewItemSpacing)
        } else {
          make.top.equalToSuperview().offset(item.extraTopPadding)
        }
      }
      view.isHidden = item.isHidden

      return ([view], self)
    }

    public func updateViews(
      _ updatingItem: Item,
      with newItem: Item
    ) -> Item {
      var updatingItem = updatingItem
      segmentedControl?.selectedSegmentIndex = newItem.value
      updatingItem.value = newItem.value
      if updatingItem.isHidden != newItem.isHidden {
        hideView = newItem.isHidden
        updatingItem.isHidden = newItem.isHidden
      }
      if updatingItem.subitems != newItem.subitems, let segmentedControl = segmentedControl {
        for (i, (_, subitem)) in zip(updatingItem.subitems, newItem.subitems).enumerated() {
          segmentedControl.setImage(subitem.image, forSegmentAt: i)
          if let title = subitem.title, !title.isEmpty {
            segmentedControl.setTitle(subitem.title, forSegmentAt: i)
          }
        }
      }
      updatingItem.subitems = newItem.subitems
      updatingItem.title = newItem.title
      titleLabel?.text = updatingItem.title
      return updatingItem
    }
  }
}

public struct SettingsSegmentedControlItem: SettingsViewObservable {
  public var isHidden: Bool = false
  public var isEnabled: Bool = true
  public var value: Int  // selectedIndex
  public var title: String?
  public var extraTopPadding: CGFloat
  public private(set) var viewModifying: any SettingsViewModifying
  struct Subitem: Equatable, Hashable {
    var title: String?
    var discoverabilityTitle: String?
    var image: UIImage?
    static func == (lhs: Subitem, rhs: Subitem) -> Bool {
      // Ignore the image one.
      return lhs.title == rhs.title && lhs.discoverabilityTitle == rhs.discoverabilityTitle
    }
    func hash(into hasher: inout Hasher) {
      // Ignore the image one.
      hasher.combine(title)
      hasher.combine(discoverabilityTitle)
    }
  }
  var subitems: [Subitem]
  public init(
    value: Int, title: String? = nil, extraTopPadding: CGFloat = 0, actions: [UIAction]
  ) {
    self.value = value
    self.title = title
    self.extraTopPadding = extraTopPadding
    subitems = actions.map {
      Subitem(title: $0.title, discoverabilityTitle: $0.discoverabilityTitle, image: $0.image)
    }
    viewModifying = ViewModifier(
      actions: actions.map {
        $0.discoverabilityTitle = nil
        return $0
      })
  }

  public func isEquivalent(to other: any SettingsViewObservable) -> Bool {
    guard let other = other as? SettingsSegmentedControlItem else { return false }
    return value == other.value && subitems == other.subitems && isHidden == other.isHidden
      && isEnabled == other.isEnabled && title == other.title
  }
}
