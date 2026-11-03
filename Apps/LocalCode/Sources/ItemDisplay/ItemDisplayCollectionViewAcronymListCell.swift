import SnapKit
import Style
import UIKit

protocol ItemDisplayCollectionViewAcronymListCellDelegate: AnyObject {
  func didTapTrash(itemIdentifier: ItemViewModel.ItemIdentifier)
}

final class ItemDisplayCollectionViewAcronymListCell: UICollectionViewCell {
  weak var delegate: ItemDisplayCollectionViewAcronymListCellDelegate? = nil
  /// Rows in the glass popover sit closer to their icon, end titles with an ellipsis, and ring
  /// the selection in a border color.
  var usesGlass = false {
    didSet {
      guard usesGlass != oldValue else { return }
      titleLabel.lineBreakMode = usesGlass ? .byTruncatingTail : .byTruncatingMiddle
      titleLeadingConstraint?.update(offset: usesGlass ? 10 : 12)
      setNeedsUpdateConfiguration()
    }
  }

  static var reusableIdentifier: String {
    "ItemDisplayCollectionViewAcronymListCell"
  }
  private let acronymImageView: UIImageView = {
    let imageView = UIImageView()
    imageView.contentMode = .scaleAspectFit
    imageView.tintColor = .senaryText
    imageView.clipsToBounds = true
    return imageView
  }()
  private let trashButton: UIButton = {
    let button = UIButton(type: .custom)
    var configuration = UIButton.Configuration.plain()
    configuration.image = #imageLiteral(resourceName: "trash-24").withTintColor(.senaryText)
    configuration.contentInsets = NSDirectionalEdgeInsets.zero
    button.configuration = configuration
    return button
  }()
  private let titleLabel: UILabel = {
    let label = UILabel()
    label.textAlignment = .left
    label.numberOfLines = 1
    label.lineBreakMode = .byTruncatingMiddle
    label.textColor = .primaryText
    FontMetrics.default.scaleFont(
      .systemFont(ofSize: 14, weight: .semibold), bindTo: label)
    return label
  }()
  private lazy var detailStack: UIStackView = {
    let stack = UIStackView()
    stack.axis = .vertical
    stack.spacing = 4
    stack.isHidden = true
    return stack
  }()
  private lazy var detailLabel: UILabel = {
    let label = UILabel()
    label.numberOfLines = 0
    label.textColor = .senaryText
    FontMetrics.default.scaleFont(.systemFont(ofSize: 12), bindTo: label)
    return label
  }()
  private lazy var captionLabel: UILabel = {
    let label = UILabel()
    label.numberOfLines = 1
    label.textColor = .septenaryText
    FontMetrics.default.scaleFont(.systemFont(ofSize: 12), bindTo: label)
    return label
  }()
  private let acronymImagePlaceholder: UIView = {
    let view = UIView()
    return view
  }()
  private let separatorView: UIView = {
    let view = UIView()
    view.backgroundColor = .tertiaryBorder
    view.isHidden = true
    return view
  }()
  private var itemIdentifier: ItemViewModel.ItemIdentifier = .empty
  private var placeholderTopConstraint: Constraint?
  private var titleLeadingConstraint: Constraint?
  private var imageSizeConstraint: Constraint?

