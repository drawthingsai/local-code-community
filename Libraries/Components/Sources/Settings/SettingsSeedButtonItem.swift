//Created 11/13/23

import Dflat
import Localization
import Style
import UIKit

extension SettingsSeedButtonItem {
  final class ViewModifier: SettingsViewModifying {
    public typealias Item = SettingsSeedButtonItem
    // views
    public var view: UIView?
    public var seedButton: UIButton?
    public var seedButtonDropdown: UIButton?

    public var textField: UITextField?
    public var didChangeSeed: (SettingsSeedButtonItem.Selection) -> Void

    private var textFieldResponder: ObjCTextFieldResponder?

    public init(didChangeSeed: @escaping (SettingsSeedButtonItem.Selection) -> Void) {
      self.didChangeSeed = didChangeSeed
      self.textFieldResponder = ObjCTextFieldResponder(viewModifier: self)
    }

    public func makeViews(from item: Item) -> ([UIView], any SettingsViewModifying) {
      let view = UIView()
      self.view = view
      let seedButton = UIButton(type: .custom)
      self.seedButton = seedButton
      var seedConfiguration = UIButton.Configuration.bordered()
      switch item.value.selection {
      case .newSeedOnGeneration:
        seedConfiguration.title = "-1"
      case .seed(_):
        seedConfiguration.title = String(item.value.seed)
      }
      seedConfiguration.background.cornerRadius = 0
      seedConfiguration.contentInsets = NSDirectionalEdgeInsets(
        top: 0, leading: Theme.current.sectionContentMargin, bottom: 0, trailing: 2)
      seedConfiguration.baseBackgroundColor = Theme.current.primaryContentBackgroundColor
      seedConfiguration.baseForegroundColor = Theme.current.primaryContentColor
      seedButton.configuration = seedConfiguration
      seedButton.contentHorizontalAlignment = .leading
      seedButton.configuration = seedConfiguration
      FontMetrics.default.scaleFont(Theme.current.primaryContentFont, bindTo: seedButton)
      let seedButtonView = UIView(frame: .zero)
      seedButtonView.addSubview(seedButton)
      seedButton.snp.makeConstraints { make in
        make.edges.equalToSuperview()
      }
      seedButtonView.layer.cornerRadius = Theme.current.itemCornerRadius
      seedButtonView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
      seedButtonView.clipsToBounds = true
      let seedButtonDropdown = UIButton(type: .custom)
      self.seedButtonDropdown = seedButtonDropdown
      var dropdownConfiguration = UIButton.Configuration.filled()
      dropdownConfiguration.image = #imageLiteral(resourceName: "chevron-down-16")
        .withRenderingMode(
          .alwaysTemplate
        ).withTintColor(Theme.current.primaryContentColor)
      dropdownConfiguration.background.cornerRadius = 0
      dropdownConfiguration.baseBackgroundColor = Theme.current.primaryContentBackgroundColor
      dropdownConfiguration.baseForegroundColor = Theme.current.primaryContentColor
      seedButtonDropdown.configuration = dropdownConfiguration
      seedButtonDropdown.layer.cornerRadius = Theme.current.itemCornerRadius
      seedButtonDropdown.layer.maskedCorners = [.layerMaxXMaxYCorner, .layerMaxXMinYCorner]
      seedButtonDropdown.layer.masksToBounds = true
      seedButtonDropdown.showsMenuAsPrimaryAction = true
      FontMetrics.default.scaleFont(Theme.current.primaryContentFont, bindTo: seedButtonDropdown)
      let seedButtonDropdownView = UIView(frame: .zero)
      seedButtonDropdownView.addSubview(seedButtonDropdown)
      seedButtonDropdown.snp.makeConstraints { make in
        make.edges.equalToSuperview()
      }
      seedButtonDropdownView.layer.cornerRadius = Theme.current.itemCornerRadius
      seedButtonDropdownView.layer.maskedCorners = [.layerMaxXMaxYCorner, .layerMaxXMinYCorner]
      seedButtonDropdownView.clipsToBounds = true
      let textField = UITextField(frame: .zero)
      self.textField = textField
      textField.backgroundColor = Theme.current.primaryContentBackgroundColor
      textField.textAlignment = .left
      textField.textColor = Theme.current.primaryContentColor
      textField.layer.cornerRadius = Theme.current.itemCornerRadius
      FontMetrics.default.scaleFont(Theme.current.primaryContentFont, bindTo: textField) {
        $0.font = $1
      }
      textField.returnKeyType = .done
      textField.keyboardType = .numberPad
      // TextField with numberPad doesn't have a done button. Creating one.
      if item.isDoneEnabled {
        let doneToolbar: UIToolbar = UIToolbar(frame: .zero)
        doneToolbar.barStyle = UIBarStyle.default
        let flexSpace = UIBarButtonItem(
          barButtonSystemItem: UIBarButtonItem.SystemItem.flexibleSpace, target: nil, action: nil)
        let done: UIBarButtonItem = UIBarButtonItem(
          title: LocalizedString.forKey("done"), style: UIBarButtonItem.Style.done,
          target: textFieldResponder, action: #selector(ObjCTextFieldResponder.tapDone))
        doneToolbar.items = [flexSpace, done]
        doneToolbar.sizeToFit()
        textField.inputAccessoryView = doneToolbar
      }
      let divider = UIView()
      divider.backgroundColor = Theme.current.buttonDividerColor
      divider.isUserInteractionEnabled = false
      view.addSubview(textField)
      view.addSubview(seedButtonView)
      view.addSubview(seedButtonDropdownView)
      view.addSubview(divider)
      seedButtonView.snp.makeConstraints { make in
        make.top.equalToSuperview()
        make.height.equalTo(Theme.current.buttonHeight)
        make.trailing.equalTo(seedButtonDropdownView.snp.leading)
        make.leading.equalToSuperview()
      }
      seedButtonDropdownView.snp.makeConstraints { make in
        make.top.bottom.equalToSuperview()
        make.trailing.equalToSuperview()
        make.size.equalTo(Theme.current.buttonHeight)
      }
      divider.snp.makeConstraints { make in
        make.bottom.top.equalToSuperview()
        make.width.equalTo(1)
        make.trailing.equalTo(seedButtonView.snp.trailing)
      }
      textField.snp.makeConstraints { make in
        make.top.bottom.equalTo(seedButtonView)
        make.leading.trailing.equalTo(seedButtonView).inset(Theme.current.sectionContentMargin)
      }
      addSeedButtonAction()
      makeSeedUI(value: item.value, newSeedOnGenerationEnabled: item.newSeedOnGenerationEnabled)
      return ([view], self)
    }

    public func updateViews(
      _ updatingItem: Item,
      with newItem: Item
    ) -> Item {
      var updatingItem = updatingItem
      updatingItem.value = newItem.value
      updatingItem.newSeedOnGenerationEnabled = newItem.newSeedOnGenerationEnabled
      makeSeedUI(
        value: updatingItem.value,
        newSeedOnGenerationEnabled: updatingItem.newSeedOnGenerationEnabled)
      if updatingItem.isHidden != newItem.isHidden {
        hideView = newItem.isHidden
        updatingItem.isHidden = newItem.isHidden
      }
      if updatingItem.isDoneEnabled != newItem.isDoneEnabled {
        updatingItem.isDoneEnabled = newItem.isDoneEnabled
        if newItem.isDoneEnabled {
          let doneToolbar: UIToolbar = UIToolbar(frame: .zero)
          doneToolbar.barStyle = UIBarStyle.default
          let flexSpace = UIBarButtonItem(
            barButtonSystemItem: UIBarButtonItem.SystemItem.flexibleSpace, target: nil, action: nil)
          let done: UIBarButtonItem = UIBarButtonItem(
            title: LocalizedString.forKey("done"), style: UIBarButtonItem.Style.done,
            target: textFieldResponder, action: #selector(ObjCTextFieldResponder.tapDone))
          doneToolbar.items = [flexSpace, done]
          doneToolbar.sizeToFit()
          textField?.inputAccessoryView = doneToolbar
        } else {
          textField?.inputAccessoryView = nil
        }
      }
      return updatingItem
    }
  }
}

public struct SettingsSeedButtonItem: SettingsViewObservable {
  public enum Selection: Equatable {
    case newSeedOnGeneration
    case seed(UInt32)
  }

