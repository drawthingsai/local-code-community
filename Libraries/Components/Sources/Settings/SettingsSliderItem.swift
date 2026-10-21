//Created 11/13/23
import Style
import UIKit

public struct SettingsSliderItem: SettingsViewObservable {
  final class ViewModifier: SettingsViewModifying {
    public typealias Item = SettingsSliderItem
    // views
    public var view: UIView?
    public var titleLabel: UILabel?
    public var slider: UISlider?
    public var valueButton: UIButton?

    public var handleValueChange: (Float) -> Void
    public var maxValue: Float
    public var valueType: ValueType
    init(valueType: ValueType, maxValue: Float, handleValueChange: @escaping (Float) -> Void) {
      self.valueType = valueType
      self.maxValue = maxValue
      self.handleValueChange = handleValueChange
    }

    public func makeViews(from item: Item) -> (
      [UIView], any SettingsViewModifying
    ) {
      let view = UIView()
      self.view = view
      let label = UILabel(frame: .zero)
      label.text = item.title
      label.textColor = Theme.current.secondaryContentColor
      FontMetrics.default.scaleFont(Theme.current.secondaryContentFont, bindTo: label)
      self.titleLabel = label
      let slider = CustomSlider(frame: .zero)
      self.slider = slider
      slider.tintColor = Theme.current.controlOnTintColor
      slider.maximumTrackTintColor = Theme.current.sliderMaximumTrackTintColor
      slider.minimumValue = item.minValue
      slider.maximumValue = item.maxValue
      slider.value = item.value
      slider.setThumbImage(#imageLiteral(resourceName: "thumb-white-20"), for: .normal)
      slider.isEnabled = item.isEnabled
      let valueButton = UIButton(type: .custom)
      self.valueButton = valueButton
      var configuration = UIButton.Configuration.borderless()
      configuration.title = SettingsSliderItem.defaultFormattedValue(
        item.value, type: item.type)
      configuration.titleAlignment = .trailing
      configuration.baseForegroundColor = .senaryText
      configuration.contentInsets = NSDirectionalEdgeInsets(
        top: 0, leading: 4, bottom: 0, trailing: 4)
      valueButton.configuration = configuration
      FontMetrics.default.scaleFont(
        .monospacedDigitSystemFont(ofSize: 11, weight: .regular), bindTo: valueButton)
      view.addSubview(label)
      view.addSubview(slider)
      view.addSubview(valueButton)
      label.snp.makeConstraints { make in
        make.leading.equalToSuperview().inset(Theme.current.sectionContentMargin)
        make.top.equalToSuperview().offset(1.5 + item.extraTopPadding)
      }
      slider.snp.makeConstraints { make in
        make.leading.trailing.equalToSuperview().inset(Theme.current.sectionContentMargin)
        make.bottom.equalToSuperview().inset(4)
        make.top.equalTo(label.snp.bottom).offset(1.5)
        make.height.equalTo(28)
      }
      valueButton.snp.makeConstraints { make in
        make.top.equalToSuperview().offset(item.extraTopPadding)
        make.bottom.equalTo(slider.snp.top)
        make.trailing.equalToSuperview().offset(-8)
      }
      slider.addAction(
        UIAction { _ in
          // Workaround a issue that setting slider value would trigger this action again.
          DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let value = item.rounded(slider.value)
            self.handleValueChange(value)
          }
        }, for: [.touchUpInside, .touchUpOutside])
      slider.addAction(
        UIAction { [weak self] _ in
          guard let self = self else { return }
          let value = item.rounded(slider.value)
          self.valueButton?.setTitle(
            SettingsSliderItem.defaultFormattedValue(value, type: item.type), for: .normal)
        }, for: [.valueChanged])
      valueButton.addAction(
        UIAction { [weak self] action in
          guard let self = self, slider.value != self.maxValue else { return }
          let value = item.rounded(slider.value)
          let incrementedValue = item.increment(value)
          self.handleValueChange(incrementedValue)
        }, for: .touchUpInside)
      return ([view], self)
    }

