import UIKit

public struct SettingsItemReconciler<
  T: Equatable & Hashable, KeyValuePairs: Sequence & ExpressibleByDictionaryLiteral
> where KeyValuePairs.Element == (key: T, value: any SettingsViewObservable) {
  private var displayingItems: [T: any SettingsViewObservable] = [:]
  private var sectionViewModifiers: [T: any SettingsViewModifying] = [:]
  private var sectionViews: [T: [UIView]] = [:]
  private let stackView: UIStackView
  public init(view: UIStackView) {
    stackView = view
  }

  public var items: KeyValuePairs = [:] {
    didSet {
      dispatchPrecondition(condition: .onQueue(.main))
      for (key, item) in items {
        // Check if we have existing section, if not, this is not loaded, we can skip safely.
        guard let existingItem = displayingItems[key] else {
          let (views, viewModifier) = item.viewModifying.makeViews(
            from: item)
          for view in views {
            stackView.addArrangedSubview(view)
            view.snp.makeConstraints { make in
              make.leading.trailing.equalToSuperview()
            }
          }
          sectionViewModifiers[key] = viewModifier
          sectionViews[key] = views
          displayingItems[key] = item
          continue
        }
        guard !existingItem.isEquivalent(to: item) else { continue }
        if let updatedItem = sectionViewModifiers[key]?.updateViews(
          existingItem, with: item)
        {
          displayingItems[key] = updatedItem
        }
      }
    }
  }
}
