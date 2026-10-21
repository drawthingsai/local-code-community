import ArgumentParser
import Foundation
import WebKit
import WebSearch

protocol BrowserSessionDelegate: AnyObject {
  /// A tab joined the session, from open or from a page that opened a window.
  func browserSession(_ session: BrowserSession, didAdd tab: BrowserTab)
  func browserSession(_ session: BrowserSession, didClose tab: BrowserTab)
  func browserSession(
    _ session: BrowserSession, show tab: BrowserTab,
    completion: @escaping (Result<Void, Error>) -> Void)
}

/// A browser profile and tabs retained between command invocations in one chat.
/// Commands serialize here rather than introducing more model-facing tools.
final class BrowserSession {
  weak var delegate: BrowserSessionDelegate?
  private(set) var tabs = [BrowserTab]()
  private var selectedId: String?
  private let scripts: BrowserScripts
  private let configuration = WKWebViewConfiguration()
  private let responder = ObjCResponder()
  private var pending = [Invocation]()
  private var current: Invocation?

  /// `dataStore` holds the cookies and other website data that the tabs share.
  init(scripts: BrowserScripts, dataStore: WKWebsiteDataStore) {
    self.scripts = scripts
    responder.session = self
    configuration.websiteDataStore = dataStore
    SafariUserAgent.apply(to: configuration)
    // Windows a page opens reuse a copy of this configuration, so its handlers serve every tab.
    // Handlers stay out of the page's world, where Safari has no window.webkit.
    let userContentController = configuration.userContentController
    userContentController.addUserScript(
      WKUserScript(
        source: scripts.consoleRelay, injectionTime: .atDocumentStart, forMainFrameOnly: true,
        in: BrowserTab.world))
    userContentController.addUserScript(
      WKUserScript(
        source: scripts.pageConsole, injectionTime: .atDocumentStart, forMainFrameOnly: true,
        in: .page))
    userContentController.add(responder, contentWorld: BrowserTab.world, name: "browserConsole")
    userContentController.addScriptMessageHandler(
      responder, contentWorld: BrowserTab.world, name: "browser")
  }

  func execute(
    arguments: [String], resolvePath: @escaping (String) -> (URL, URL)?,
    isCancelled: @escaping () -> Bool, completion: @escaping (Result<String, Error>) -> Void
  ) {
    precondition(Thread.isMainThread)
    pending.append(
      Invocation(
        arguments: arguments, resolvePath: resolvePath, isCancelled: isCancelled,
        completion: completion))
    startNext()
  }

  /// Closes a tab the person closed, failing a command that is running against it.
  func close(tabId: String) {
    precondition(Thread.isMainThread)
    guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
    let invocation = current?.target === tab ? current : nil
    remove(tab)
    if let invocation {
      finish(
        invocation,
        .failure(
          BrowserError.unavailable(
            "The person closed the tab. Selected tab: \(selectedId ?? "none"). Run web-browse-cli tabs."
          )))
    }
  }

  /// Closes every tab and fails queued commands.
  func close() {
    precondition(Thread.isMainThread)
    for invocation in pending + (current.map { [$0] } ?? []) {
      finish(invocation, .failure(BrowserError.unavailable("The browser session closed.")))
    }
    for tab in tabs { remove(tab) }
  }

