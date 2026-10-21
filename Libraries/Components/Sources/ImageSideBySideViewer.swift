//  Created by weiyan on 5/24/24.
//

import Localization
import NukeUI
import SnapKit
import Style
import UIKit

@MainActor
public final class ImageSideBySideViewer {
  public var view: UIView { internalView }
  public var isAccessoriesHidden: Bool {
    set { internalView.isAccessoriesHidden = newValue }
    get { internalView.isAccessoriesHidden }
  }
  private let internalView: View
  private let bouncyController: BouncyController

  private lazy var panGestureRecognizer = {
    let panGestureRecognizer = UILongPressGestureRecognizer(
      target: self, action: #selector(pan(_:)))
    panGestureRecognizer.minimumPressDuration = 0
    return panGestureRecognizer
  }()

  public init(imageAspectRatio: CGSize) {
    internalView = View(frame: .zero, imageAspectRatio: imageAspectRatio)
    bouncyController = BouncyController(
      view: internalView.dividerIcon, views: [], scaleFactor: 0.9, usingSpringWithDamping: 10,
      initialSpringVelocity: 100, allowableMovement: .greatestFiniteMagnitude,
      touchDownAnimationDuration: 0.3, touchUpAnimationDuration: 0.4)
    internalView.dividerIcon.addGestureRecognizer(panGestureRecognizer)
  }

  public var backgroundColor: UIColor = .clear {
    didSet {
      internalView.firstView.backgroundColor = backgroundColor
      internalView.secondView.backgroundColor = backgroundColor
    }
  }

  public var imageUrls: (URL?, URL?) = (nil, nil) {
    didSet {
      internalView.firstImageView.url = imageUrls.0
      internalView.secondImageView.url = imageUrls.1
    }
  }
  @objc
  private func pan(_ gestureRecognizer: UIPanGestureRecognizer) {
    let point = gestureRecognizer.location(in: internalView)

    // Update slider position
    internalView.sliderPosition = min(max(point.x / internalView.bounds.width, 0), 1)

    switch gestureRecognizer.state {
    case .began, .changed:
      internalView.verticalDivider.snp.remakeConstraints { make in
        make.top.bottom.equalToSuperview()
        make.leading.equalToSuperview().offset(point.x)
        make.width.equalTo(2)
      }
    default:
      break
    }
  }
}

extension ImageSideBySideViewer {

  private final class View: UIView {

    let secondImageView: LazyImageView = {
      let lazyImageView = LazyImageView()
      lazyImageView.imageView.contentMode = .scaleAspectFill
      return lazyImageView
    }()

    let firstImageView: LazyImageView = {
      let lazyImageView = LazyImageView()
      lazyImageView.imageView.contentMode = .scaleAspectFill
      return lazyImageView
    }()

    let secondView: UIView = {
      let view = UIView(frame: .zero)
      view.clipsToBounds = true
      return view
    }()

    let firstView: UIView = {
      let view = UIView(frame: .zero)
      view.clipsToBounds = true
      return view
    }()

    var sliderPosition: CGFloat = 0.5 {
      didSet {
        firstView.snp.remakeConstraints { make in
          make.top.bottom.leading.equalToSuperview()
          make.width.equalToSuperview().multipliedBy(sliderPosition)
        }
      }
    }

    private let leftLabel: UILabel = {
      let label = UILabel(frame: .zero)
      label.text = LocalizedString.forKey("before")
      FontMetrics.default.scaleFont(.systemFont(ofSize: 11, weight: .semibold), bindTo: label)
      label.textColor = .quinaryText
      label.shadowOffset = CGSize(width: 0, height: 2)
      label.shadowColor = .black.withAlphaComponent(0.12)
      label.layer.shadowRadius = 4
      return label
    }()

    private let rightLabel: UILabel = {
      let label = UILabel(frame: .zero)
      label.text = LocalizedString.forKey("after")
      FontMetrics.default.scaleFont(.systemFont(ofSize: 11, weight: .semibold), bindTo: label)
      label.textColor = .quinaryText
      label.shadowOffset = CGSize(width: 0, height: 2)
      label.shadowColor = .black.withAlphaComponent(0.12)
      label.layer.shadowRadius = 4
      return label
    }()

    let verticalDivider: UIView = {
      let divider = SettingsViewFactory.makeDividerView()
      divider.backgroundColor = .quinaryBorder
      return divider
    }()