  override init(frame: CGRect) {
    super.init(frame: frame)
    var backgroundConfiguration = UIBackgroundConfiguration.listPlainCell()
    backgroundConfiguration.backgroundColor = .clear
    self.backgroundConfiguration = backgroundConfiguration
    let backgroundView = UIView(frame: .zero)
    backgroundView.layer.cornerRadius = 10
    backgroundView.layer.borderWidth = 2.0
    contentView.addSubview(separatorView)
    contentView.addSubview(backgroundView)
    contentView.addSubview(titleLabel)
    contentView.addSubview(acronymImagePlaceholder)
    contentView.addSubview(detailStack)
    detailStack.addArrangedSubview(detailLabel)
    detailStack.addArrangedSubview(captionLabel)

    // The icon and its selection ring keep the compact row's size when details make the row taller.
    acronymImagePlaceholder.snp.makeConstraints { make in
      placeholderTopConstraint = make.top.equalToSuperview().offset(4).constraint
      make.leading.equalToSuperview().offset(4)
      make.size.equalTo(24)
    }
    // The separator sits in the group spacing that a row starting a group adds above its icon.
    separatorView.snp.makeConstraints { make in
      make.top.equalToSuperview().offset(6)
      make.leading.trailing.equalToSuperview().inset(12)
      make.height.equalTo(0.5)
    }
    backgroundView.snp.makeConstraints { make in
      make.edges.equalTo(acronymImagePlaceholder).inset(-4)
    }
    titleLabel.snp.makeConstraints { make in
      make.centerY.equalTo(acronymImagePlaceholder.snp.centerY)
      titleLeadingConstraint =
        make.leading.equalTo(acronymImagePlaceholder.snp.trailing).offset(12).constraint
      make.trailing.lessThanOrEqualToSuperview().offset(-4)
      make.height.equalTo(20)
    }
    detailStack.snp.makeConstraints { make in
      make.top.equalTo(titleLabel.snp.bottom).offset(Self.detailTopSpacing)
      make.leading.equalTo(titleLabel)
      make.trailing.equalToSuperview().offset(-4)
    }

    contentView.addSubview(acronymImageView)
    acronymImageView.snp.makeConstraints { make in
      make.center.equalTo(acronymImagePlaceholder.snp.center)
      imageSizeConstraint = make.height.width.equalTo(16).constraint
    }
    contentView.addSubview(trashButton)
    trashButton.snp.makeConstraints { make in
      make.centerY.equalTo(acronymImagePlaceholder)
      make.height.width.equalTo(24)
      make.trailing.equalToSuperview().offset(-4)
    }
    trashButton.isHidden = true

    self.configurationUpdateHandler = { cell, state in
      if state.isSelected || state.isHighlighted {
        let usesGlass = (cell as? ItemDisplayCollectionViewAcronymListCell)?.usesGlass == true
        backgroundView.layer.borderColor =
          (usesGlass ? UIColor.quaternaryBorder : UIColor.senaryText).cgColor
      } else {
        backgroundView.layer.borderColor = UIColor.clear.cgColor
      }
    }
    acronymImagePlaceholder.layer.cornerRadius = 6
    acronymImagePlaceholder.clipsToBounds = true
    let acronymToolTipInteraction = UIToolTipInteraction()
    acronymToolTipInteraction.delegate = self
    acronymImagePlaceholder.addInteraction(acronymToolTipInteraction)
    let titleToolTipInteraction = UIToolTipInteraction()
    titleToolTipInteraction.delegate = self
    titleLabel.addInteraction(titleToolTipInteraction)
    trashButton.addAction(
      UIAction { [weak self] _ in
        guard let self = self else { return }
        self.delegate?.didTapTrash(itemIdentifier: self.itemIdentifier)
      }, for: .touchUpInside)
  }

