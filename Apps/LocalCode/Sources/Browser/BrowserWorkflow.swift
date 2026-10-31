import UIKit
import WebKit

protocol BrowserWorkflowDelegate: AnyObject {
  /// The chat's view controller. On iPhone and iPad it presents the sheet; on Mac, new browser
  /// windows open over the chat's window. Hidden tabs live in the chat's window too, behind its
  /// views: WebKit only paints them, runs animation frames, and reports the page as visible
  /// while they are in a window.
  func browserWorkflowPresentingViewController(_ workflow: BrowserWorkflow) -> UIViewController?
  /// A tab opened or closed, or its page's title or address changed.
  func browserWorkflowDidChangeTabs(_ workflow: BrowserWorkflow)
}

/// One chat's browser. Hidden tabs sit in a clipped one-point view at the back of the chat's
/// window; show moves a tab's web view into its own `UnifiedBrowserWindowWorkflow`, and closing
/// that window moves it back.
final class BrowserWorkflow {
  weak var delegate: BrowserWorkflowDelegate?
  private let session: BrowserSession
  /// Open windows, by tab.
  private var windowWorkflows = [String: UnifiedBrowserWindowWorkflow]()
  /// Each tab's title and address, by tab.
  private var tabObservations = [String: [NSKeyValueObservation]]()
  private lazy var hostView: UIView = {
    let view = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
    view.clipsToBounds = true
    view.isUserInteractionEnabled = false
    view.accessibilityElementsHidden = true
    return view
  }()

  init(scripts: BrowserScripts, dataStore: WKWebsiteDataStore) {
    session = BrowserSession(scripts: scripts, dataStore: dataStore)
    session.delegate = self
  }

  /// The open tabs, oldest first, each named by its page's title, or else its host.
  var tabs: [(id: String, title: String)] {
    session.tabs.map { tab in
      let webView = tab.webView
      let title =
        webView.title.flatMap { $0.isEmpty ? nil : $0 } ?? webView.url?.host
        ?? webView.url?.absoluteString ?? "about:blank"
      return (tab.id, title)
    }
  }

  /// Opens the tab's window, or brings it to the front, without waiting for commands.
  func show(tabId: String) {
    guard let tab = session.tabs.first(where: { $0.id == tabId }) else { return }
    present(tab) { _ in }
  }

  /// Opens a blank tab in its window and selects it, so the person can sign in to a site with
  /// their own credentials before agents use the tab.
  func openTab() {
    attachHostView()
    present(session.openTab()) { _ in }
  }

  func closeTab(id: String) {
    session.close(tabId: id)
  }

  func execute(
    arguments: [String], resolvePath: @escaping (String) -> (URL, URL)?,
    isCancelled: @escaping () -> Bool, completion: @escaping (Result<String, Error>) -> Void
  ) {
    attachHostView()
    session.execute(
      arguments: arguments, resolvePath: resolvePath, isCancelled: isCancelled,
      completion: completion)
  }

  /// Closes every window and tab.
  func close() {
    for workflow in windowWorkflows.values {
      workflow.delegate = nil
      workflow.close(animated: false)
    }
    windowWorkflows.removeAll()
    session.close()
    hostView.removeFromSuperview()
  }

  /// Puts the hidden tabs' host in the chat's window, where WebKit keeps their pages running.
  private func attachHostView() {
    guard hostView.window == nil,
      let window = delegate?.browserWorkflowPresentingViewController(self)?.viewIfLoaded?.window
    else { return }
    window.insertSubview(hostView, at: 0)
  }

  private func hide(_ webView: BrowserWebView) {
    webView.isPresented = false
    webView.removeFromSuperview()
    webView.translatesAutoresizingMaskIntoConstraints = true
    webView.frame = BrowserTab.viewport
    hostView.addSubview(webView)
  }

  /// Opens the tab's window, or brings it to the front. The page lays out at the window's size
  /// until it closes.
  private func present(_ tab: BrowserTab, completion: @escaping (Result<Void, Error>) -> Void) {
    let presenter = delegate?.browserWorkflowPresentingViewController(self)
    if let workflow = windowWorkflows[tab.id] {
      workflow.present(from: presenter, completion: completion)
      return
    }
    let open = { [weak self] in
      guard let self else { return }
      let workflow = UnifiedBrowserWindowWorkflow(webView: tab.webView)
      workflow.delegate = self
      self.windowWorkflows[tab.id] = workflow
      tab.webView.isPresented = true
      workflow.present(from: presenter) { [weak self, weak workflow] result in
        if case .failure = result, let self, let workflow,
          self.windowWorkflows[tab.id] === workflow
        {
          // The web view never left the hidden host.
          self.windowWorkflows[tab.id] = nil
          tab.webView.isPresented = false
        }
        completion(result)
      }
    }
    #if targetEnvironment(macCatalyst)
      open()
    #else
      // A sheet shows one tab at a time.
      guard let other = windowWorkflows.values.first(where: \.isOpen) else {
        open()
        return
      }
      other.close(animated: false, completion: open)
    #endif
  }
}

extension BrowserWorkflow: BrowserSessionDelegate {
  func browserSession(_ session: BrowserSession, didAdd tab: BrowserTab) {
    hide(tab.webView)
    let didChange = { [weak self] in
      guard let self else { return }
      self.delegate?.browserWorkflowDidChangeTabs(self)
    }
    tabObservations[tab.id] = [
      tab.webView.observe(\.title) { _, _ in didChange() },
      tab.webView.observe(\.url) { _, _ in didChange() },
    ]
    delegate?.browserWorkflowDidChangeTabs(self)
  }

  func browserSession(_ session: BrowserSession, didClose tab: BrowserTab) {
    if let workflow = windowWorkflows.removeValue(forKey: tab.id) {
      workflow.delegate = nil
      workflow.close()
    }
    tab.webView.removeFromSuperview()
    tabObservations[tab.id] = nil
    delegate?.browserWorkflowDidChangeTabs(self)
  }

  func browserSession(
    _ session: BrowserSession, show tab: BrowserTab,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    present(tab, completion: completion)
  }
}

extension BrowserWorkflow: UnifiedBrowserWindowWorkflowDelegate {
  func unifiedBrowserWindowWorkflowDidClose(_ workflow: UnifiedBrowserWindowWorkflow) {
    guard let id = windowWorkflows.first(where: { $0.value === workflow })?.key else { return }
    windowWorkflows[id] = nil
    guard let tab = session.tabs.first(where: { $0.id == id }) else { return }
    hide(tab.webView)
  }
}
