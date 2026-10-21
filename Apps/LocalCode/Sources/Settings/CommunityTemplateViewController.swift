import Localization
import SnapKit
import Style
import UIKit

protocol CommunityTemplateViewControllerDelegate: AnyObject {
  func didTapClose()
  func didSelectTemplate(named name: String)
}

/// A searchable list of the community templates to start a new project from.
final class CommunityTemplateViewController: UIViewController, EscapeKeyDismissible {
  enum State {
    case loading
    case loaded([String])
    case failed
  }

  weak var delegate: CommunityTemplateViewControllerDelegate?

  var state = State.loading {
    didSet {
      updateTemplates()
    }
  }

  private var templateNames = [String]()

  override var keyCommands: [UIKeyCommand]? {
    let command = UIKeyCommand(
      input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(dismissWithEscape))
    command.wantsPriorityOverSystemBehavior = true
    return [command]
  }

  private lazy var xButton: UIButton = {
    let button = UIButton(type: .custom)
    var configuration = UIButton.Configuration.filled()
    configuration.cornerStyle = .capsule
    configuration.background.backgroundColor = .clear
    configuration.baseForegroundColor = .senaryText
    configuration.image = #imageLiteral(resourceName: "close-16").withRenderingMode(
      .alwaysTemplate)
    configuration.contentInsets = .zero
    button.configuration = configuration
    button.configurationUpdateHandler = {
      guard var configuration = $0.configuration else { return }
      configuration.background.backgroundColor =
        $0.isHighlighted || $0.state.contains(.focused) ? .quinaryBackground : .clear
      $0.configuration = configuration
    }
    button.addAction(
      UIAction { [weak self] _ in
        self?.delegate?.didTapClose()
      }, for: .touchUpInside)
    return button
  }()

  private lazy var titleLabel: UILabel = {
    let label = UILabel(frame: .zero)
    label.text = LocalizedString.forKey("community_templates")
    label.textColor = .primaryText
    FontMetrics.default.scaleFont(.systemFont(ofSize: 15, weight: .medium), bindTo: label)
    return label
  }()

  private lazy var searchBar: UISearchBar = {
    let searchBar = UISearchBar(frame: .zero)
    searchBar.searchBarStyle = .minimal
    searchBar.placeholder = LocalizedString.forKey("search")
    searchBar.delegate = self
    return searchBar
  }()

  private lazy var tableView: UITableView = {
    let tableView = UITableView(frame: .zero, style: .plain)
    tableView.backgroundColor = .clear
    tableView.separatorColor = .primaryBorder
    tableView.keyboardDismissMode = .onDrag
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Template")
    tableView.dataSource = self
    tableView.delegate = self
    return tableView
  }()

  private lazy var messageLabel: UILabel = {
    let label = UILabel(frame: .zero)
    label.textColor = .senaryText
    label.textAlignment = .center
    label.numberOfLines = 0
    FontMetrics.default.scaleFont(.systemFont(ofSize: 14), bindTo: label)
    return label
  }()

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .secondaryBackground

    view.addSubview(xButton)
    xButton.snp.makeConstraints { make in
      make.top.equalTo(view.snp.topMargin).offset(10)
      make.trailing.equalToSuperview().offset(-14)
      make.width.height.equalTo(32)
    }

    view.addSubview(titleLabel)
    titleLabel.snp.makeConstraints { make in
      make.centerY.equalTo(xButton)
      make.leading.equalToSuperview().offset(24)
      make.trailing.lessThanOrEqualTo(xButton.snp.leading).offset(-12)
    }

    view.addSubview(searchBar)
    searchBar.snp.makeConstraints { make in
      make.top.equalTo(view.snp.topMargin).offset(52)
      make.leading.trailing.equalToSuperview().inset(16)
    }

    view.addSubview(tableView)
    tableView.snp.makeConstraints { make in
      make.top.equalTo(searchBar.snp.bottom).offset(8)
      make.leading.trailing.bottom.equalToSuperview()
    }

    view.addSubview(messageLabel)
    messageLabel.snp.makeConstraints { make in
      make.top.equalTo(searchBar.snp.bottom).offset(32)
      make.leading.trailing.equalToSuperview().inset(24)
    }

    updateTemplates()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    // Only a hardware keyboard types straight into search; a software one would cover the list.
    #if targetEnvironment(macCatalyst)
      searchBar.becomeFirstResponder()
    #endif
  }

  @objc func dismissWithEscape() {
    delegate?.didTapClose()
  }

  private func updateTemplates() {
    guard isViewLoaded else { return }
    switch state {
    case .loading:
      templateNames = []
      messageLabel.text = LocalizedString.forKey("loading_templates")
    case .loaded(let names):
      let searchText = searchBar.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      templateNames =
        searchText.isEmpty ? names : names.filter { $0.localizedStandardContains(searchText) }
      messageLabel.text =
        templateNames.isEmpty ? LocalizedString.forKey("no_templates_found") : nil
    case .failed:
      templateNames = []
      messageLabel.text = LocalizedString.forKey("cannot_load_templates")
    }
    messageLabel.isHidden = messageLabel.text == nil
    tableView.reloadData()
  }
}

extension CommunityTemplateViewController: UISearchBarDelegate {
  func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
    updateTemplates()
  }

  func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
    // Return picks the only match, which is what a search narrowed down to.
    guard templateNames.count == 1 else {
      searchBar.resignFirstResponder()
      return
    }
    delegate?.didSelectTemplate(named: templateNames[0])
  }
}

extension CommunityTemplateViewController: UITableViewDataSource, UITableViewDelegate {
  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    templateNames.count
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "Template", for: indexPath)
    var configuration = cell.defaultContentConfiguration()
    configuration.text = templateNames[indexPath.row]
    configuration.textProperties.color = .primaryText
    configuration.image = UIImage(named: "folder-24")?.withTintColor(.senaryText)
    cell.contentConfiguration = configuration
    cell.backgroundColor = .clear
    return cell
  }

  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    delegate?.didSelectTemplate(named: templateNames[indexPath.row])
  }
}