  /// A web URL, or a local file and the directory WebKit may read for it.
  static func destination(
    _ argument: String, resolvePath: (String) -> (URL, URL)?
  ) throws -> (url: URL, readAccessURL: URL?) {
    let scheme = URL(string: argument)?.scheme?.lowercased()
    if let scheme, ["http", "https", "about"].contains(scheme), let url = URL(string: argument) {
      return (url, nil)
    }
    let file = resolvePath(argument)
    if let file, FileManager.default.fileExists(atPath: file.0.path) {
      return (file.0, file.1)
    }
    // A host typed without a scheme, such as localhost:5173 or example.com/docs.
    let host = argument.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
    let name =
      host.hasPrefix("[")
      ? String(host.prefix { $0 != "]" }) + "]"
      : String(host.prefix { $0 != ":" })
    let port = host.dropFirst(name.count)
    let isLocal =
      name == "localhost" || name.hasSuffix(".local") || name.hasPrefix("[")
      || (!name.isEmpty && name.allSatisfy { $0.isNumber || $0 == "." })
    let fileExtensions: Set<String> = [
      "html", "htm", "xhtml", "svg", "xml", "pdf", "png", "jpg", "jpeg", "gif", "webp", "txt",
      "md", "json", "js", "css",
    ]
    let isHost =
      name.allSatisfy { $0.isLetter || $0.isNumber || "-.[]:".contains($0) }
      && (port.isEmpty || (port.first == ":" && port.dropFirst().allSatisfy(\.isNumber)))
      && (isLocal
        || (name.contains(".")
          && !fileExtensions.contains(String(name.split(separator: ".").last ?? "").lowercased())))
    if isHost, let url = URL(string: (isLocal ? "http://" : "https://") + argument) {
      return (url, nil)
    }
    if let scheme, scheme != "file" {
      throw BrowserError.invalidArguments(
        "Unsupported URL scheme \(scheme):. Use http(s) or a local HTML file.")
    }
    guard file != nil else {
      throw BrowserError.invalidArguments("\(argument) is outside the permitted directories")
    }
    throw BrowserError.invalidArguments(
      "No such file: \(argument). For a website, pass a URL such as https://example.com.")
  }

  private final class Invocation {
    let arguments: [String]
    let resolvePath: (String) -> (URL, URL)?
    let isCancelled: () -> Bool
    let completion: (Result<String, Error>) -> Void
    var deadline = Date.distantFuture
    var timer: Timer?
    var target: BrowserTab?
    var openedTabs = [BrowserTab]()
    var isFinished = false

    init(
      arguments: [String], resolvePath: @escaping (String) -> (URL, URL)?,
      isCancelled: @escaping () -> Bool, completion: @escaping (Result<String, Error>) -> Void
    ) {
      self.arguments = arguments
      self.resolvePath = resolvePath
      self.isCancelled = isCancelled
      self.completion = completion
    }
  }

  private func startNext() {
    guard current == nil, !pending.isEmpty else { return }
    let invocation = pending.removeFirst()
    current = invocation
    guard !invocation.isCancelled() else {
      finish(invocation, .failure(BrowserError.cancelled))
      return
    }
    invocation.deadline = Date().addingTimeInterval(30)
    // ios_system only exposes cancellation as a flag, so the main thread checks it while WebKit
    // works. The common mode keeps checking while the person scrolls the chat.
    let timer = Timer(timeInterval: 0.05, repeats: true) { [self] _ in
      let isCancelled = invocation.isCancelled()
      guard isCancelled || Date() >= invocation.deadline else { return }
      invocation.target?.cancel()
      finish(invocation, .failure(isCancelled ? BrowserError.cancelled : BrowserError.timedOut))
    }
    RunLoop.main.add(timer, forMode: .common)
    invocation.timer = timer
    let request: BrowserRequest
    do {
      request = try BrowserRequest(arguments: invocation.arguments)
    } catch {
      finish(
        invocation, .failure(BrowserError.invalidArguments(BrowserCommand.message(for: error))))
      return
    }
    do {
      try perform(request, invocation)
    } catch {
      finish(invocation, .failure(error))
    }
  }

  /// Every command ends here once; later WebKit callbacks for it are ignored.
  private func finish(_ invocation: Invocation, _ result: Result<String, Error>) {
    guard !invocation.isFinished else { return }
    invocation.isFinished = true
    invocation.timer?.invalidate()
    if current === invocation {
      current = nil
    } else {
      pending.removeAll { $0 === invocation }
    }
    invocation.completion(result)
    startNext()
  }

