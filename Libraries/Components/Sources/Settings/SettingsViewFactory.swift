//Created 12/5/23
import Localization
import Style
import UIKit

public enum SettingsViewFactory {
  //make a title view with left and right image
  public static func makeImageTitleInfoView(leadingImage: UIImage?, title: String) -> (
    titleView: UIView, leadingImageView: UIImageView, titleLabel: UILabel, iconView: UIImageView
  ) {
    let (titleView, titleLabel, infoIcon) = makeTitleInfoView(title: title)
    let leadingImageView = UIImageView(
      image: leadingImage?.withTintColor(Theme.current.sectionIconColor))
    titleView.addSubview(leadingImageView)
    leadingImageView.isUserInteractionEnabled = false
    leadingImageView.contentMode = .scaleAspectFit
    leadingImageView.snp.makeConstraints { make in
      make.leading.equalToSuperview().offset(Theme.current.sectionTitleMargin)
      make.centerY.equalToSuperview()
      make.size.equalTo(16)
    }
    titleLabel.snp.remakeConstraints { make in
      make.leading.equalTo(leadingImageView.snp.trailing).offset(4)
      make.trailing.equalTo(infoIcon.snp.leading).offset(-4)
      make.centerY.equalToSuperview()
    }
    return (titleView, leadingImageView, titleLabel, infoIcon)
  }
  // make a title view with icon
  public static func makeTitleInfoView(title: String) -> (
    titleView: UIView, titleLabel: UILabel, iconView: UIImageView
  ) {
    let (titleView, titleLabel) = makeTitleView(title: title)
    let infoIcon = UIImageView(
      image: UIImage(imageLiteralResourceName: "info-16").withTintColor(
        Theme.current.sectionIconColor),
      highlightedImage: UIImage(imageLiteralResourceName: "info-filled-16").withTintColor(
        Theme.current.sectionIconColor))
    titleView.addSubview(infoIcon)
    infoIcon.snp.makeConstraints { make in
      make.centerY.equalTo(titleLabel)
      make.trailing.equalToSuperview().offset(-Theme.current.sectionTitleMargin)
      make.size.equalTo(16)
    }
    return (titleView, titleLabel, infoIcon)
  }

  // make title view just by itself
  public static func makeTitleView(title: String) -> (titleView: UIView, titleLabel: UILabel) {
    let titleView = UIView()
    let titleLabel = UILabel(frame: .zero)
    titleLabel.text = title
    titleLabel.textColor = Theme.current.sectionTitleColor
    titleLabel.lineBreakMode = .byTruncatingMiddle
    titleLabel.numberOfLines = 1
    FontMetrics.default.scaleFont(Theme.current.sectionTitleFont, bindTo: titleLabel)
    titleView.addSubview(titleLabel)
    titleLabel.snp.makeConstraints { make in
      make.centerY.equalToSuperview()
      make.top.bottom.equalToSuperview().priority(.high)
      make.leading.equalToSuperview().inset(Theme.current.sectionTitleMargin)
    }
    return (titleView, titleLabel)
  }

  public static func makeDividerView() -> UIView {
    let divider = UIView()
    divider.backgroundColor = Theme.current.itemBorderColor
    divider.isUserInteractionEnabled = false
    return divider
  }

