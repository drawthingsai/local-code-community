import SnapKit
import Style
import UIKit

class ItemDisplayCollectionViewListCell: UICollectionViewCell {

  static var reusableIdentifier: String {
    "ItemDisplayCollectionViewListCell"
  }
  private let imageView: UIImageView = {
    let imageView = UIImageView()
    imageView.contentMode = .scaleAspectFit
    imageView.clipsToBounds = true
    return imageView
  }()
  private let titleLabel: UILabel = {
    let label = UILabel()
    label.textAlignment = .left
    label.numberOfLines = 1
    label.lineBreakMode = .byTruncatingMiddle
    FontMetrics.default.scaleFont(.systemFont(ofSize: 14, weight: .semibold), bindTo: label)
    return label
  }()
  private let detailLabel: UILabel = {
    let label = UILabel()
    label.textAlignment = .left
    label.numberOfLines = 0
    label.lineBreakMode = .byTruncatingMiddle
    FontMetrics.default.scaleFont(.systemFont(ofSize: 14), bindTo: label)
    return label
  }()

  override init(frame: CGRect) {
    super.init(frame: frame)
    var backgroundConfiguration = UIBackgroundConfiguration.listPlainCell()
    backgroundConfiguration.backgroundColor = .clear
    self.backgroundConfiguration = backgroundConfiguration
    let backgroundView = UIView(frame: .zero)
    backgroundView.layer.cornerRadius = 23
    backgroundView.layer.borderWidth = 3.0
    backgroundView.clipsToBounds = true

    contentView.addSubview(backgroundView)

    contentView.addSubview(imageView)
    contentView.addSubview(titleLabel)
    contentView.addSubview(detailLabel)

    imageView.snp.makeConstraints { make in
      make.top.leading.equalToSuperview().offset(7)
      make.bottom.equalToSuperview().offset(-7)
      make.height.equalTo(imageView.snp.width)
    }
    backgroundView.snp.makeConstraints { make in
      make.top.bottom.leading.equalToSuperview()
      make.trailing.equalTo(imageView).offset(7)
    }
    imageView.layer.cornerRadius = 15
    imageView.clipsToBounds = true
    titleLabel.snp.makeConstraints { make in
      make.top.equalTo(imageView.snp.top).offset(2)
      make.leading.equalTo(imageView.snp.trailing).offset(16)
      make.trailing.equalToSuperview().offset(-4)
      make.height.equalTo(25)
    }
    detailLabel.snp.makeConstraints { make in
      make.top.equalTo(titleLabel.snp.bottom).offset(3)
      make.leading.equalTo(titleLabel.snp.leading)
      make.trailing.equalToSuperview().offset(-4)
      make.bottom.equalTo(imageView.snp.bottom).offset(-4)
    }

    self.configurationUpdateHandler = { _, state in
      if state.isSelected || state.isHighlighted {
        backgroundView.layer.borderColor = UIColor.selectorGrayColor.cgColor
      } else {
        backgroundView.layer.borderColor = UIColor.clear.cgColor
      }
    }
    let imageToolTipInteraction = UIToolTipInteraction()
    imageToolTipInteraction.delegate = self
    imageView.addInteraction(imageToolTipInteraction)
    let titleToolTipInteraction = UIToolTipInteraction()
    titleToolTipInteraction.delegate = self
    titleLabel.addInteraction(titleToolTipInteraction)
  }

  required init?(coder aDecoder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func setViewModel(with viewModel: ItemViewModel) {
    imageView.image = nil

    switch viewModel.title {
    case .title(let title):
      titleLabel.text = title
    case .attributed(let attributed):
      titleLabel.attributedText = attributed
    }

    switch viewModel.thumbnail {

    case .imageLiteralResourceName(let imageLiteralResourceName):
      imageView.image = UIImage(imageLiteralResourceName: imageLiteralResourceName)

    case .thumbnailPath(let thumbnailPath):
      let documentsDirectory = FileManager.default.urls(
        for: .documentDirectory, in: .userDomainMask
      ).first!
      let fullPath = documentsDirectory.appendingPathComponent(thumbnailPath).path
      if let image = UIImage(contentsOfFile: fullPath) {
        imageView.image = image
      }
    }

    detailLabel.text = viewModel.detail
  }

}

extension ItemDisplayCollectionViewListCell: UIToolTipInteractionDelegate {
  func toolTipInteraction(_ interaction: UIToolTipInteraction, configurationAt point: CGPoint)
    -> UIToolTipConfiguration?
  {
    guard let text = titleLabel.text else { return nil }
    return UIToolTipConfiguration(toolTip: text)
  }
}
