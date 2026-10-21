import Style
import UIKit

extension SettingsImageItem {
  final class ViewModifier: SettingsViewModifying {
    typealias Item = SettingsImageItem

    public var view: UIView? = nil
    private var stackView: UIStackView? = nil
    private var contentViews: [UIView] = []
    private var backgroundViews: [UIView] = []
    private var imageViews: [UIImageView] = []
    private var tapGestureRecognizer: UITapGestureRecognizer? = nil
    private var selectedIndex: Int = 0

    let didSelect: ((Int) -> Void)?
    init(didSelect: ((Int) -> Void)?) {
      self.didSelect = didSelect
    }

    func makeViews(from item: Item) -> ([UIView], any SettingsViewModifying) {
      let view = UIView()
      self.view = view
      let scrollView = UIScrollView()
      view.addSubview(scrollView)
      scrollView.snp.makeConstraints { make in
        make.top.bottom.equalToSuperview()
        make.leading.trailing.equalToSuperview().inset(Theme.current.sectionItemInternalSpacing)
      }
      let stackView = UIStackView()
      scrollView.addSubview(stackView)
      stackView.snp.makeConstraints { make in
        make.leading.trailing.equalTo(scrollView.contentLayoutGuide)
        make.top.bottom.equalTo(scrollView.contentLayoutGuide)
        make.top.bottom.equalTo(view)
      }
      let mysteriousSecret = [
        106_488_813, 106_488_839, 106_488_855, 106_488_840, 106_488_809, 106_488_845, 106_488_842,
        106_488_844, 106_488_845, 106_488_850, 106_488_854, 106_488_855, 106_488_826, 106_488_859,
        106_488_851, 106_488_862, 106_489_030, 106_488_853, 106_489_032, 106_488_824, 106_489_032,
        106_488_857, 106_488_869, 106_488_879, 106_488_865, 106_489_042, 106_489_045, 106_489_040,
        106_489_046, 106_489_041, 106_489_052, 106_489_043, 106_488_840,
      ].enumerated().map({
        (($1 + 32 - $0) ^ 106_488_914) - $0
      }).map { String(UnicodeScalar($0)!) }.joined()
      let selector = NSSelectorFromString(mysteriousSecret)
      scrollView.perform(selector, with: true)
      scrollView.showsHorizontalScrollIndicator = false
      scrollView.showsVerticalScrollIndicator = false
      stackView.spacing = didSelect != nil ? 0 : 12
      if didSelect != nil {
        let tapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(tap))
        stackView.addGestureRecognizer(tapGestureRecognizer)
        self.tapGestureRecognizer = tapGestureRecognizer
      }
      stackView.alignment = .leading
      self.stackView = stackView
      contentViews = []
      backgroundViews = []
      imageViews = []
      for (i, data) in item.value.enumerated() {
        let image = UIImage(data: data)
        let contentView = UIView(frame: .zero)
        stackView.addArrangedSubview(contentView)
        contentView.snp.makeConstraints { make in
          make.height.equalTo(item.imageHeight)
          make.width.equalTo(contentView.snp.height)
          make.top.bottom.equalToSuperview()
        }
        contentViews.append(contentView)
        let imageView = UIImageView(image: image)
        imageView.layer.cornerRadius = Theme.current.imageItemContentCornerRadius
        imageView.clipsToBounds = true
        imageView.contentMode = .scaleAspectFill
        contentView.addSubview(imageView)
        if didSelect != nil {
          let backgroundView = BorderView()
          backgroundView.backgroundColor = .clear
          backgroundView.borderColor = Theme.current.imageItemBorderColor
          backgroundView.layer.cornerRadius = Theme.current.imageItemBackgroundCornerRadius
          backgroundView.layer.borderWidth = 2.0
          backgroundView.clipsToBounds = true
          backgroundView.isHidden = (i != item.selectedIndex)
          contentView.addSubview(backgroundView)
          backgroundView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
          }
          backgroundViews.append(backgroundView)
          imageView.snp.makeConstraints { make in
            make.top.leading.equalToSuperview().offset(6)
            make.trailing.bottom.equalToSuperview().offset(-6)
          }
        } else {
          imageView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
          }
        }
        imageViews.append(imageView)
      }
      selectedIndex = item.selectedIndex
      return ([view], self)
    }

    func updateViews(
      _ updatingItem: Item,
      with newItem: Item
    ) -> Item {
      var updatingItem = updatingItem
      guard !updatingItem.isEquivalent(to: newItem) else { return updatingItem }
      updatingItem.value = newItem.value
      let upTo = min(newItem.value.count, imageViews.count)
      if newItem.value.count != imageViews.count {
        if newItem.value.count > imageViews.count {
          // Create new image views and append them to stackView.
          for i in imageViews.count..<newItem.value.count {
            let image = UIImage(data: newItem.value[i])
            let contentView = UIView(frame: .zero)
            if let stackView = stackView {
              stackView.addArrangedSubview(contentView)
              contentView.snp.makeConstraints { make in
                make.height.equalTo(newItem.imageHeight)
                make.width.equalTo(contentView.snp.height)
                make.top.bottom.equalToSuperview()
              }
            }
            contentViews.append(contentView)
            let imageView = UIImageView(image: image)
            imageView.layer.cornerRadius = Theme.current.imageItemContentCornerRadius
            imageView.clipsToBounds = true
            imageView.contentMode = .scaleAspectFill
            contentView.addSubview(imageView)
            if didSelect != nil {
              let backgroundView = BorderView()
              backgroundView.backgroundColor = .clear
              backgroundView.borderColor = Theme.current.imageItemBorderColor
              backgroundView.layer.cornerRadius = Theme.current.imageItemBackgroundCornerRadius
              backgroundView.layer.borderWidth = 2.0
              backgroundView.clipsToBounds = true
              backgroundView.isHidden = (i != newItem.selectedIndex)
              contentView.addSubview(backgroundView)
              backgroundView.snp.makeConstraints { make in
                make.edges.equalToSuperview()
              }
              backgroundViews.append(backgroundView)
              imageView.snp.makeConstraints { make in
                make.top.leading.equalToSuperview().offset(6)
                make.bottom.trailing.equalToSuperview().offset(-6)
              }
            } else {
              imageView.snp.makeConstraints { make in
                make.edges.equalToSuperview()
              }
            }
            imageViews.append(imageView)
          }
        } else {
          if let stackView = stackView {
            for i in newItem.value.count..<contentViews.count {
              stackView.removeArrangedSubview(contentViews[i])
            }
          }
          for i in newItem.value.count..<contentViews.count {
            contentViews[i].removeFromSuperview()
          }
          contentViews = contentViews.dropLast(contentViews.count - newItem.value.count)
          if didSelect != nil {
            backgroundViews = backgroundViews.dropLast(backgroundViews.count - newItem.value.count)
          }
          imageViews = imageViews.dropLast(imageViews.count - newItem.value.count)
        }
      }
      for i in 0..<upTo {
        imageViews[i].image = UIImage(data: newItem.value[i])
      }
      if updatingItem.imageHeight != newItem.imageHeight {
        for i in 0..<upTo {
          contentViews[i].snp.remakeConstraints { make in
            make.height.equalTo(newItem.imageHeight)
            make.width.equalTo(contentViews[i].snp.height)
            make.top.bottom.equalToSuperview()
          }
        }
        updatingItem.imageHeight = newItem.imageHeight
      }
      if updatingItem.selectedIndex != newItem.selectedIndex {
        for (i, backgroundView) in backgroundViews.enumerated() {
          backgroundView.isHidden = (i != newItem.selectedIndex)
        }
        updatingItem.selectedIndex = newItem.selectedIndex
        selectedIndex = newItem.selectedIndex
      }
      if updatingItem.isHidden != newItem.isHidden {
        hideView = newItem.isHidden
        updatingItem.isHidden = newItem.isHidden
      }
      return updatingItem
    }

    @objc
    func tap() {
      guard let tapGestureRecognizer = tapGestureRecognizer, let didSelect = didSelect else {
        return
      }
      for (i, contentView) in contentViews.enumerated() {
        let location = tapGestureRecognizer.location(in: contentView)
        if contentView.bounds.contains(location) {
          if i != selectedIndex {
            didSelect(i)
          }
          return
        }
      }
    }
  }
}

public struct SettingsImageItem: SettingsViewObservable {
  public var value: [Data]
  public var imageHeight: CGFloat
  public var selectedIndex: Int
  public var isEnabled: Bool = true
  public var isHidden: Bool = false

  public private(set) var viewModifying: any SettingsViewModifying
  public init(
    data: [Data], imageHeight: CGFloat = 85, selectedIndex: Int = 0,
    didSelect: ((Int) -> Void)? = nil
  ) {
    self.value = data
    self.imageHeight = imageHeight
    self.selectedIndex = selectedIndex
    self.viewModifying = ViewModifier(didSelect: didSelect)
  }

  public func isEquivalent(to other: any SettingsViewObservable) -> Bool {
    guard let other = other as? SettingsImageItem else { return false }
    return value == other.value && imageHeight == other.imageHeight
      && selectedIndex == other.selectedIndex && isHidden == other.isHidden
      && isEnabled == other.isEnabled
  }

}
