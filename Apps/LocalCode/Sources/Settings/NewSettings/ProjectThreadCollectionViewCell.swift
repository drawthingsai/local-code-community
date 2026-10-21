import FBShimmer
import Localization
import SnapKit
import Style
import UIKit

protocol ProjectThreadCollectionViewCellDelegate: AnyObject {
  func projectThreadCollectionViewCellDidSelectRename(_ cell: ProjectThreadCollectionViewCell)
  func projectThreadCollectionViewCellDidSelectDelete(_ cell: ProjectThreadCollectionViewCell)
  func projectThreadCollectionViewCellHasBrowser(_ cell: ProjectThreadCollectionViewCell) -> Bool
  func projectThreadCollectionViewCellDidSelectCloseBrowser(
    _ cell: ProjectThreadCollectionViewCell)
  func projectThreadCollectionViewCellDidSelectExportModelContext(
    _ cell: ProjectThreadCollectionViewCell)
}

final class ProjectThreadCollectionViewCell: UICollectionViewCell {
  static let reusableIdentifier = "ProjectThreadCollectionViewCell"

  weak var delegate: ProjectThreadCollectionViewCellDelegate?

  var item: ProjectItem? {
    didSet {
      guard item != oldValue, let item else { return }
      let image: UIImage
      if item.newThread {
        image = #imageLiteral(resourceName: "chat-new-24").withRenderingMode(.alwaysTemplate)
        titleLabel.text = LocalizedString.forKey("start_a_new_thread")
        FontMetrics.default.scaleFont(.italicSystemFont(ofSize: 14), bindTo: titleLabel)
        button.isHidden = true
        button.menu = nil
      } else if item.threadId == OnboardingState.threadIdentifier {
        // The welcome thread is virtual: it cannot be renamed or deleted.
        image = #imageLiteral(resourceName: "chat-dash-24").withRenderingMode(.alwaysTemplate)
        titleLabel.text = item.title
        FontMetrics.default.scaleFont(.systemFont(ofSize: 14), bindTo: titleLabel)
        button.isHidden = true
        button.menu = nil
      } else {
        if item.status == .new {
          image = #imageLiteral(resourceName: "chat-badge-blue-24")
        } else if item.status == .incomplete {
          image = #imageLiteral(resourceName: "chat-badge-orange-24")
        } else {
          image = #imageLiteral(resourceName: "chat-24").withRenderingMode(.alwaysTemplate)
        }
        titleLabel.text = item.title
        FontMetrics.default.scaleFont(
          .systemFont(ofSize: 14, weight: item.status == .new ? .bold : .regular),
          bindTo: titleLabel)
        button.isHidden = false
        button.menu = UIMenu(children: [
          UIAction(
            title: LocalizedString.forKey("rename_thread_dot"),
            image: UIImage(imageLiteralResourceName: "edit-16").withRenderingMode(.alwaysTemplate)
          ) { [weak self] _ in
            guard let self else { return }
            self.delegate?.projectThreadCollectionViewCellDidSelectRename(self)
          },
          // Shown only while the thread has a browser, so the menu asks each time it opens.
          UIDeferredMenuElement.uncached { [weak self] completion in
            guard let self, self.delegate?.projectThreadCollectionViewCellHasBrowser(self) == true
            else {
              completion([])
              return
            }
            completion([
              UIAction(
                title: LocalizedString.forKey("close_browser_tabs_dot"),
                image: UIImage(imageLiteralResourceName: "close-16").withRenderingMode(
                  .alwaysTemplate)
              ) { [weak self] _ in
                guard let self else { return }
                self.delegate?.projectThreadCollectionViewCellDidSelectCloseBrowser(self)
              }
            ])
          },
          UIAction(
            title: LocalizedString.forKey("export_model_context_dot"),
            image: UIImage(imageLiteralResourceName: "download-16").withRenderingMode(
              .alwaysTemplate)
          ) { [weak self] _ in
            guard let self else { return }
            self.delegate?.projectThreadCollectionViewCellDidSelectExportModelContext(self)
          },
          UIAction(
            title: LocalizedString.forKey("delete_thread_dot"),
            image: UIImage(imageLiteralResourceName: "trash-16").withRenderingMode(.alwaysTemplate),
            attributes: .destructive
          ) { [weak self] _ in
            guard let self else { return }
            self.delegate?.projectThreadCollectionViewCellDidSelectDelete(self)
          },
        ])
      }
      imageView.image = image
      highlightImageView.image = image
      updateShimmering()
      setNeedsUpdateConfiguration()
    }
  }

  private lazy var imageView: UIImageView = {
    let imageView = UIImageView(frame: .zero)
    imageView.contentMode = .scaleAspectFit
    return imageView
  }()
  private lazy var highlightImageView: UIImageView = {
    let imageView = UIImageView(frame: .zero)
    imageView.contentMode = .scaleAspectFit
    return imageView
  }()
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
    view.shimmeringSpeed = 36
    view.shimmeringPauseDuration = 0.05
    view.isUserInteractionEnabled = false
    return view
  }()
  private lazy var titleLabel: UILabel = {
    let label = UILabel(frame: .zero)
    label.textColor = .senaryText
    label.lineBreakMode = .byTruncatingTail
    FontMetrics.default.scaleFont(.systemFont(ofSize: 14), bindTo: label)
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
    return button
  }()

  override init(frame: CGRect) {
    super.init(frame: frame)
    layer.cornerRadius = 16
    clipsToBounds = true
    contentView.addSubview(imageView)
    contentView.addSubview(shimmerView)
    highlightView.addSubview(highlightImageView)
    contentView.addSubview(titleLabel)
    contentView.addSubview(button)
    imageView.snp.makeConstraints { make in
      make.leading.equalToSuperview().offset(8)
      make.centerY.equalToSuperview()
      make.size.equalTo(24)
    }
    shimmerView.snp.makeConstraints { make in
      make.edges.equalTo(imageView)
    }
    highlightImageView.snp.makeConstraints { make in
      make.edges.equalToSuperview()
    }
    titleLabel.snp.makeConstraints { make in
      make.leading.equalTo(imageView.snp.trailing).offset(6)
      make.centerY.equalToSuperview()
      make.trailing.lessThanOrEqualTo(button.snp.leading).offset(-8)
    }
    button.snp.makeConstraints { make in
      make.centerY.equalToSuperview()
      make.size.equalTo(36)
      make.trailing.equalToSuperview().offset(-2)
    }
    configurationUpdateHandler = { cell, state in
      guard let cell = cell as? ProjectThreadCollectionViewCell else { return }
      let contentColor: UIColor = state.isSelected ? .secondaryText : .senaryText
      cell.contentView.backgroundColor =
        state.isSelected ? .quinaryBackground : .secondaryBackground
      if cell.item?.status != .new && cell.item?.status != .incomplete {
        cell.imageView.tintColor = contentColor
        cell.highlightImageView.tintColor = contentColor
      }
      cell.titleLabel.textColor = contentColor
      cell.button.tintColor = contentColor
    }
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    updateShimmering()
  }

  private func updateShimmering() {
    let isInProgress = item?.status == .inProgress && item?.newThread == false
    imageView.alpha = isInProgress ? 0.28 : 1
    shimmerView.isHidden = !isInProgress
    shimmerView.isShimmering = isInProgress && window != nil
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}