  public struct Complex: Equatable {
    public var selection: Selection
    public var seed: UInt32
    public var history: [UInt32]?
    public init(selection: Selection, seed: UInt32, history: [UInt32]? = nil) {
      self.selection = selection
      self.seed = seed
      self.history = history
    }
  }

  public var isHidden: Bool = false
  public var isEnabled: Bool = true
  public var value: Complex
  public var isDoneEnabled: Bool
  public var newSeedOnGenerationEnabled: Bool
  public private(set) var viewModifying: any SettingsViewModifying
  public init(
    value: Complex,
    isDoneEnabled: Bool,
    newSeedOnGenerationEnabled: Bool = true,
    didChangeSeed: @escaping (Selection) -> Void
  ) {
    self.value = value
    self.isDoneEnabled = isDoneEnabled
    self.newSeedOnGenerationEnabled = newSeedOnGenerationEnabled
    self.viewModifying = ViewModifier(didChangeSeed: didChangeSeed)
  }

  public func isEquivalent(to other: any SettingsViewObservable) -> Bool {
    guard let other = other as? SettingsSeedButtonItem else { return false }
    return value == other.value && isDoneEnabled == other.isDoneEnabled
      && newSeedOnGenerationEnabled == other.newSeedOnGenerationEnabled
      && isHidden == other.isHidden && isEnabled == other.isEnabled
  }

