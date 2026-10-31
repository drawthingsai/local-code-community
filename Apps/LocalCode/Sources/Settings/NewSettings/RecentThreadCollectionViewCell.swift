import FBShimmer
import Localization
import SnapKit
import Style
import UIKit

protocol RecentThreadCollectionViewCellDelegate: AnyObject {
  func recentThreadCollectionViewCellDidSelectRename(_ cell: RecentThreadCollectionViewCell)
  func recentThreadCollectionViewCellDidSelectDelete(_ cell: RecentThreadCollectionViewCell)
  func recentThreadCollectionViewCellMoveDestinations(_ cell: RecentThreadCollectionViewCell)
    -> [(path: String, title: String)]
  func recentThreadCollectionViewCell(
    _ cell: RecentThreadCollectionViewCell, didSelectMoveToProjectAt projectPath: String)
  func recentThreadCollectionViewCellDidSelectReveal(_ cell: RecentThreadCollectionViewCell)
  func recentThreadCollectionViewCellHasBrowser(_ cell: RecentThreadCollectionViewCell) -> Bool
  func recentThreadCollectionViewCellDidSelectCloseBrowser(_ cell: RecentThreadCollectionViewCell)
  func recentThreadCollectionViewCellDidSelectExportModelContext(
    _ cell: RecentThreadCollectionViewCell)
}

final class RecentThreadCollectionViewCell: UICollectionViewCell {
  static let reusableIdentifier = "RecentThreadCollectionViewCell"

  struct ViewModel: Equatable {
    var abbreviation: String
    var title: String
    var subtitle: String
    var datetime: String
    var folder: String
    var status: ProjectController.Thread.Status
  }

  weak var delegate: RecentThreadCollectionViewCellDelegate?

  var viewModel: ViewModel? {
    didSet {
      guard viewModel != oldValue, let viewModel else { return }
      thumbnailLabel.text = viewModel.abbreviation
      highlightThumbnailLabel.text = viewModel.abbreviation
      titleLabel.text = viewModel.title
      datetimeLabel.text = viewModel.datetime + " · "
      folderLabel.text = viewModel.folder
      if viewModel.status != oldValue?.status {
        FontMetrics.default.scaleFont(
          .systemFont(ofSize: 13, weight: viewModel.status == .new ? .bold : .medium),
          bindTo: titleLabel)
        FontMetrics.default.scaleFont(
          .systemFont(ofSize: 12, weight: viewModel.status == .new ? .semibold : .regular),
          bindTo: subtitleLabel)
        switch viewModel.status {
        case .new:
          dotView.image = #imageLiteral(resourceName: "dot-blue-10")
          dotView.isHidden = false
        case .incomplete:
          dotView.image = #imageLiteral(resourceName: "dot-orange-10")
          dotView.isHidden = false
        case .idle, .inProgress:
          dotView.isHidden = true
        }
      }
      // The subtitle wraps up to two lines of 16pt each, matching the 16pt date line below.
      let paragraphStyle = NSMutableParagraphStyle()
      paragraphStyle.minimumLineHeight = 16
      paragraphStyle.maximumLineHeight = 16
      paragraphStyle.lineBreakMode = .byTruncatingTail
      subtitleLabel.attributedText = NSAttributedString(
        string: viewModel.subtitle, attributes: [.paragraphStyle: paragraphStyle])
      updateShimmering()
    }
  }