  public static func makeSectionStackView(individualSectionStyle: Bool = true) -> (
    borderView: UIView, stackView: UIStackView
  ) {
    let containerView = BorderView.defaultBorderView(
      cornerRadius: Theme.current.sectionBorderRadius)
    containerView.translatesAutoresizingMaskIntoConstraints = false
    containerView.layer.masksToBounds = false
    let shadowView = PassThroughView()
    shadowView.layer.cornerRadius = Theme.current.sectionBorderRadius
    shadowView.clipsToBounds = false
    shadowView.backgroundColor = .secondaryBackground
    shadowView.layer.shadowColor = UIColor.black.cgColor
    shadowView.layer.shadowOpacity = 0.04
    shadowView.layer.shadowOffset = CGSize(width: 0, height: 2)
    shadowView.layer.shadowRadius = 4
    shadowView.layer.masksToBounds = false
    let stackView = UIStackView()
    stackView.layer.cornerRadius = Theme.current.sectionBorderRadius
    stackView.backgroundColor = .secondaryBackground
    stackView.axis = .vertical
    stackView.distribution = .equalSpacing
    stackView.alignment = .fill
    stackView.spacing = Theme.current.stackViewItemSpacing

    containerView.addSubview(shadowView)
    containerView.addSubview(stackView)
    shadowView.snp.makeConstraints { make in
      make.edges.equalToSuperview()
    }
    if individualSectionStyle {
      containerView.borderColor = Theme.current.sectionBorderColor
      containerView.layer.borderWidth = Theme.current.sectionBorderWidth
      stackView.snp.makeConstraints { make in
        make.edges.equalToSuperview().inset(Theme.current.sectionLayoutMargin)
      }
    } else {
      stackView.snp.makeConstraints { make in
        make.edges.equalToSuperview()
      }
      shadowView.isHidden = true
      containerView.layer.borderWidth = 0
    }
    return (borderView: containerView, stackView: stackView)
  }

  public static func localDeviceIconName(userInterfaceIdiom: UIUserInterfaceIdiom) -> String {
    #if os(macOS) || (os(iOS) && targetEnvironment(macCatalyst))
      return "laptop-filled"
    #else
      if userInterfaceIdiom == .phone {
        return "phone-filled"
      } else {
        return "tablet-filled"
      }
    #endif
  }

  public static func makeDropdownButton(
    alternativeImage: UIImage? = nil, titleLineBreakMode: NSLineBreakMode = .byTruncatingTail,
    onImageViewCreated: ((UIImageView) -> Void)? = nil
  ) -> UIButton {
    let buttonImage: UIImage =
      alternativeImage
      ?? #imageLiteral(resourceName: "chevron-down-16")
      .withRenderingMode(.alwaysTemplate)
    let button = UIButton(type: .custom)
    button.layer.cornerRadius = Theme.current.itemCornerRadius
    var configuration = UIButton.Configuration.bordered()
    let buttonImageView = UIImageView(image: buttonImage)
    onImageViewCreated?(buttonImageView)
    buttonImageView.tintColor = Theme.current.primaryContentColor
    buttonImageView.contentMode = .center
    buttonImageView.isUserInteractionEnabled = false
    configuration.titleAlignment = .leading
    configuration.contentInsets = NSDirectionalEdgeInsets(
      top: 0, leading: 12, bottom: 0, trailing: 40)
    configuration.background.cornerRadius = Theme.current.itemCornerRadius
    configuration.baseBackgroundColor = Theme.current.primaryContentBackgroundColor
    configuration.baseForegroundColor = Theme.current.primaryContentColor
    configuration.titleLineBreakMode = titleLineBreakMode
    button.configurationUpdateHandler = { [weak buttonImageView] button in
      guard let buttonImageView = buttonImageView, let titleLabel = button.titleLabel else {
        return
      }
      // Push to the end of the run loop so we can get the text color of the title label properly.
      DispatchQueue.main.async {
        buttonImageView.tintColor = titleLabel.textColor
      }
    }
    button.contentHorizontalAlignment = .leading
    button.tintColor = .systemBackground
    button.configuration = configuration
    FontMetrics.default.scaleFont(Theme.current.primaryContentFont, bindTo: button)
    button.addSubview(buttonImageView)
    buttonImageView.snp.makeConstraints { make in
      make.trailing.equalToSuperview().inset(Theme.current.sectionContentMargin)
      make.centerY.equalToSuperview()
      make.size.equalTo(16)
    }
    return button
  }

