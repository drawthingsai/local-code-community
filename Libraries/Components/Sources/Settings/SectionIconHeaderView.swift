import Dflat
import Localization
import Style
import UIKit

public final class SectionIconHeaderView: UICollectionReusableView {
  public static let reusableIdentifier = "SectionIconHeaderView"
  public struct ViewModel: Hashable & Equatable {
    public var imageName: String?
    public var title: String
    public var detail: String
    public var lookUpKey: String
    public var backgroundColor: UIColor?
    public init(
      imageName: String? = nil, title: String, detail: String, lookUpKey: String,
      backgroundColor: UIColor? = nil
    ) {
      self.imageName = imageName
      self.title = title
      self.detail = detail
      self.lookUpKey = lookUpKey
      self.backgroundColor = backgroundColor
    }
  }

  private lazy var stackView: UIStackView = {
    let stackView = UIStackView()
    stackView.axis = .vertical
    stackView.distribution = .equalSpacing
    stackView.alignment = .fill
    stackView.spacing = Theme.current.stackViewItemSpacing
    return stackView
  }()
  private lazy var detailView: UIView = {
    let detailView = UIView()
    detailView.addSubview(detailLabel)
    detailLabel.snp.makeConstraints { make in
      make.leading.trailing.equalToSuperview().inset(Theme.current.sectionTitleMargin)
      make.top.equalToSuperview()
      make.bottom.equalToSuperview().inset(8)
    }
    return detailView
  }()
  private lazy var detailLabel: UILabel = {
    let label = UILabel(frame: .zero)
    FontMetrics.default.scaleFont(Theme.current.sectionDescriptionFont, bindTo: label)
    label.textColor = Theme.current.sectionDescriptionColor
    label.lineBreakMode = .byWordWrapping
    label.numberOfLines = 0
    return label
  }()
  private var toolTipController: ToolTipAndDetailAppearanceController? = nil
  private let titleView: UIView
  private lazy var iconView: UIImageView = {
    UIImageView(
      image: UIImage(imageLiteralResourceName: "info-16").withTintColor(
        Theme.current.sectionIconColor),
      highlightedImage: UIImage(imageLiteralResourceName: "info-filled-16").withTintColor(
        Theme.current.sectionIconColor))
  }()
  private lazy var titleLabel: UILabel = {
    let titleLabel = UILabel(frame: .zero)
    titleLabel.textColor = Theme.current.sectionTitleColor
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.numberOfLines = 1
    FontMetrics.default.scaleFont(Theme.current.sectionTitleFont, bindTo: titleLabel)
    return titleLabel
  }()
  private lazy var imageView: UIImageView = {
    let imageView = UIImageView(frame: .zero)
    imageView.isUserInteractionEnabled = false
    imageView.tintColor = Theme.current.sectionTitleColor
    imageView.contentMode = .center
    return imageView
  }()

  public var contentInsets: NSDirectionalEdgeInsets = NSDirectionalEdgeInsets(
    top: 8, leading: 12, bottom: 8, trailing: 12)
  {
    didSet {
      if oldValue.top != contentInsets.top || oldValue.bottom != contentInsets.bottom {
        stackView.snp.remakeConstraints { make in
          make.top.equalToSuperview().offset(contentInsets.top)
          make.trailing.leading.equalToSuperview()
          make.bottom.equalToSuperview().offset(-oldValue.bottom)
        }
      }
      if oldValue.leading != contentInsets.leading {
        imageView.snp.remakeConstraints { make in
          make.centerY.equalToSuperview()
          make.width.height.equalTo(16)
          make.leading.equalToSuperview().offset(contentInsets.leading)
        }
      }
      if oldValue.trailing != contentInsets.trailing {
        iconView.snp.makeConstraints { make in
          make.centerY.equalToSuperview()
          make.width.height.equalTo(16)
          make.trailing.equalToSuperview().offset(-contentInsets.trailing)
        }
      }
    }
  }

  public override init(frame: CGRect) {
    titleView = UIView(frame: .zero)
    super.init(frame: frame)
    backgroundColor = Theme.current.itemBackgroundColor
    addSubview(stackView)
    stackView.snp.makeConstraints { make in
      make.top.equalToSuperview().offset(Theme.current.stackViewItemSpacing)
      make.trailing.leading.equalToSuperview()
      make.bottom.equalToSuperview().offset(-8).priority(.medium)
    }
    titleView.addSubview(imageView)
    imageView.snp.makeConstraints { make in
      make.centerY.equalToSuperview()
      make.width.height.equalTo(16)
      make.leading.equalToSuperview().inset(Theme.current.sectionTitleMargin)
    }
    titleView.addSubview(titleLabel)
    titleLabel.snp.makeConstraints { make in
      make.top.equalToSuperview()
      make.bottom.equalToSuperview()
      make.leading.equalTo(imageView.snp.trailing).offset(4)
      make.trailing.equalToSuperview().inset(Theme.current.sectionTitleMargin + 16 + 4)
    }
    titleView.addSubview(iconView)
    iconView.snp.makeConstraints { make in
      make.centerY.equalToSuperview()
      make.width.height.equalTo(16)
      make.trailing.equalToSuperview().inset(Theme.current.sectionTitleMargin)
    }
    stackView.addArrangedSubview(titleView)
    titleView.snp.makeConstraints { make in
      make.leading.trailing.equalToSuperview()
    }
    stackView.addArrangedSubview(detailView)
  }
  required init?(coder: NSCoder) {
    fatalError()
  }

  public func setViewModel(
    _ viewModel: ViewModel, workspace: Workspace,
    invalidateLayout: @escaping () -> Void
  ) {
    titleLabel.text = viewModel.title
    detailLabel.text = viewModel.detail
    if let backgroundColor = viewModel.backgroundColor {
      self.backgroundColor = backgroundColor
    }
    imageView.image = UIImage(named: viewModel.imageName ?? "")?.withTintColor(
      Theme.current.sectionIconColor)
    let toolTipController = ToolTipAndDetailAppearanceController(
      titleView, detail: detailView, toolTip: viewModel.detail, lookUpKey: viewModel.lookUpKey,
      workspace: workspace, animateHidden: true)
    toolTipController.iconView = iconView
    toolTipController.animateAlongIsHiddenChange = { _ in
      invalidateLayout()
    }
    self.toolTipController = toolTipController
  }
}