  private func perform(_ request: BrowserRequest, _ invocation: Invocation) throws {
    let finish = { [self] (result: Result<String, Error>) in self.finish(invocation, result) }
    let selected = { [self] () throws -> BrowserTab in
      guard let tab = tabs.first(where: { $0.id == (request.tabId ?? selectedId) }) else {
        throw BrowserError.unavailable("No matching tab. Run web-browse-cli open <url> or tabs.")
      }
      // Addressing a tab selects it for later commands, like switching to it in a browser.
      selectedId = tab.id
      invocation.target = tab
      return tab
    }
    switch request.command {
    case .tabs:
      // tabs --tab <id> switches tabs without acting on a page.
      if request.tabId != nil { _ = try selected() }
      finish(
        .success(
          try Self.json(
            tabs.map { tab in tab.metadata.merging(["selected": tab.id == selectedId]) { $1 } })))
    case .open(let argument), .goto(let argument):
      let destination = try Self.destination(argument, resolvePath: invocation.resolvePath)
      let tab: BrowserTab
      if case .open = request.command {
        tab = BrowserTab(configuration: configuration, client: scripts.client)
        add(tab)
        invocation.target = tab
      } else {
        tab = try selected()
      }
      tab.navigate(to: destination.url, readAccessURL: destination.readAccessURL) { result in
        finish(result.flatMap { _ in Result { try Self.json(tab.metadata) } })
      }
    case .close:
      let tab = try selected()
      remove(tab)
      var closed: [String: Any] = ["closed": tab.id]
      closed["selected"] = selectedId
      finish(.success(try Self.json(closed)))
    case .show:
      let tab = try selected()
      guard let delegate else {
        throw BrowserError.unavailable("Browser presentation is unavailable in this host.")
      }
      delegate.browserSession(self, show: tab) { result in
        finish(result.flatMap { _ in Result { try Self.json(tab.metadata) } })
      }
    case .console(let clear):
      let tab = try selected()
      let text = try Self.json([
        "tab": tab.id, "messages": tab.consoleMessages, "dropped": tab.droppedConsoleMessages,
      ])
      if clear { tab.clearConsoleMessages() }
      finish(.success(text))
    case .screenshot(let file, let inline, let fullPage):
      let url = try file.map { path in
        guard let resolved = invocation.resolvePath(path) else {
          throw BrowserError.invalidArguments("--file \(path) is outside the permitted directories")
        }
        return resolved.0
      }
      let tab = try selected()
      tab.screenshot(fullPage: fullPage) { result in
        // A command that was cancelled or timed out meanwhile leaves no file behind.
        guard !invocation.isFinished else { return }
        finish(
          Result {
            let data = try result.get()
            var metadata: [String: Any] = ["tab": tab.id, "bytes": data.count]
            if let url {
              try data.write(to: url, options: .atomic)
              metadata["file"] = url.path
            }
            let includeImage = inline || url == nil
            if includeImage { metadata["inline"] = true }
            return try Self.json(metadata) + (includeImage ? "\n" + Self.inlinePNG(data) : "")
          })
      }
    case .snapshot, .dom, .inspect, .run:
      var includeImage = false
      let script: String
      switch request.command {
      case .snapshot(let json, let boxes, let depth, let maxChars, let image):
        includeImage = image
        var options: [String: Any] = ["boxes": boxes]
        options["depth"] = depth
        options["maxChars"] = maxChars
        script =
          "async tab => await tab.playwright.\(json ? "snapshotJSON" : "domSnapshot")(\(try Self.json(options)))"
      case .dom(let maxChars):
        var options = [String: Any]()
        options["maxChars"] = maxChars
        script = "async tab => await tab.dom_cua.get_visible_dom(\(try Self.json(options)))"
      case .inspect(let selector):
        script =
          "async tab => await tab.playwright.locator(\(try Self.json(selector))).elementInfo()"
      case .run(.code(let code)):
        script = code
      case .run(.file(let path)):
        guard let (url, _) = invocation.resolvePath(path) else {
          throw BrowserError.invalidArguments("Script \(path) is outside the permitted directories")
        }
        script = try String(contentsOf: url, encoding: .utf8)
      default: preconditionFailure()
      }
      guard script.utf8.count <= 1_000_000 else {
        throw BrowserError.invalidArguments("Browser script exceeds 1 MB")
      }
      let tab = try selected()
      tab.run(script, timeoutMs: 29_000) { [self] result in
        let result = result.map { output(of: $0, openedTabs: invocation.openedTabs) }
        guard includeImage, case .success(let text) = result else {
          finish(result)
          return
        }
        tab.screenshot(fullPage: false) { image in
          finish(image.map { text + "\n" + Self.inlinePNG($0) })
        }
      }
    }
  }

