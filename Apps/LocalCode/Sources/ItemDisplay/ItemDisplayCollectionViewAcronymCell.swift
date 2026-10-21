import SnapKit
import Style
import UIKit

class ItemDisplayCollectionViewAcronymCell: UICollectionViewCell {

  static var reusableIdentifier: String {
    "ItemDisplayCollectionViewAcronymCell"
  }

  private let acronymImage: UIImageView = {
    let imageView = UIImageView()
    imageView.contentMode = .scaleAspectFit
    imageView.clipsToBounds = true
    return imageView
  }()

  private let acronymTitle: UILabel = {
    let label = UILabel()
    label.textAlignment = .center
    label.numberOfLines = 1
    FontMetrics.default.scaleFont(.boldSystemFont(ofSize: 20), bindTo: label)
    return label
  }()

  private let titleLabel: UILabel = {
    let label = UILabel()
    label.textAlignment = .center
    label.numberOfLines = 2
    label.lineBreakMode = .byTruncatingMiddle
    FontMetrics.default.scaleFont(
      .systemFont(ofSize: 12, weight: .semibold), bindTo: label)
    return label
  }()

  override init(frame: CGRect) {
    super.init(frame: frame)
    var backgroundConfiguration = UIBackgroundConfiguration.listPlainCell()
    backgroundConfiguration.backgroundColor = .clear
    self.backgroundConfiguration = backgroundConfiguration

    let backgroundView = UIView(frame: .zero)
    backgroundView.backgroundColor = .clear
    backgroundView.layer.cornerRadius = 19
    backgroundView.layer.borderWidth = 2.0
    backgroundView.clipsToBounds = true
    contentView.addSubview(titleLabel)
    contentView.addSubview(acronymTitle)
    acronymTitle.snp.makeConstraints { make in
      make.top.leading.equalToSuperview().offset(6)
      make.trailing.equalToSuperview().offset(-6)
      make.height.equalTo(acronymTitle.snp.width)
    }
    contentView.addSubview(backgroundView)
    backgroundView.snp.makeConstraints { make in
      make.top.leading.trailing.equalToSuperview()
      make.height.equalTo(backgroundView.snp.width)
    }
    acronymTitle.layer.cornerRadius = 15
    acronymTitle.clipsToBounds = true
    contentView.addSubview(acronymImage)
    acronymImage.snp.makeConstraints { make in
      make.center.equalTo(acronymTitle.snp.center)
      make.height.width.equalTo(36)
    }
    titleLabel.snp.remakeConstraints { make in
      make.top.equalTo(acronymTitle.snp.bottom).offset(6)
      make.leading.equalTo(acronymTitle.snp.leading)
      make.trailing.equalTo(acronymTitle.snp.trailing)
      make.height.equalTo(34)
    }
    self.configurationUpdateHandler = { _, state in
      if state.isSelected || state.isHighlighted {
        backgroundView.layer.borderColor = UIColor.selectorGrayColor.cgColor
      } else {
        backgroundView.layer.borderColor = UIColor.clear.cgColor
      }
    }
    let acronymToolTipInteraction = UIToolTipInteraction()
    acronymToolTipInteraction.delegate = self
    acronymTitle.addInteraction(acronymToolTipInteraction)
    let titleToolTipInteraction = UIToolTipInteraction()
    titleToolTipInteraction.delegate = self
    titleLabel.addInteraction(titleToolTipInteraction)
  }

  required init?(coder aDecoder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func setViewModel(with viewModel: ItemAcronymViewModel) {
    acronymImage.image = nil
    acronymTitle.text = nil
    switch viewModel.title {
    case .title(let title):
      titleLabel.text = title
    case .attributed(let attributed):
      titleLabel.attributedText = attributed
    }
    acronymTitle.backgroundColor = viewModel.backgroundColor

    switch viewModel.thumbnail {
    case .image(let image):
      acronymImage.tintColor = .senaryText
      acronymImage.image = image
    case .acronymTitle(let text):
      self.acronymTitle.text = text
    case .systemName(let systemName):
      acronymImage.image = UIImage(systemName: systemName)?.withTintColor(
        .label, renderingMode: .alwaysOriginal)
    case .imageLiteralResourceName(let imageLiteralResourceName):
      acronymImage.image = UIImage(imageLiteralResourceName: imageLiteralResourceName)
        .withTintColor(.label)
    }
  }
}

extension ItemDisplayCollectionViewAcronymCell: UIToolTipInteractionDelegate {
  func toolTipInteraction(_ interaction: UIToolTipInteraction, configurationAt point: CGPoint)
    -> UIToolTipConfiguration?
  {
    guard let text = titleLabel.text else { return nil }
    return UIToolTipConfiguration(toolTip: text)
  }
}
