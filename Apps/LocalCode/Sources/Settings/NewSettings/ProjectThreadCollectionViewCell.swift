import FBShimmer
import ImageIO
import Localization
import SnapKit
import Style
import UIKit

protocol ProjectThreadCollectionViewCellDelegate: AnyObject {
  func projectThreadCollectionViewCellDidSelectRename(_ cell: ProjectThreadCollectionViewCell)
  func projectThreadCollectionViewCellDidSelectDelete(_ cell: ProjectThreadCollectionViewCell)
  func projectThreadCollectionViewCellMoveDestinations(_ cell: ProjectThreadCollectionViewCell)
    -> [(path: String, title: String)]
  func projectThreadCollectionViewCell(
    _ cell: ProjectThreadCollectionViewCell, didSelectMoveToProjectAt projectPath: String)
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
        if let messagingPlatform = item.messagingPlatform {
          // A chat app's thread shows the app, with its status as a dot.
          switch messagingPlatform {
          case .iMessage: image = Self.iMessageImage
          case .telegram: image = #imageLiteral(resourceName: "telegram-24")
          case .discord: image = #imageLiteral(resourceName: "discord-24")
          }
        } else if item.status == .new {
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
          // Lists the projects as they are when the menu opens, and only for a thread that can move.
          UIDeferredMenuElement.uncached { [weak self] completion in
            guard let self,
              let destinations = self.delegate?.projectThreadCollectionViewCellMoveDestinations(
                self), !destinations.isEmpty
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
                    self.delegate?.projectThreadCollectionViewCell(
                      self, didSelectMoveToProjectAt: destination.path)
                  }
                })
            ])
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
      switch (item.messagingPlatform, item.status) {
      case (.some, .new):
        dotView.image = #imageLiteral(resourceName: "dot-blue-10")
        dotView.isHidden = false
      case (.some, .incomplete):
        dotView.image = #imageLiteral(resourceName: "dot-orange-10")
        dotView.isHidden = false
      default:
        dotView.isHidden = true
      }
      updateShimmering()
      setNeedsUpdateConfiguration()
    }
  }

  /// Messages' own icon, read from the app on the Mac, since apps can't ship Apple's icons.
  /// Elsewhere, or if it can't be read, a bubble drawn in Messages' colors.
  private static let iMessageImage: UIImage = {
    #if targetEnvironment(macCatalyst)
      if let bundle = Bundle(path: "/System/Applications/Messages.app"),
        let iconFile = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
        let url = bundle.url(
          forResource: (iconFile as NSString).deletingPathExtension, withExtension: "icns"),
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)
      {
        let widths = (0..<CGImageSourceGetCount(source)).compactMap { index -> (Int, Int)? in
          let properties =
            CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
          return (properties?[kCGImagePropertyPixelWidth] as? Int).map { (index, $0) }
        }
        // The smallest size that stays sharp at 24pt on a Retina screen.
        if let (index, width) = widths.filter({ $0.1 >= 64 }).min(by: { $0.1 < $1.1 })
          ?? widths.max(by: { $0.1 < $1.1 }),
          let cgImage = CGImageSourceCreateImageAtIndex(source, index, nil)
        {
          return UIImage(cgImage: cgImage, scale: CGFloat(width) / 24, orientation: .up)
        }
      }
    #endif
    return #imageLiteral(resourceName: "imessage-24")
  }()

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
  // As on Recents rows: the 10pt dot is centered in a 14pt circle filled with the cell background,
  // which gives the 2pt border that reads as a cutout on the icon's corner.
  private lazy var dotView: UIImageView = {
    let imageView = UIImageView(frame: .zero)
    imageView.contentMode = .center
    imageView.layer.cornerRadius = 7
    imageView.clipsToBounds = true
    imageView.isHidden = true
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
    clipsToBounds = true
    contentView.addSubview(imageView)
    contentView.addSubview(shimmerView)
    highlightView.addSubview(highlightImageView)
    contentView.addSubview(dotView)
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
    dotView.snp.makeConstraints { make in
      make.top.equalTo(imageView).offset(-4)
      make.trailing.equalTo(imageView).offset(4)
      make.size.equalTo(14)
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
      // On iPhone every row keeps the selected row's content color; only the fill marks the
      // selection.
      let isPhone = state.traitCollection.userInterfaceIdiom == .phone
      cell.layer.cornerRadius = isPhone ? 12 : 16
      let contentColor: UIColor = state.isSelected || isPhone ? .secondaryText : .senaryText
      cell.contentView.backgroundColor =
        state.isSelected
        ? (isPhone ? .senaryFill : .quinaryBackground) : .secondaryBackground
      cell.dotView.backgroundColor = cell.contentView.backgroundColor
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