  /// Lists tabs that pages opened while the command ran; the last of them is now selected.
  private func output(of text: String, openedTabs: [BrowserTab]) -> String {
    guard !openedTabs.isEmpty,
      let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
      let annotated = try? Self.json(
        object.merging(["openedTabs": openedTabs.map(\.metadata)]) { $1 })
    else { return text }
    return annotated
  }

  private func add(_ tab: BrowserTab) {
    tab.delegate = self
    tabs.append(tab)
    selectedId = tab.id
    delegate?.browserSession(self, didAdd: tab)
  }

  private func remove(_ tab: BrowserTab) {
    tab.delegate = nil
    tabs.removeAll { $0 === tab }
    if selectedId == tab.id {
      selectedId =
        tab.opener.flatMap { opener in tabs.contains { $0 === opener } ? opener.id : nil }
        ?? tabs.last?.id
    }
    delegate?.browserSession(self, didClose: tab)
    tab.cancel()
  }

  private func tab(for webView: WKWebView?) -> BrowserTab? {
    tabs.first { $0.webView === webView }
  }

  private static func json(_ value: Any) throws -> String {
    let data = try JSONSerialization.data(
      withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
    return String(decoding: data, as: UTF8.self)
  }

  private static func inlinePNG(_ data: Data) -> String {
    "\u{1b}]1337;File=inline=1;size=\(data.count):\(data.base64EncodedString())\u{7}"
  }

  private final class ObjCResponder: NSObject, WKScriptMessageHandler,
    WKScriptMessageHandlerWithReply
  {
    weak var session: BrowserSession?

    func userContentController(
      _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
    ) {
      guard let body = message.body as? [String: Any],
        let tab = session?.tab(for: message.webView)
      else { return }
      tab.appendConsoleMessage(body)
    }

    func userContentController(
      _ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
      replyHandler: @escaping (Any?, String?) -> Void
    ) {
      guard let body = message.body as? [String: Any],
        let tab = session?.tab(for: message.webView)
      else {
        replyHandler(nil, "This tab is no longer in the browser session")
        return
      }
      tab.evaluateInPage(body, frame: message.frameInfo, reply: replyHandler)
    }
  }
}

extension BrowserSession: BrowserTabDelegate {
  func browserTab(
    _ tab: BrowserTab, createTabWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction
  ) -> BrowserTab? {
    let popup = BrowserTab(
      configuration: configuration, client: scripts.client,
      initialURL: navigationAction.request.url)
    popup.opener = tab
    add(popup)
    current?.openedTabs.append(popup)
    return popup
  }

  func browserTabDidClose(_ tab: BrowserTab) {
    guard tabs.contains(where: { $0 === tab }) else { return }
    let invocation = current?.target === tab ? current : nil
    remove(tab)
    if let invocation {
      finish(
        invocation,
        .failure(
          BrowserError.unavailable(
            "The page closed its tab. Selected tab: \(selectedId ?? "none"). Run web-browse-cli tabs."
          )))
    }
  }
}
