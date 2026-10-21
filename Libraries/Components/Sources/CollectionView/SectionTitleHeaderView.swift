//Created 5/8/24
import Style
import UIKit

public class SectionTitleHeaderView: UICollectionReusableView {
  public static let reusableIdentifier: String = "SectionTitleHeaderView"
  public struct ViewModel: Hashable {
    public let title: String
    public let font: UIFont
    public let color: UIColor
    public let inset: CGFloat
    public init(
      title: String, font: UIFont = .systemFont(ofSize: 14, weight: .medium),
      color: UIColor = .secondaryText, inset: CGFloat = 32
    ) {
      self.title = title
      self.font = font
      self.color = color
      self.inset = 32
    }
  }

  public var viewModel: ViewModel? {
    didSet {
      guard viewModel != oldValue else { return }
      if viewModel?.font != oldValue?.font {
        FontMetrics.default.clearBinding(to: self)
        if let font = viewModel?.font {
          FontMetrics.default.scaleFont(font, bindTo: titleLabel)
        }
      }
      if let inset = viewModel?.inset, inset != oldValue?.inset {
        titleLabel.snp.remakeConstraints { make in
          make.leading.trailing.equalToSuperview().inset(inset + 12)
          make.centerY.equalToSuperview()
        }
      }
      titleLabel.text = viewModel?.title
      titleLabel.textColor = viewModel?.color
    }
  }

  public lazy var titleLabel: UILabel = UILabel()

  public override init(frame: CGRect) {
    super.init(frame: frame)
    addSubview(titleLabel)
    titleLabel.snp.makeConstraints { make in
      make.leading.trailing.equalToSuperview().inset(12)
      make.centerY.equalToSuperview()
    }
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}
