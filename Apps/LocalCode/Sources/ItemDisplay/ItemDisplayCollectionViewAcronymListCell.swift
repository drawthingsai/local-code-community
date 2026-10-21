import SnapKit
import Style
import UIKit

protocol ItemDisplayCollectionViewAcronymListCellDelegate: AnyObject {
  func didTapTrash(itemIdentifier: ItemViewModel.ItemIdentifier)
}

final class ItemDisplayCollectionViewAcronymListCell: UICollectionViewCell {
  weak var delegate: ItemDisplayCollectionViewAcronymListCellDelegate? = nil

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
  private var itemIdentifier: ItemViewModel.ItemIdentifier = .empty

  override init(frame: CGRect) {
    super.init(frame: frame)
    var backgroundConfiguration = UIBackgroundConfiguration.listPlainCell()
    backgroundConfiguration.backgroundColor = .clear
    self.backgroundConfiguration = backgroundConfiguration
    let backgroundView = UIView(frame: .zero)
    backgroundView.layer.cornerRadius = 10
    backgroundView.layer.borderWidth = 2.0
    contentView.addSubview(backgroundView)
    contentView.addSubview(titleLabel)
    contentView.addSubview(acronymImagePlaceholder)
    contentView.addSubview(detailStack)
    detailStack.addArrangedSubview(detailLabel)
    detailStack.addArrangedSubview(captionLabel)

    // The icon and its selection ring keep the compact row's size when details make the row taller.
    acronymImagePlaceholder.snp.makeConstraints { make in
      make.top.leading.equalToSuperview().offset(4)
      make.size.equalTo(24)
    }
    backgroundView.snp.makeConstraints { make in
      make.edges.equalTo(acronymImagePlaceholder).inset(-4)
    }
    titleLabel.snp.makeConstraints { make in
      make.centerY.equalTo(acronymImagePlaceholder.snp.centerY)
      make.leading.equalTo(acronymImagePlaceholder.snp.trailing).offset(12)
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
      make.height.width.equalTo(16)
    }
    contentView.addSubview(trashButton)
    trashButton.snp.makeConstraints { make in
      make.centerY.equalTo(acronymImagePlaceholder)
      make.height.width.equalTo(24)
      make.trailing.equalToSuperview().offset(-4)
    }
    trashButton.isHidden = true

    self.configurationUpdateHandler = { _, state in
      if state.isSelected || state.isHighlighted {
        backgroundView.layer.borderColor = UIColor.senaryText.cgColor
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