    let dividerIcon: UIImageView = {
      let imageView = UIImageView()
      imageView.contentMode = .center
      imageView.image = #imageLiteral(resourceName: "diamond-grip").withTintColor(.quinaryText)
      imageView.layer.cornerRadius = 16
      imageView.backgroundColor = .primaryShadow
      imageView.clipsToBounds = true
      imageView.isUserInteractionEnabled = true
      return imageView
    }()

    private let leftLabelBackgroundShadow: UIVisualEffectView = {
      let view = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
      view.layer.cornerRadius = 12
      view.clipsToBounds = true
      view.alpha = 0.8
      return view
    }()

    private let rightLabelBackgroundShadow: UIVisualEffectView = {
      let view = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
      view.layer.cornerRadius = 12
      view.clipsToBounds = true
      view.alpha = 0.8
      return view
    }()

    public var isAccessoriesHidden: Bool {
      didSet {
        if isAccessoriesHidden {
          dividerIcon.alpha = 0
          leftLabel.alpha = 0
          rightLabel.alpha = 0
          leftLabelBackgroundShadow.alpha = 0
          rightLabelBackgroundShadow.alpha = 0
        } else {
          dividerIcon.alpha = 1
          leftLabel.alpha = 1
          rightLabel.alpha = 1
          leftLabelBackgroundShadow.alpha = 1
          rightLabelBackgroundShadow.alpha = 1
        }
      }
    }

    public init(frame: CGRect, imageAspectRatio: CGSize) {
      isAccessoriesHidden = false
      super.init(frame: frame)
      addSubview(secondView)
      secondView.addSubview(secondImageView)
      addSubview(firstView)
      firstView.addSubview(firstImageView)
      addSubview(verticalDivider)
      addSubview(dividerIcon)
      addSubview(leftLabelBackgroundShadow)
      addSubview(rightLabelBackgroundShadow)
      addSubview(leftLabel)
      addSubview(rightLabel)

      firstView.snp.makeConstraints { make in
        make.top.bottom.leading.equalToSuperview()
        make.width.equalToSuperview().multipliedBy(sliderPosition)
      }

      secondView.snp.makeConstraints { make in
        make.edges.equalToSuperview()
      }

      if imageAspectRatio == .zero {
        firstImageView.snp.makeConstraints { make in
          make.edges.equalTo(secondView)
        }
        secondImageView.snp.makeConstraints { make in
          make.edges.equalToSuperview()
        }
      } else {
        // Matching width.
        firstImageView.snp.makeConstraints { make in
          make.leading.trailing.equalTo(secondView)
          make.height.equalTo(firstImageView.snp.width).multipliedBy(
            imageAspectRatio.height / imageAspectRatio.width)
          make.centerY.equalTo(secondView)
        }
        secondImageView.snp.makeConstraints { make in
          make.leading.trailing.equalToSuperview()
          make.height.equalTo(secondImageView.snp.width).multipliedBy(
            imageAspectRatio.height / imageAspectRatio.width)
          make.centerY.equalToSuperview()
        }
      }

      leftLabelBackgroundShadow.snp.makeConstraints { make in
        make.leading.equalToSuperview().inset(12)
        make.top.equalToSuperview({ $0.snp.topMargin }).inset(72)
      }

      leftLabel.snp.makeConstraints { make in
        make.leading.trailing.equalTo(leftLabelBackgroundShadow).inset(10)
        make.top.bottom.equalTo(leftLabelBackgroundShadow).inset(6)
      }

      rightLabelBackgroundShadow.snp.makeConstraints { make in
        make.trailing.equalToSuperview().inset(12)
        make.top.equalToSuperview({ $0.snp.topMargin }).inset(72)
      }
      rightLabel.snp.makeConstraints { make in
        make.leading.trailing.equalTo(rightLabelBackgroundShadow).inset(10)
        make.top.bottom.equalTo(rightLabelBackgroundShadow).inset(6)
      }

      verticalDivider.snp.makeConstraints { make in
        make.top.bottom.equalToSuperview()
        make.centerX.equalToSuperview()
        make.width.equalTo(1)
      }
      dividerIcon.snp.makeConstraints { make in
        make.size.equalTo(32)
        make.center.equalTo(verticalDivider.snp.center)
      }
    }

    required init?(coder: NSCoder) {
      fatalError()
    }
  }
}