  public static func makeIncompatibleView() -> UIView {
    let incompatibleView = UIView()
    incompatibleView.snp.makeConstraints { make in
      make.height.equalTo(24)
    }
    let incompatibleLabel = UILabel()
    incompatibleLabel.text = LocalizedString.forKey("incompatible")
    incompatibleLabel.textColor = .warningText
    FontMetrics.default.scaleFont(
      Theme.current.secondaryContentFont, bindTo: incompatibleLabel)
    let incompatibleIcon = UIImageView(
      image: #imageLiteral(resourceName: "warning-triangle").withTintColor(.warningText))
    incompatibleView.addSubview(incompatibleLabel)
    incompatibleView.addSubview(incompatibleIcon)
    incompatibleIcon.snp.makeConstraints { make in
      make.leading.equalToSuperview().offset(Theme.current.sectionContentMargin)
      make.centerY.equalToSuperview()
      make.size.equalTo(16)
    }
    incompatibleLabel.snp.makeConstraints { make in
      make.leading.equalTo(incompatibleIcon.snp.trailing).offset(6)
      make.centerY.equalToSuperview()
    }
    return incompatibleView
  }

  public static func setWarningView(
    isIncompatible: Bool, animated: Bool, incompatibleView: UIView?, backgroundView: UIView?,
    stackView: UIView?
  ) {
    guard let incompatibleView, let backgroundView, let stackView else { return }
    guard incompatibleView.isHidden != !isIncompatible else { return }
    let updateBlock = {
      if isIncompatible {
        backgroundView.layer.borderColor = UIColor.warningBorder.cgColor
        if let button = backgroundView as? UIButton {
          button.configuration?.baseBackgroundColor = .warningBackground
        } else {
          backgroundView.backgroundColor = .warningBackground
        }
        backgroundView.layer.borderWidth = 1
      } else {
        backgroundView.layer.borderWidth = 0
        if let button = backgroundView as? UIButton {
          button.configuration?.baseBackgroundColor = Theme.current.primaryContentBackgroundColor
        } else {
          backgroundView.backgroundColor = Theme.current.primaryContentBackgroundColor
        }
      }
      incompatibleView.alpha = isIncompatible ? 1 : 0
      incompatibleView.isHidden = !isIncompatible
      stackView.superview?.layoutIfNeeded()
    }
    if animated {
      UIView.animate(
        withDuration: 0.2, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState]
      ) {
        updateBlock()
      }
    } else {
      updateBlock()
    }
  }

  public static func makeDigestView(title: String, image: UIImage) -> UIView {
    let view = UIView()
    let label = UILabel()
    label.text = title
    label.textColor = .quinaryText
    FontMetrics.default.scaleFont(.systemFont(ofSize: 12), bindTo: label)
    let imageView = UIImageView(image: image.withTintColor(.quinaryText))
    view.addSubview(imageView)
    view.addSubview(label)
    imageView.snp.makeConstraints { make in
      make.leading.top.bottom.equalToSuperview()
      make.size.equalTo(16)
    }
    label.snp.makeConstraints { make in
      make.leading.equalTo(imageView.snp.trailing).offset(4)
      make.trailing.equalToSuperview()
      make.centerY.equalToSuperview()
    }
    return view
  }
}

extension UIImage {
  public static var imageRectangle16: UIImage {
    UIImage(imageLiteralResourceName: "image-rectangle-16")
  }

  public static var model16: UIImage {
    UIImage(imageLiteralResourceName: "dt-model-16")
  }

  public static var lora16: UIImage {
    UIImage(imageLiteralResourceName: "lora-16")
  }

  public static var control16: UIImage {
    UIImage(imageLiteralResourceName: "control-16")
  }

  public static var presetH16: UIImage {
    UIImage(imageLiteralResourceName: "presets-h-16")
  }

  public static var checkCircle16: UIImage {
    UIImage(imageLiteralResourceName: "check-circle-16")
  }

  public static var toggleRight16: UIImage {
    UIImage(imageLiteralResourceName: "toggle-right-16")
  }
}
