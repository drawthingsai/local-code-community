import MultiSlider
//Created 11/13/23
import Style
import UIKit

public struct SettingsDoubleSliderItem: SettingsViewObservable {
  final class ViewModifier: SettingsViewModifying {
    public typealias Item = SettingsDoubleSliderItem
    // views
    public var view: UIView?
    public var titleLabel: UILabel?
    public var slider: MultiSlider?
    public var value0Button: UIButton?
    public var value1Button: UIButton?

    public var handleValueChange: (ClosedRange<Float>) -> Void
    public var maxValue: Float
    public var valueType: ValueType
    init(
      valueType: ValueType, maxValue: Float,
      handleValueChange: @escaping (ClosedRange<Float>) -> Void
    ) {
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
      let slider = MultiSlider(frame: .zero)
      slider.thumbImage = #imageLiteral(resourceName: "thumb-white-20")
      self.slider = slider
      slider.orientation = .horizontal
      slider.thumbTouchExpansionRadius = 4
      slider.trackWidth = 4
      slider.keepsDistanceBetweenThumbs = false
      slider.showsThumbImageShadow = false
      slider.tintColor = Theme.current.controlOnTintColor
      slider.leadingTrackColor =
        item.leadingTrackFilled
        ? Theme.current.controlOnTintColor : Theme.current.sliderMaximumTrackTintColor
      slider.trailingTrackColor = Theme.current.sliderMaximumTrackTintColor
      slider.minimumValue = CGFloat(item.minValue)
      slider.maximumValue = CGFloat(item.maxValue)
      slider.value = [CGFloat(item.value.lowerBound), CGFloat(item.value.upperBound)]
      slider.isEnabled = item.isEnabled
      let value0Button = UIButton(type: .custom)
      let value1Button = UIButton(type: .custom)
      self.value0Button = value0Button
      self.value1Button = value1Button
      var configuration = UIButton.Configuration.borderless()
      configuration.titleAlignment = .center
      configuration.baseForegroundColor = .senaryText
      configuration.contentInsets = NSDirectionalEdgeInsets(
        top: 0, leading: 4, bottom: 0, trailing: 4)
      configuration.title = SettingsDoubleSliderItem.defaultFormattedValue(
        item.value.lowerBound, type: item.type)
      value0Button.configuration = configuration
      switch item.format {
      case .range:
        configuration.title = SettingsDoubleSliderItem.defaultFormattedValue(
          item.value.upperBound, type: item.type)
      case .plus:
        configuration.title = SettingsDoubleSliderItem.defaultFormattedValue(
          item.value.upperBound - item.value.lowerBound, type: item.type)
      }
      value1Button.configuration = configuration
      FontMetrics.default.scaleFont(
        .monospacedDigitSystemFont(ofSize: 11, weight: .regular), bindTo: value0Button)
      FontMetrics.default.scaleFont(
        .monospacedDigitSystemFont(ofSize: 11, weight: .regular), bindTo: value1Button)
      let labelSeparator = UILabel(frame: .zero)
      switch item.format {
      case .range:
        labelSeparator.text = "–"
      case .plus:
        labelSeparator.text = "+"
      }
      labelSeparator.textColor = .senaryText
      FontMetrics.default.scaleFont(Theme.current.sectionDescriptionFont, bindTo: labelSeparator)
      view.addSubview(label)
      view.addSubview(slider)
      view.addSubview(value0Button)
      view.addSubview(labelSeparator)
      view.addSubview(value1Button)
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
      value1Button.snp.makeConstraints { make in
        make.top.equalToSuperview().offset(item.extraTopPadding)
        make.bottom.equalTo(slider.snp.top)
        make.trailing.equalToSuperview().offset(-8)
      }
      labelSeparator.snp.makeConstraints { make in
        make.centerY.equalTo(value1Button)
        make.trailing.equalTo(value1Button.snp.leading)
      }
      value0Button.snp.makeConstraints { make in
        make.top.equalToSuperview().offset(item.extraTopPadding)
        make.bottom.equalTo(slider.snp.top)
        make.trailing.equalTo(labelSeparator.snp.leading)
      }
      slider.addAction(
        UIAction { [weak self] action in
          guard let self = self else { return }
          let value0 = SettingsDoubleSliderItem.defaultRoundedValue(
            Float(slider.value[0]), type: item.type)
          let value1 = SettingsDoubleSliderItem.defaultRoundedValue(
            Float(slider.value[1]), type: item.type)
          self.handleValueChange(min(value0, value1)...max(value0, value1))
        }, for: [.touchUpInside, .touchUpOutside])
      let format = item.format
      slider.addAction(
        UIAction { [weak self] action in
          guard let self = self else { return }
          let value0 = SettingsDoubleSliderItem.defaultRoundedValue(
            Float(slider.value[0]), type: item.type)
          let value1 = SettingsDoubleSliderItem.defaultRoundedValue(
            Float(slider.value[1]), type: item.type)
          self.value0Button?.setTitle(
            SettingsDoubleSliderItem.defaultFormattedValue(min(value0, value1), type: item.type),
            for: .normal)
          switch format {
          case .range:
            self.value1Button?.setTitle(
              SettingsDoubleSliderItem.defaultFormattedValue(max(value0, value1), type: item.type),
              for: .normal)
          case .plus:
            self.value1Button?.setTitle(
              SettingsDoubleSliderItem.defaultFormattedValue(
                max(value0, value1) - min(value0, value1), type: item.type),
              for: .normal)
          }
        }, for: [.valueChanged])
      value0Button.addAction(
        UIAction { [weak self] action in
          guard let self = self, Float(slider.value[0]) < Float(slider.value[1]) else { return }
          let value0 = SettingsDoubleSliderItem.defaultRoundedValue(
            Float(slider.value[0]), type: item.type)
          let value1 = SettingsDoubleSliderItem.defaultRoundedValue(
            Float(slider.value[1]), type: item.type)
          let incrementedValue = min(
            SettingsDoubleSliderItem.defaultIncrementValue(value0, type: valueType), value1)
          self.handleValueChange(min(incrementedValue, value1)...max(incrementedValue, value1))
        }, for: .touchUpInside)
      value1Button.addAction(
        UIAction { [weak self] action in
          guard let self = self, Float(slider.value[1]) < maxValue else { return }
          let value0 = SettingsDoubleSliderItem.defaultRoundedValue(
            Float(slider.value[0]), type: item.type)
          let value1 = SettingsDoubleSliderItem.defaultRoundedValue(
            Float(slider.value[1]), type: item.type)
          let incrementedValue = min(
            SettingsDoubleSliderItem.defaultIncrementValue(value1, type: valueType), maxValue)
          self.handleValueChange(min(value0, incrementedValue)...max(value0, incrementedValue))
        }, for: .touchUpInside)
      return ([view], self)
    }