    public func updateViews(
      _ updatingItem: Item,
      with newItem: Item
    ) -> Item {
      var updatingItem = updatingItem
      if let slider = slider {
        if slider.minimumValue != newItem.minValue {
          slider.minimumValue = newItem.minValue
          updatingItem.minValue = newItem.minValue
        }
        if slider.maximumValue != newItem.maxValue {
          slider.maximumValue = newItem.maxValue
          updatingItem.maxValue = newItem.maxValue
          maxValue = newItem.maxValue
        }
        if slider.value != newItem.value {
          slider.setValue(newItem.value, animated: true)
        }
        if slider.isEnabled != newItem.isEnabled {
          slider.isEnabled = newItem.isEnabled
          updatingItem.isEnabled = newItem.isEnabled
        }
      }
      valueButton?.setTitle(
        SettingsSliderItem.defaultFormattedValue(newItem.value, type: newItem.type),
        for: .normal
      )
      updatingItem.value = newItem.value
      handleValueChange = newItem.handleValueChange
      if updatingItem.isHidden != newItem.isHidden {
        hideView = newItem.isHidden
        updatingItem.isHidden = newItem.isHidden
      }
      updatingItem.title = newItem.title
      titleLabel?.text = updatingItem.title
      return updatingItem
    }
  }

  public enum ValueType {
    case percent(_: Int = 0)
    case fractional(_: Int)
    case scale
  }

  public var isHidden: Bool = false
  public var isEnabled: Bool
  public var extraTopPadding: CGFloat
  public var viewModifying: any SettingsViewModifying {
    viewModifier
  }
  private var viewModifier: ViewModifier

  public var title: String?
  public var type: ValueType
  public struct CustomScale {
    public var rounded: ((Float) -> Float)
    public var increment: ((Float) -> Float)
    public init(rounded: @escaping (Float) -> Float, increment: @escaping (Float) -> Float) {
      self.rounded = rounded
      self.increment = increment
    }
  }
  public var customScale: CustomScale?
  public var value: Float
  public var minValue: Float
  public var maxValue: Float
  public var handleValueChange: (Float) -> Void

  public static func defaultFormattedValue(_ value: Float, type: ValueType) -> String {
    switch type {
    case .fractional(let fractionLength):
      return value.formatted(.number.precision(.fractionLength(fractionLength)))
    case .scale:
      return value.formatted(.number.precision(.fractionLength(0)))
    case .percent(let fractionLength):
      return value.formatted(.percent.precision(.fractionLength(fractionLength)))
    }
  }

  private static func defaultIncrementValue(_ value: Float, type: ValueType) -> Float {
    switch type {
    case .fractional(let fractionLength):
      let pow10 = pow(10, Float(fractionLength))
      return ((value + pow(0.1, Float(fractionLength))) * pow10).rounded() / pow10
    case .percent(let fractionLength):
      let pow10 = pow(10, Float(fractionLength))
      return ((value + 0.01 * pow(0.1, Float(fractionLength))) * (100 * pow10)).rounded()
        / (100 * pow10)
    case .scale:
      return (value + 64).rounded()
    }
  }

  public func increment(_ value: Float) -> Float {
    guard let customScale = customScale else {
      return Self.defaultIncrementValue(value, type: type)
    }
    return customScale.increment(value)
  }

  private static func defaultRoundedValue(_ value: Float, type: ValueType) -> Float {
    switch type {
    case .fractional(let fractionLength):
      let pow10 = pow(10, Float(fractionLength))
      return (value * pow10).rounded() / pow10
    case .percent(let fractionLength):
      let pow10 = pow(10, Float(fractionLength))
      return (value * (100 * pow10)).rounded() / (100 * pow10)
    case .scale:
      return (value / 64).rounded() * 64
    }
  }

  public func rounded(_ value: Float) -> Float {
    guard let customScale = customScale else {
      return Self.defaultRoundedValue(value, type: type)
    }
    return customScale.rounded(value)
  }

  public init(
    title: String? = nil, minValue: Float, maxValue: Float, value: Float,
    valueType: ValueType, customScale: CustomScale? = nil, isEnabled: Bool = true,
    extraTopPadding: CGFloat = 0, handleValueChange: @escaping (Float) -> Void
  ) {
    self.title = title
    self.type = valueType
    self.customScale = customScale
    self.minValue = minValue
    self.maxValue = maxValue
    self.value = value
    self.isEnabled = isEnabled
    self.extraTopPadding = extraTopPadding
    self.handleValueChange = handleValueChange
    self.viewModifier = ViewModifier(
      valueType: valueType, maxValue: maxValue, handleValueChange: handleValueChange)
  }

  public func isEquivalent(to other: any SettingsViewObservable) -> Bool {
    guard let other = other as? SettingsSliderItem else { return false }
    return value == other.value && isHidden == other.isHidden && isEnabled == other.isEnabled
      && title == other.title && minValue == other.minValue && maxValue == other.maxValue
  }
}
