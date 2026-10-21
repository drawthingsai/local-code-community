import Foundation
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
  func application(
    _ application: UIApplication, configurationForConnecting session: UISceneSession,
    options: UIScene.ConnectionOptions
  ) -> UISceneConfiguration {
    let configuration = UISceneConfiguration(name: "Probe", sessionRole: session.role)
    configuration.delegateClass = SceneDelegate.self
    return configuration
  }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?
  private var workflow: PickerProbeWorkflow?

  func scene(
    _ scene: UIScene, willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    guard let scene = scene as? UIWindowScene else { return }
    let workflow = PickerProbeWorkflow()
    let window = UIWindow(windowScene: scene)
    window.rootViewController = workflow.viewController
    scene.sizeRestrictions?.minimumSize = CGSize(width: 820, height: 600)
    self.workflow = workflow
    self.window = window
    window.makeKeyAndVisible()
    workflow.start()
  }
}

protocol PickerProbeViewControllerDelegate: AnyObject {
  func openFolderPicker()
  func openUIKitPicker()
  func checkRequestedDirectory()
  func restoreBookmark()
  func forgetBookmark()
}

final class PickerProbeViewController: UIViewController {
  weak var delegate: PickerProbeViewControllerDelegate?
  private let directoryField = UITextField()
  private let outputView = UITextView()
  private var buttons = [UIButton]()

  var directoryPath: String {
    get { directoryField.text ?? "" }
    set { directoryField.text = newValue }
  }

  var isPicking = false {
    didSet {
      buttons.forEach { $0.isEnabled = !isPicking }
      directoryField.isEnabled = !isPicking
    }
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    let heading = UILabel()
    heading.text = "Catalyst Folder Picker Probe"
    heading.font = .preferredFont(forTextStyle: .title1)
    let instructions = UILabel()
    instructions.text =
      "Compare the starting folder in both pickers. Selecting a folder tests access and saves a "
      + "bookmark. Quit and reopen this app, then choose Verify saved bookmark."
    instructions.numberOfLines = 0
    directoryField.borderStyle = .roundedRect
    directoryField.placeholder = "Absolute directory path"
    directoryField.autocorrectionType = .no
    directoryField.autocapitalizationType = .none
    directoryField.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
    let actions: [(String, () -> Void)] = [
      ("Open shared picker", { [weak self] in self?.delegate?.openFolderPicker() }),
      ("Open UIKit picker", { [weak self] in self?.delegate?.openUIKitPicker() }),
      ("Check path access", { [weak self] in self?.delegate?.checkRequestedDirectory() }),
      ("Verify saved bookmark", { [weak self] in self?.delegate?.restoreBookmark() }),
      ("Forget bookmark", { [weak self] in self?.delegate?.forgetBookmark() }),
    ]
    buttons = actions.map { title, action in
      let button = UIButton(type: .system)
      var configuration = UIButton.Configuration.bordered()
      configuration.title = title
      button.configuration = configuration
      button.addAction(UIAction { _ in action() }, for: .touchUpInside)
      return button
    }
    let pickerButtons = UIStackView(arrangedSubviews: Array(buttons.prefix(2)))
    pickerButtons.spacing = 12
    pickerButtons.distribution = .fillEqually
    let bookmarkButtons = UIStackView(arrangedSubviews: Array(buttons.dropFirst(2)))
    bookmarkButtons.spacing = 12
    bookmarkButtons.distribution = .fillEqually
    outputView.isEditable = false
    outputView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
    outputView.backgroundColor = .secondarySystemBackground
    outputView.layer.cornerRadius = 8
    let stack = UIStackView(
      arrangedSubviews: [
        heading, instructions, directoryField, pickerButtons, bookmarkButtons, outputView,
      ])
    stack.axis = .vertical
    stack.spacing = 16
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
      stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
      stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
      directoryField.heightAnchor.constraint(greaterThanOrEqualToConstant: 36),
      outputView.heightAnchor.constraint(greaterThanOrEqualToConstant: 260),
    ])
  }

  func append(_ message: String) {
    outputView.text += message + "\n"
    outputView.scrollRangeToVisible(NSRange(location: outputView.text.utf16.count, length: 0))
    print(message)
    fflush(stdout)
  }
}