    public func updateViews(
      _ updatingItem: Item,
      with newItem: Item
    ) -> Item {
      var updatingItem = updatingItem
      if let slider = slider {
        if slider.minimumValue != CGFloat(newItem.minValue) {
          slider.minimumValue = CGFloat(newItem.minValue)
          updatingItem.minValue = newItem.minValue
        }
        if slider.maximumValue != CGFloat(newItem.maxValue) {
          slider.maximumValue = CGFloat(newItem.maxValue)
          updatingItem.maxValue = newItem.maxValue
        }
        let value0 = Float(slider.value[0])
        let value1 = Float(slider.value[1])
        if min(value0, value1)...max(value0, value1) != newItem.value {
          slider.value = [CGFloat(newItem.value.lowerBound), CGFloat(newItem.value.upperBound)]
        }
        if slider.isEnabled != newItem.isEnabled {
          slider.isEnabled = newItem.isEnabled
          updatingItem.isEnabled = newItem.isEnabled
        }
      }
      value0Button?.setTitle(
        SettingsDoubleSliderItem.defaultFormattedValue(
          newItem.value.lowerBound, type: newItem.type),
        for: .normal
      )
      switch newItem.format {
      case .range:
        value1Button?.setTitle(
          SettingsDoubleSliderItem.defaultFormattedValue(
            newItem.value.upperBound, type: newItem.type),
          for: .normal
        )
      case .plus:
        value1Button?.setTitle(
          SettingsDoubleSliderItem.defaultFormattedValue(
            newItem.value.upperBound - newItem.value.lowerBound, type: newItem.type),
          for: .normal
        )
      }
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
  public var value: ClosedRange<Float>
  public var minValue: Float
  public var maxValue: Float
  public var leadingTrackFilled: Bool
  public enum Format {
    case range
    case plus
  }
  public var format: Format
  public var handleValueChange: (ClosedRange<Float>) -> Void

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
    title: String? = nil, minValue: Float, maxValue: Float, value: ClosedRange<Float>,
    valueType: ValueType, customScale: CustomScale? = nil, isEnabled: Bool = true,
    leadingTrackFilled: Bool = false,
    format: Format = .range, extraTopPadding: CGFloat = 0,
    handleValueChange: @escaping (ClosedRange<Float>) -> Void
  ) {
    self.title = title
    self.type = valueType
    self.customScale = customScale
    self.minValue = minValue
    self.maxValue = maxValue
    self.value = value
    self.isEnabled = isEnabled
    self.leadingTrackFilled = leadingTrackFilled
    self.format = format
    self.extraTopPadding = extraTopPadding
    self.handleValueChange = handleValueChange
    self.viewModifier = ViewModifier(
      valueType: valueType, maxValue: maxValue, handleValueChange: handleValueChange)
  }

  public func isEquivalent(to other: any SettingsViewObservable) -> Bool {
    guard let other = other as? SettingsDoubleSliderItem else { return false }
    return value == other.value && isHidden == other.isHidden && isEnabled == other.isEnabled
      && title == other.title && minValue == other.minValue && maxValue == other.maxValue
      && leadingTrackFilled == other.leadingTrackFilled && format == other.format
  }
}