  public static func randomDice() -> UIImage {
    switch Int.random(in: 0..<6) {
    case 0:
      return #imageLiteral(resourceName: "dice-one")
    case 1:
      return #imageLiteral(resourceName: "dice-two")
    case 2:
      return #imageLiteral(resourceName: "dice-three")
    case 3:
      return #imageLiteral(resourceName: "dice-four")
    case 4:
      return #imageLiteral(resourceName: "dice-five")
    case 5:
      return #imageLiteral(resourceName: "dice-six")
    default:
      fatalError()
    }
  }
}

extension SettingsSeedButtonItem.ViewModifier {
  private func addSeedButtonAction() {
    seedButton?.addAction(
      UIAction { [weak self] _ in
        guard let self = self else { return }
        self.didChangeSeed(.seed(UInt32.random(in: UInt32.min...UInt32.max)))
      }, for: .touchUpInside)
  }
  private func makeSeedUI(value: SettingsSeedButtonItem.Complex, newSeedOnGenerationEnabled: Bool) {
    var actions = [UIAction]()
    if let seedHistories = value.history {
      for seed in seedHistories {
        actions.append(
          UIAction(
            title: String(seed),
            state: value.seed == seed ? .on : .off
          ) { [weak self] _ in
            guard let self = self else { return }
            didChangeSeed(.seed(seed))
          })
      }
    }
    actions.append(
      UIAction(
        title: LocalizedString.forKey("enter_seed")
      ) { [weak self] _ in
        guard let self = self else { return }
        self.pressSeed()
      })
    actions.append(
      UIAction(
        title: LocalizedString.forKey("random_seed")
      ) { [weak self] _ in
        guard let self = self else { return }
        self.didChangeSeed(.seed(UInt32.random(in: UInt32.min...UInt32.max)))
      })
    if newSeedOnGenerationEnabled {
      #if targetEnvironment(macCatalyst)
        actions.append(
          UIAction(
            title: LocalizedString.forKey("new_seed_on_generation") + " 🎲",
            state: value.selection == .newSeedOnGeneration ? .on : .off
          ) { [weak self] _ in
            guard let self = self else { return }
            self.didChangeSeed(.newSeedOnGeneration)
          })
      #else
        actions.append(
          UIAction(
            title: LocalizedString.forKey("new_seed_on_generation"),
            image: SettingsSeedButtonItem.randomDice().withRenderingMode(.alwaysTemplate),
            state: value.selection == .newSeedOnGeneration ? .on : .off
          ) { [weak self] _ in
            guard let self = self else { return }
            self.didChangeSeed(.newSeedOnGeneration)
          })
      #endif
    }
    seedButton?.menu = UIMenu(children: actions)
    seedButtonDropdown?.menu = UIMenu(children: actions)
    switch value.selection {
    case .newSeedOnGeneration:
      seedButtonDropdown?.configuration?.image = SettingsSeedButtonItem.randomDice()
        .withRenderingMode(
          .alwaysTemplate
        ).withTintColor(Theme.current.primaryContentColor)
      seedButtonDropdown?.configuration?.contentInsets = NSDirectionalEdgeInsets(
        top: 0, leading: 0, bottom: 0, trailing: 0)
      seedButton?.configuration?.title = "-1"
      seedButton?.setTitle("-1", for: .normal)
      seedButton?.showsMenuAsPrimaryAction = true
    case .seed(let seed):
      seedButtonDropdown?.configuration?.image = #imageLiteral(resourceName: "chevron-down-16")
        .withRenderingMode(
          .alwaysTemplate
        ).withTintColor(Theme.current.primaryContentColor)
      seedButtonDropdown?.configuration?.contentInsets = NSDirectionalEdgeInsets(
        top: 0, leading: 0, bottom: 0, trailing: 0)
      seedButton?.configuration?.title = "\(seed)"
      seedButton?.setTitle("\(seed)", for: .normal)
      seedButton?.showsMenuAsPrimaryAction = false
    }
  }

  private func pressSeed() {
    guard let textField = textField else { return }
    textField.delegate = textFieldResponder
    textField.text = seedButton?.currentTitle
    textField.superview?.bringSubviewToFront(textField)
    textField.becomeFirstResponder()
  }
  private final class ObjCTextFieldResponder: NSObject, UITextFieldDelegate {
    weak var viewModifier: SettingsSeedButtonItem.ViewModifier? = nil
    init(viewModifier: SettingsSeedButtonItem.ViewModifier) {
      self.viewModifier = viewModifier
    }
    @objc func tapDone() {
      guard let viewModifier = viewModifier else { return }
      viewModifier.textField?.endEditing(true)
    }
    func textFieldDidBeginEditing(_ textField: UITextField) {
      textField.selectedTextRange = textField.textRange(
        from: textField.beginningOfDocument, to: textField.endOfDocument)
    }
    func textFieldDidEndEditing(_ textField: UITextField, reason: UITextField.DidEndEditingReason) {
      guard let viewModifier = viewModifier else { return }
      textField.superview?.sendSubviewToBack(textField)
      if reason == .committed {
        if textField.text != viewModifier.seedButton?.currentTitle {
          guard let seedText = textField.text, let seed = UInt64(seedText.prefix(20))
          else {
            if textField.text == "-1" {
              viewModifier.didChangeSeed(.newSeedOnGeneration)
            }
            return
          }
          viewModifier.didChangeSeed(.seed(UInt32(seed & 0xffff_ffff)))
        }
      }
    }
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
      textField.endEditing(true)
      return false
    }
  }
}