  required init?(coder aDecoder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func setViewModel(with viewModel: ItemAcronymViewModel, showsDetails: Bool) {
    acronymImageView.image = nil
    switch viewModel.title {
    case .title(let title):
      titleLabel.text = title
    case .attributed(let attributed):
      titleLabel.attributedText = attributed
    }
    itemIdentifier = viewModel.itemIdentifier
    trashButton.isHidden = !viewModel.canDelete
    acronymImagePlaceholder.backgroundColor = viewModel.backgroundColor
    acronymImageView.tintColor = viewModel.thumbnailTintColor ?? .senaryText
    imageSizeConstraint?.update(offset: viewModel.thumbnailSize)
    // Rebinding would otherwise add a handler each time the cell is reused.
    FontMetrics.default.clearBinding(to: titleLabel)
    FontMetrics.default.scaleFont(
      .systemFont(ofSize: 14, weight: viewModel.titleWeight), bindTo: titleLabel)
    separatorView.isHidden = !viewModel.startsGroup
    placeholderTopConstraint?.update(offset: 4 + (viewModel.startsGroup ? Self.groupSpacing : 0))
    detailStack.isHidden = !showsDetails || (viewModel.detail.isEmpty && viewModel.caption.isEmpty)
    detailLabel.attributedText = NSAttributedString(
      string: viewModel.detail,
      attributes: [.paragraphStyle: Self.detailParagraphStyle(font: detailLabel.font)])
    detailLabel.isHidden = viewModel.detail.isEmpty
    captionLabel.attributedText = NSAttributedString(
      string: viewModel.caption,
      attributes: [.paragraphStyle: Self.detailParagraphStyle(font: captionLabel.font)])
    captionLabel.isHidden = viewModel.caption.isEmpty

    switch viewModel.thumbnail {
    case .image(let image):
      acronymImageView.image = image
    case .acronymTitle(_):
      break
    case .systemName(let systemName):
      acronymImageView.image = UIImage(systemName: systemName)?.withTintColor(
        .label, renderingMode: .alwaysOriginal)
    case .imageLiteralResourceName(let imageLiteralResourceName):
      acronymImageView.image = UIImage(imageLiteralResourceName: imageLiteralResourceName)
        .withTintColor(.label)
    }

  }

  /// The space a row that starts a group adds above its icon, with the separator 6pt from its top.
  static let groupSpacing: CGFloat = 16.5

  // Measured from the design: the detail's first baseline sits 19pt below the title's, the caption's
  // 20pt below the detail's last one, and the row ends 8pt under the caption's baseline.
  private static let detailTopSpacing: CGFloat = 1
  private static let detailBottomSpacing: CGFloat = 5

  // Detail lines sit on a 16pt grid for the 12pt font, so lines are 4/3 of the font size.
  private static func detailParagraphStyle(font: UIFont) -> NSParagraphStyle {
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.minimumLineHeight = (font.pointSize * 4 / 3).rounded()
    paragraphStyle.maximumLineHeight = paragraphStyle.minimumLineHeight
    return paragraphStyle
  }

  /// The row height that fits the detail and caption under the title, or nil when the row has
  /// neither and keeps its compact height.
  static func detailedHeight(for viewModel: ItemAcronymViewModel, width: CGFloat) -> CGFloat? {
    guard !viewModel.detail.isEmpty || !viewModel.caption.isEmpty else { return nil }
    // Icon, its leading inset and gap, and the trailing inset, as laid out in init.
    let textWidth = width - 4 - 24 - 12 - 4
    let font = UIFont.systemFont(ofSize: 12 * FontMetrics.default.size.rawValue)
    let attributes: [NSAttributedString.Key: Any] = [
      .font: font, .paragraphStyle: detailParagraphStyle(font: font),
    ]
    let lineHeights = [viewModel.detail, viewModel.caption].filter { !$0.isEmpty }.map {
      ceil(
        NSAttributedString(string: $0, attributes: attributes).boundingRect(
          with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
          options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil
        ).height)
    }
    // The 20pt title is centered on the 24pt icon, which is 4pt from the top.
    let titleBottom: CGFloat = 4 + 12 + 10
    return titleBottom + detailTopSpacing + lineHeights.reduce(0, +)
      + CGFloat(lineHeights.count - 1) * 4 + detailBottomSpacing
  }
}

extension ItemDisplayCollectionViewAcronymListCell: UIToolTipInteractionDelegate {
  func toolTipInteraction(_ interaction: UIToolTipInteraction, configurationAt point: CGPoint)
    -> UIToolTipConfiguration?
  {
    guard let text = titleLabel.text else { return nil }
    return UIToolTipConfiguration(toolTip: text)
  }
}