final class PickerProbeWorkflow: PickerProbeViewControllerDelegate,
  UnifiedDocumentPickerControllerDelegate
{
  let viewController = PickerProbeViewController()
  private let responder = PickerResponder()
  private let defaults = UserDefaults.standard

  final class PickerResponder: NSObject, UIDocumentPickerDelegate {
    weak var workflow: PickerProbeWorkflow?

    func documentPicker(
      _ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]
    ) {
      workflow?.selected(urls.first, using: "UIKit")
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
      workflow?.selected(nil, using: "UIKit")
    }
  }

  init() {
    viewController.delegate = self
    responder.workflow = self
  }

  func start() {
    viewController.loadViewIfNeeded()
    viewController.directoryPath =
      defaults.string(forKey: "requestedDirectory")
      ?? Bundle.main.object(forInfoDictionaryKey: "ProbeInitialDirectory") as? String ?? "/"
    viewController.append("Process: \(ProcessInfo.processInfo.processIdentifier)")
    viewController.append("Container: \(NSHomeDirectory())")
    viewController.append("NSOpenPanel class available: \(NSClassFromString("NSOpenPanel") != nil)")
    viewController.append("Saved bookmark: \(defaults.data(forKey: "bookmark") != nil)")
    viewController.append("No access has been activated by this launch.\n")
  }

  private func requestedDirectory() -> URL? {
    let path = viewController.directoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard path.hasPrefix("/") else {
      viewController.append("Enter an absolute path.")
      return nil
    }
    defaults.set(path, forKey: "requestedDirectory")
    return URL(fileURLWithPath: path, isDirectory: true)
  }

  func openFolderPicker() {
    guard !viewController.isPicking, let directory = requestedDirectory() else { return }
    let picker = UnifiedDocumentPickerController(forOpeningContentTypes: [.folder])
    picker.title = "Unified folder access probe"
    picker.directoryURL = directory
    picker.allowsMultipleSelection = false
    picker.delegate = self
    viewController.isPicking = true
    viewController.append("\nUnified picker requested: \(directory.path)")
    if !viewController.present(picker, animated: true) {
      viewController.isPicking = false
      viewController.append("Unable to present the folder picker.")
    } else if let delay = Bundle.main.object(forInfoDictionaryKey: "ProbeDismissAfter") as? Double {
      let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
        self?.viewController.append("Dismissing the shared picker programmatically.")
        picker.dismiss(animated: true)
      }
      RunLoop.main.add(timer, forMode: .common)
    }
  }

  func documentPicker(_ controller: UnifiedDocumentPickerController, didPickDocumentsAt urls: [URL])
  {
    selected(urls.first, using: "Unified picker")
  }

  func documentPickerWasCancelled(_ controller: UnifiedDocumentPickerController) {
    selected(nil, using: "Unified picker")
  }

  func openUIKitPicker() {
    guard !viewController.isPicking, let directory = requestedDirectory() else { return }
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
    picker.directoryURL = directory
    picker.allowsMultipleSelection = false
    picker.delegate = responder
    viewController.append("\nUIKit requested: \(directory.path)")
    viewController.isPicking = true
    viewController.present(picker, animated: true)
  }

  fileprivate func selected(_ url: URL?, using picker: String) {
    viewController.isPicking = false
    guard let url else {
      viewController.append("\(picker): cancelled; existing bookmark preserved.")
      return
    }
    viewController.append("\(picker) selected: \(url.path)")
    let accessed = url.startAccessingSecurityScopedResource()
    viewController.append("startAccessingSecurityScopedResource: \(accessed)")
    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
    do {
      let entries = try FileManager.default.contentsOfDirectory(
        at: url, includingPropertiesForKeys: nil)
      viewController.append("Directory read succeeded: \(entries.count) entries.")
      let bookmark = try url.bookmarkData(
        options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
      defaults.set(bookmark, forKey: "bookmark")
      viewController.append("Bookmark saved. Quit and reopen, then verify it.\n")
    } catch {
      viewController.append("Selection/access failed: \(error.localizedDescription)")
    }
  }

  func checkRequestedDirectory() {
    guard let directory = requestedDirectory() else { return }
    do {
      let entries = try FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)
      viewController.append("Path access without activating a bookmark: \(entries.count) entries.")
    } catch {
      viewController.append(
        "Path access without activating a bookmark: \(error.localizedDescription)")
    }
  }

  func restoreBookmark() {
    guard let data = defaults.data(forKey: "bookmark") else {
      viewController.append("No saved bookmark.")
      return
    }
    do {
      var stale = false
      let url = try URL(
        resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &stale)
      viewController.append("\nRestored: \(url.path); stale: \(stale)")
      let accessed = url.startAccessingSecurityScopedResource()
      viewController.append("startAccessingSecurityScopedResource: \(accessed)")
      defer { if accessed { url.stopAccessingSecurityScopedResource() } }
      let entries = try FileManager.default.contentsOfDirectory(
        at: url, includingPropertiesForKeys: nil)
      if stale {
        let updated = try url.bookmarkData(
          options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(updated, forKey: "bookmark")
      }
      viewController.append("Bookmark access succeeded: \(entries.count) entries.\n")
    } catch {
      viewController.append("Bookmark access failed: \(error.localizedDescription)")
    }
  }

  func forgetBookmark() {
    defaults.removeObject(forKey: "bookmark")
    viewController.append(
      "Bookmark removed. Restart before checking access without a bookmark again.")
  }
}
