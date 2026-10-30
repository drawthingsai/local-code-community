import Localization
import SnapKit
import Style
import UIKit

protocol ProjectSectionHeaderViewDelegate: AnyObject {
  func projectSectionHeaderViewDidSelectRename(_ headerView: ProjectSectionHeaderView)
  func projectSectionHeaderViewDidSelectDelete(_ headerView: ProjectSectionHeaderView)
  func projectSectionHeaderViewDidSelectReveal(_ headerView: ProjectSectionHeaderView)
  func projectSectionHeaderView(
    _ headerView: ProjectSectionHeaderView, hasBrowserData completion: @escaping (Bool) -> Void)
  func projectSectionHeaderViewDidSelectClearBrowserData(_ headerView: ProjectSectionHeaderView)
}

final class ProjectSectionHeaderView: UICollectionReusableView {
  static let reusableIdentifier = "ProjectSectionHeaderView"

  weak var delegate: ProjectSectionHeaderViewDelegate?

  private(set) var projectPath: String?

  func configure(
    projectPath: String, title: String, canModify: Bool, revealTitle: String,
    isBotModeEnabled: Bool
  ) {
    self.projectPath = projectPath
    titleLabel.text = title
    imageView.image = UIImage(named: isBotModeEnabled ? "monkey-filled-16" : "folder-filled-16")?
      .withRenderingMode(.alwaysTemplate)
    button.isHidden = false
    var actions: [UIMenuElement] = [
      UIAction(
        title: revealTitle,
        image: UIImage(systemName: "folder")
      ) { [weak self] _ in
        guard let self else { return }
        self.delegate?.projectSectionHeaderViewDidSelectReveal(self)
      }
    ]
    if canModify {
      actions.append(
        UIAction(
          title: LocalizedString.forKey(
            isBotModeEnabled ? "rename_bot_dot" : "rename_directory_dot"),
          image: UIImage(imageLiteralResourceName: "edit-16").withRenderingMode(.alwaysTemplate)
        ) { [weak self] _ in
          guard let self else { return }
          self.delegate?.projectSectionHeaderViewDidSelectRename(self)
        })
    }
    // Shown only once the project's browsers have saved data, so the menu asks each time it
    // opens.
    actions.append(
      UIDeferredMenuElement.uncached { [weak self] completion in
        guard let self, let delegate = self.delegate else {
          completion([])
          return
        }
        delegate.projectSectionHeaderView(self) { [weak self] hasBrowserData in
          guard let self, hasBrowserData else {
            completion([])
            return
          }
          completion([
            UIAction(
              title: LocalizedString.forKey("clear_browser_data_dot"),
              image: UIImage(imageLiteralResourceName: "sign-out-16").withRenderingMode(
                .alwaysTemplate)
            ) { [weak self] _ in
              guard let self else { return }
              self.delegate?.projectSectionHeaderViewDidSelectClearBrowserData(self)
            }
          ])
        }
      })
    if canModify {
      actions.append(
        UIAction(
          title: LocalizedString.forKey(
            isBotModeEnabled ? "delete_bot_dot" : "delete_directory_dot"),
          image: UIImage(imageLiteralResourceName: "trash-16").withRenderingMode(.alwaysTemplate),
          attributes: .destructive
        ) { [weak self] _ in
          guard let self else { return }
          self.delegate?.projectSectionHeaderViewDidSelectDelete(self)
        })
    }
    button.menu = UIMenu(children: actions)
  }

  /// A project on one of the account's Macs: its folder is the Mac's, so there's nothing to do
  /// with it here.
  func configureForMac(title: String) {
    projectPath = nil
    titleLabel.text = title
    imageView.image = UIImage(systemName: "desktopcomputer")
    button.isHidden = true
    button.menu = nil
  }

  private lazy var imageView: UIImageView = {
    let imageView = UIImageView(
      image: #imageLiteral(resourceName: "folder-filled-16").withRenderingMode(.alwaysTemplate))
    imageView.tintColor = .secondaryText
    imageView.contentMode = .scaleAspectFit
    return imageView
  }()
  private lazy var titleLabel: UILabel = {
    let label = UILabel(frame: .zero)
    label.textColor = .secondaryText
    label.lineBreakMode = .byTruncatingTail
    FontMetrics.default.scaleFont(.systemFont(ofSize: 14, weight: .semibold), bindTo: label)
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
    backgroundColor = .secondaryBackground
    addSubview(imageView)
    addSubview(titleLabel)
    addSubview(button)
    imageView.snp.makeConstraints { make in
      make.leading.equalToSuperview().offset(12)
      make.centerY.equalToSuperview()
      make.size.equalTo(16)
    }
    titleLabel.snp.makeConstraints { make in
      make.leading.equalTo(imageView.snp.trailing).offset(4)
      make.centerY.equalToSuperview()
      make.trailing.lessThanOrEqualTo(button.snp.leading).offset(-8)
    }
    button.snp.makeConstraints { make in
      make.centerY.equalToSuperview()
      make.size.equalTo(36)
      make.trailing.equalToSuperview().offset(-2)
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}