  private lazy var thumbnailView: UIView = {
    let view = UIView(frame: .zero)
    view.backgroundColor = .novemdecenaryBackground
    view.layer.cornerRadius = 12
    view.clipsToBounds = true
    return view
  }()
  private lazy var thumbnailLabel = Self.makeThumbnailLabel()
  private lazy var highlightThumbnailLabel = Self.makeThumbnailLabel()
  private lazy var highlightView: UIView = {
    let view = UIView(frame: .zero)
    view.isUserInteractionEnabled = false
    return view
  }()
  private lazy var shimmerView: FBShimmeringView = {
    let view = FBShimmeringView(frame: .zero)
    view.contentView = highlightView
    view.shimmeringOpacity = 0
    view.shimmeringAnimationOpacity = 1
    // Same sweep timing as the 24pt icon in ProjectThreadCollectionViewCell (speed 36), scaled to
    // the 30pt square.
    view.shimmeringSpeed = 45
    view.shimmeringPauseDuration = 0.05
    view.isUserInteractionEnabled = false
    return view
  }()
  // The 10pt dot is centered in a 14pt circle filled with the cell background, which gives the
  // 2pt border that reads as a cutout on the thumbnail corner.
  private lazy var dotView: UIImageView = {
    let imageView = UIImageView(frame: .zero)
    imageView.contentMode = .center
    imageView.layer.cornerRadius = 7
    imageView.clipsToBounds = true
    imageView.isHidden = true
    return imageView
  }()
  private lazy var titleLabel: UILabel = {
    let label = UILabel(frame: .zero)
    label.textColor = .secondaryText
    label.lineBreakMode = .byTruncatingTail
    FontMetrics.default.scaleFont(.systemFont(ofSize: 13, weight: .medium), bindTo: label)
    return label
  }()
  private lazy var subtitleLabel: UILabel = {
    let label = UILabel(frame: .zero)
    label.textColor = .senaryText
    label.numberOfLines = 2
    label.lineBreakMode = .byTruncatingTail
    FontMetrics.default.scaleFont(.systemFont(ofSize: 12), bindTo: label)
    return label
  }()
  private lazy var datetimeLabel: UILabel = {
    let label = UILabel(frame: .zero)
    label.textColor = .senaryText
    FontMetrics.default.scaleFont(.systemFont(ofSize: 11), bindTo: label)
    label.setContentHuggingPriority(.required, for: .horizontal)
    label.setContentCompressionResistancePriority(.required, for: .horizontal)
    return label
  }()
  private lazy var folderLabel: UILabel = {
    let label = UILabel(frame: .zero)
    label.textColor = .quaternaryText
    label.lineBreakMode = .byTruncatingTail
    FontMetrics.default.scaleFont(.systemFont(ofSize: 11, weight: .semibold), bindTo: label)
    return label
  }()
  private lazy var button: UIButton = {
    let button = UIButton(type: .custom)
    var configuration = UIButton.Configuration.plain()
    configuration.background.backgroundColor = .clear
    configuration.contentInsets = .zero
    configuration.image = #imageLiteral(resourceName: "overflow").withRenderingMode(.alwaysTemplate)
    button.configuration = configuration
    button.tintColor = .senaryText
    button.showsMenuAsPrimaryAction = true
    button.menu = UIMenu(children: [
      UIAction(
        title: ProjectController.revealTitle,
        image: UIImage(systemName: "folder")
      ) { [weak self] _ in
        guard let self else { return }
        self.delegate?.recentThreadCollectionViewCellDidSelectReveal(self)
      },
      UIAction(
        title: LocalizedString.forKey("rename_thread_dot"),
        image: UIImage(imageLiteralResourceName: "edit-16").withRenderingMode(.alwaysTemplate)
      ) { [weak self] _ in
        guard let self else { return }
        self.delegate?.recentThreadCollectionViewCellDidSelectRename(self)
      },
      // Lists the projects as they are when the menu opens, and only for a thread that can move.
      UIDeferredMenuElement.uncached { [weak self] completion in
        guard let self,
          let destinations = self.delegate?.recentThreadCollectionViewCellMoveDestinations(self),
          !destinations.isEmpty
        else {
          completion([])
          return
        }
        completion([
          UIMenu(
            title: LocalizedString.forKey("move_to_dot"),
            image: UIImage(systemName: "arrow.forward.folder"),
            children: destinations.map { destination in
              UIAction(title: destination.title) { [weak self] _ in
                guard let self else { return }
                self.delegate?.recentThreadCollectionViewCell(
                  self, didSelectMoveToProjectAt: destination.path)
              }
            })
        ])
      },
      // Shown only while the thread has a browser, so the menu asks each time it opens.
      UIDeferredMenuElement.uncached { [weak self] completion in
        guard let self, self.delegate?.recentThreadCollectionViewCellHasBrowser(self) == true else {
          completion([])
          return
        }
        completion([
          UIAction(
            title: LocalizedString.forKey("close_browser_tabs_dot"),
            image: UIImage(imageLiteralResourceName: "close-16").withRenderingMode(.alwaysTemplate)
          ) { [weak self] _ in
            guard let self else { return }
            self.delegate?.recentThreadCollectionViewCellDidSelectCloseBrowser(self)
          }
        ])
      },
      UIAction(
        title: LocalizedString.forKey("export_model_context_dot"),
        image: UIImage(imageLiteralResourceName: "download-16").withRenderingMode(.alwaysTemplate)
      ) { [weak self] _ in
        guard let self else { return }
        self.delegate?.recentThreadCollectionViewCellDidSelectExportModelContext(self)
      },
      UIAction(
        title: LocalizedString.forKey("delete_thread_dot"),
        image: UIImage(imageLiteralResourceName: "trash-16").withRenderingMode(.alwaysTemplate),
        attributes: .destructive
      ) { [weak self] _ in
        guard let self else { return }
        self.delegate?.recentThreadCollectionViewCellDidSelectDelete(self)
      },
    ])
    return button
  }()

  private static func makeThumbnailLabel() -> UILabel {
    let label = UILabel(frame: .zero)
    label.textColor = .secondaryText
    label.textAlignment = .center
    FontMetrics.default.scaleFont(.systemFont(ofSize: 16, weight: .semibold), bindTo: label)
    return label
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    layer.cornerRadius = 16
    clipsToBounds = true
    contentView.addSubview(thumbnailView)
    thumbnailView.addSubview(thumbnailLabel)
    thumbnailView.addSubview(shimmerView)
    highlightView.addSubview(highlightThumbnailLabel)
    contentView.addSubview(dotView)
    contentView.addSubview(titleLabel)
    contentView.addSubview(subtitleLabel)
    contentView.addSubview(datetimeLabel)
    contentView.addSubview(folderLabel)
    contentView.addSubview(button)
    // Top aligns with the title label, and the leading inset matches the 8pt gap to the text.
    thumbnailView.snp.makeConstraints { make in
      make.top.leading.equalToSuperview().inset(4)
      make.size.equalTo(48)
    }
    // Spans the thumbnail width so wide initials such as "OW" are not truncated.
    thumbnailLabel.snp.makeConstraints { make in
      make.centerY.equalToSuperview()
      make.leading.trailing.equalToSuperview()
    }
    // The shimmer band is sized by a 30pt square at the center of the thumbnail. The band travels
    // past the square's edges, so glyphs that overhang the square still light up.
    shimmerView.snp.makeConstraints { make in
      make.center.equalToSuperview()
      make.size.equalTo(30)
    }
    highlightThumbnailLabel.snp.makeConstraints { make in
      make.edges.equalTo(thumbnailLabel)
    }
    dotView.snp.makeConstraints { make in
      make.top.equalTo(thumbnailView).offset(-4)
      make.trailing.equalTo(thumbnailView).offset(4)
      make.size.equalTo(14)
    }
    titleLabel.snp.makeConstraints { make in
      make.top.equalToSuperview().offset(6)
      make.leading.equalTo(thumbnailView.snp.trailing).offset(8)
      make.trailing.lessThanOrEqualTo(button.snp.leading).offset(-8)
      make.height.equalTo(24)
    }
    subtitleLabel.snp.makeConstraints { make in
      make.top.equalTo(titleLabel.snp.bottom)
      make.leading.equalTo(titleLabel)
      // Pinned (not lessThanOrEqual) so the label wraps at this width when the cell self-sizes.
      make.trailing.equalTo(button.snp.leading).offset(-8)
      make.height.greaterThanOrEqualTo(16)
    }
    // The cell height follows the text: 8pt above the title, 6pt below the date line.
    datetimeLabel.snp.makeConstraints { make in
      make.top.equalTo(subtitleLabel.snp.bottom).offset(6)
      make.leading.equalTo(titleLabel)
      make.bottom.equalToSuperview().inset(6)
      make.height.equalTo(16)
    }
    folderLabel.snp.makeConstraints { make in
      make.leading.equalTo(datetimeLabel.snp.trailing)
      make.centerY.equalTo(datetimeLabel)
      make.trailing.lessThanOrEqualTo(button.snp.leading).offset(-8)
      make.height.equalTo(16)
    }
    button.snp.makeConstraints { make in
      make.top.trailing.equalToSuperview().inset(4)
      make.size.equalTo(32)
    }
    configurationUpdateHandler = { cell, state in
      guard let cell = cell as? RecentThreadCollectionViewCell else { return }
      cell.contentView.backgroundColor =
        state.isSelected ? .quinaryBackground : .secondaryBackground
      cell.dotView.backgroundColor = cell.contentView.backgroundColor
      cell.button.tintColor = state.isSelected ? .secondaryText : .senaryText
    }
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    updateShimmering()
  }

  private func updateShimmering() {
    let isInProgress = viewModel?.status == .inProgress
    thumbnailLabel.alpha = isInProgress ? 0.28 : 1
    shimmerView.isHidden = !isInProgress
    shimmerView.isShimmering = isInProgress && window != nil
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}
