import Foundation
import ImageIO
import WebKit

#if canImport(UIKit)
  import UIKit
#else
  import AppKit
#endif

enum BrowserError: LocalizedError {
  case invalidArguments(String)
  case unavailable(String)
  case script(String)
  case pageCrashed(URL?)
  case download(URL, mimeType: String?)
  case unsupportedURL(URL)
  case timedOut
  case cancelled

  var errorDescription: String? {
    switch self {
    case .invalidArguments(let message), .unavailable(let message), .script(let message):
      return message
    case .pageCrashed(let url):
      let reload =
        url.map { "web-browse-cli goto '\($0.absoluteString)'" } ?? "web-browse-cli goto <url>"
      return
        "The page's web process ended, usually under memory pressure. Run \(reload) to reload it."
    case .download(let url, let mimeType):
      return
        "\(url.absoluteString) is a file download\(mimeType.map { " (\($0))" } ?? ""), which the browser does not save. Fetch it with curl, which does not have this tab's cookies."
    case .unsupportedURL(let url):
      return
        "The page tried to open \(url.absoluteString). The browser loads only web pages and local files."
    case .timedOut: return "Browser request timed out. Inspect the page before repeating an action."
    case .cancelled: return "Browser request cancelled."
    }
  }
}

struct BrowserScripts {
  /// The Playwright runtime and the browser client, evaluated in the client's world the first
  /// time a command needs them in each document.
  let client: String
  /// Forwards console output and uncaught errors from the page's own world, from document start.
  let pageConsole: String
  /// Relays `pageConsole`'s events to the host from the client's world, from document start.
  let consoleRelay: String

  init(directory: URL) throws {
    let injected = try String(
      contentsOf: directory.appendingPathComponent("injected-script.js"), encoding: .utf8)
    let browserClient = try String(
      contentsOf: directory.appendingPathComponent("browser-client.js"), encoding: .utf8)
    client = """
      (() => {
        const module = { exports: {} };
        \(injected)
        \(browserClient)
        const injected = new (module.exports.InjectedScript())(globalThis, {
          browserName: "webkit", sdkLanguage: "javascript", isUnderTest: false,
          testIdAttributeName: "data-testid", stableRafCount: 1, frameSeq: 0, customEngines: []
        });
        globalThis.__browserClient = createBrowserClient(injected);
        return true;
      })();
      """
    // A page that knew the event's name could read or forge console messages.
    let consoleEvent = "c" + UUID().uuidString.lowercased()
    pageConsole = try String(
      contentsOf: directory.appendingPathComponent("page-console.js"), encoding: .utf8
    ).replacingOccurrences(of: "__CONSOLE_EVENT__", with: consoleEvent)
    consoleRelay = """
      (() => {
        const handler = webkit.messageHandlers.browserConsole;
        document.addEventListener('\(consoleEvent)', event => {
          try { handler.postMessage(JSON.parse(event.detail)); } catch {}
        }, true);
      })();
      """
  }
}

#if canImport(UIKit)
  /// Hidden tabs stay in the chat's window so WebKit keeps painting them and running animation
  /// frames. Script focus would then take the keyboard from the chat, so the web view becomes
  /// first responder only while the person has the tab open. Pages still receive focus events.
  final class BrowserWebView: WKWebView {
    var isPresented = false

    override var canBecomeFirstResponder: Bool {
      isPresented && super.canBecomeFirstResponder
    }

    override func becomeFirstResponder() -> Bool {
      isPresented && super.becomeFirstResponder()
    }
  }
#else
  typealias BrowserWebView = WKWebView
#endif

protocol BrowserTabDelegate: AnyObject {
  /// A page opened a window. WebKit loads it into the returned tab, which must use `configuration`.
  func browserTab(
    _ tab: BrowserTab, createTabWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction
  ) -> BrowserTab?
  /// The page called window.close().
  func browserTabDidClose(_ tab: BrowserTab)
}

/// One live WebKit document. The owner supplies main-thread scheduling and serialization.
/// JavaScript runs in an isolated content world; the page retains its ordinary application state.
final class BrowserTab {
  /// The layout size pages see whenever the tab is not open in the browser sheet.
  static let viewport = CGRect(x: 0, y: 0, width: 1100, height: 850)
  static let world = WKContentWorld.world(name: "browser")
  private static let consoleLimit = 200
  /// What WebKit loads itself. Other schemes would go to the system, which installs or opens
  /// other apps (itms-services:, app links).
  private static let loadableSchemes: Set<String> = [
    "http", "https", "file", "about", "data", "blob", "javascript",
  ]

  let id = UUID().uuidString
  let webView: BrowserWebView
  weak var delegate: BrowserTabDelegate?
  /// The tab whose page opened this one; it is selected again when this one closes.
  weak var opener: BrowserTab?
  private(set) var isTerminated = false
  private(set) var consoleMessages = [[String: Any]]()
  private(set) var droppedConsoleMessages = 0
  private let client: String
  private let initialURL: URL?
  private let responder = ObjCResponder()
  private var navigationCompletion: ((Result<Void, Error>) -> Void)?
  private var requestedNavigation: WKNavigation?
  // The running script ends exactly once: with its result, or when its document goes away.
  private var activeScript: Script?
  // A navigation the page started, from a click or its own script. A command waits for it, so
  // the next command sees the page it loaded.
  private var pageNavigation: PageNavigation?
  private var pageNavigationWaiters = [() -> Void]()
  // A main-frame response the tab declined to show, which WebKit then reports as an
  // interrupted load.
  private var declinedDownload: BrowserError?
  // A link with a target opens its window only after an asynchronous policy check, which can
  // finish after the script that clicked it. Commands wait for those windows before reporting.
  private var requestedWindows = 0
  private var requestedWindowWaiters = [() -> Void]()

  private struct Script {
    let id: String
    let completion: (Result<String, Error>) -> Void
    // Once the script returns, its command only waits for the windows and navigation it started,
    // and a new document no longer ends it.
    var hasReturned = false
  }

  private enum PageNavigation {
    // WebKit starts loading after the policy check allows it.
    case pending(WKNavigation?)
    case finished
    case failed(Error)
  }

  init(configuration: WKWebViewConfiguration, client: String, initialURL: URL? = nil) {
    precondition(Thread.isMainThread)
    self.client = client
    self.initialURL = initialURL
    webView = BrowserWebView(frame: Self.viewport, configuration: configuration)
    #if canImport(UIKit)
      // Safe-area insets would shrink the page's viewport while the tab sits in the window.
      webView.scrollView.contentInsetAdjustmentBehavior = .never
    #endif
    responder.tab = self
    webView.navigationDelegate = responder
    webView.uiDelegate = responder
  }

  var metadata: [String: Any] {
    var metadata: [String: Any] = [
      "id": id, "url": (webView.url ?? initialURL)?.absoluteString ?? "about:blank",
      "title": webView.title ?? "",
    ]
    if isTerminated { metadata["crashed"] = true }
    return metadata
  }

  func navigate(
    to url: URL, readAccessURL: URL? = nil, completion: @escaping (Result<Void, Error>) -> Void
  ) {
    load(completion: completion) { [webView] in
      url.isFileURL
        ? webView.loadFileURL(url, allowingReadAccessTo: readAccessURL ?? url)
        : webView.load(URLRequest(url: url))
    }
  }

  /// Reloads the current page; `fromOrigin` bypasses the cache for the page and its resources.
  func reload(fromOrigin: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
    load(completion: completion) { [webView] in
      fromOrigin ? webView.reloadFromOrigin() : webView.reload()
    }
  }

  private func load(
    completion: @escaping (Result<Void, Error>) -> Void, start: () -> WKNavigation?
  ) {
    precondition(Thread.isMainThread)
    guard navigationCompletion == nil else {
      completion(.failure(BrowserError.unavailable("A navigation is already in progress.")))
      return
    }
    isTerminated = false
    pageNavigation = nil
    declinedDownload = nil
    navigationCompletion = completion
    let navigation = start()
    requestedNavigation = navigation
    if navigation == nil {
      finishNavigation(.failure(BrowserError.unavailable("Unable to start navigation.")))
    }
  }

  func run(
    _ script: String, timeoutMs: Int, completion: @escaping (Result<String, Error>) -> Void
  ) {
    precondition(Thread.isMainThread)
    guard !isTerminated else {
      completion(.failure(BrowserError.pageCrashed(webView.url)))
      return
    }
    let requestId = UUID().uuidString
    activeScript = Script(id: requestId, completion: completion)
    // A navigation that already ended was not this script's.
    switch pageNavigation {
    case .pending: break
    default: pageNavigation = nil
    }
    let call = { [webView, id] (handler: @escaping (Result<Any, Error>) -> Void) in
      webView.callAsyncJavaScript(
        """
        const client = globalThis.__browserClient;
        return client ? await client.run(requestId, timeout, script, tabId) : null;
        """,
        arguments: ["requestId": requestId, "timeout": timeoutMs, "script": script, "tabId": id],
        in: nil, in: Self.world, completionHandler: handler)
    }
    let finish: (Result<Any, Error>) -> Void = { [self] result in
      switch result {
      case .success(let output as String):
        guard activeScript?.id == requestId else { return }
        activeScript?.hasReturned = true
        afterRequestedWindows {
          self.afterPageNavigation { navigation in
            self.output(output, after: navigation) { self.finishScript(requestId, .success($0)) }
          }
        }
      case .success:
        finishScript(
          requestId, .failure(BrowserError.script("Browser script returned an invalid result.")))
      case .failure(let error as NSError)
      where error.domain == WKError.errorDomain
        && error.code == WKError.javaScriptResultTypeIsUnsupported.rawValue:
        // The wrapper returns a string or null, so this means the web process took the reply
        // with it. The termination report that follows ends the script and marks the tab.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
          finishScript(requestId, .failure(BrowserError.pageCrashed(webView.url)))
        }
      case .failure(let error):
        finishScript(requestId, .failure(Self.scriptError(error, url: webView.url)))
      }
    }
    call { [self] result in
      // A new document has no client until a command needs one.
      guard case .success(let value) = result, value is NSNull else {
        finish(result)
        return
      }
      // The client could not see a cancellation or a navigation that ended this script while
      // it was missing, so each step of the bootstrap checks that the script is still active.
      guard activeScript?.id == requestId else { return }
      webView.evaluateJavaScript(client, in: nil, in: Self.world) { [self] result in
        guard activeScript?.id == requestId else { return }
        if case .failure(let error) = result {
          finish(.failure(error))
        } else {
          call(finish)
        }
      }
    }
  }

  /// Runs a serialized function in the page's own world for the client's tab.page.evaluate.
  func evaluateInPage(
    _ message: [String: Any], frame: WKFrameInfo, reply: @escaping (Any?, String?) -> Void
  ) {
    guard let source = message["source"] as? String else {
      reply(nil, "page.evaluate needs a function or an expression")
      return
    }
    let body =
      message["isFunction"] as? Bool == false
      ? "return await (\(source));" : "return await (\(source))(...args);"
    webView.callAsyncJavaScript(
      body, arguments: ["args": message["args"] as? [Any] ?? []], in: frame, in: .page
    ) { [webView] result in
      switch result {
      case .success(let value): reply(value, nil)
      case .failure(let error as NSError)
      where error.domain == WKError.errorDomain
        && error.code == WKError.javaScriptResultTypeIsUnsupported.rawValue:
        // undefined, functions, and nodes have no JSON-like form; they arrive as null.
        reply(nil, nil)
      case .failure(let error):
        reply(nil, Self.scriptError(error, url: webView.url).localizedDescription)
      }
    }
  }

  func appendConsoleMessage(_ message: [String: Any]) {
    var entry = message.filter { ["level", "text", "location"].contains($0.key) }
    if let text = entry["text"] as? String, text.count > 2000 {
      entry["text"] = String(text.prefix(2000)) + "…"
    }
    entry["page"] = webView.url?.absoluteString ?? "about:blank"
    consoleMessages.append(entry)
    if consoleMessages.count > Self.consoleLimit {
      consoleMessages.removeFirst()
      droppedConsoleMessages += 1
    }
  }

  func clearConsoleMessages() {
    consoleMessages.removeAll()
    droppedConsoleMessages = 0
  }

  func screenshot(
    fullPage: Bool, completion: @escaping (Result<Data, Error>) -> Void
  ) {
    precondition(Thread.isMainThread)
    guard !isTerminated else {
      completion(.failure(BrowserError.pageCrashed(webView.url)))
      return
    }
    guard fullPage else {
      // iOS lays out pages without a viewport tag wider than the view and scales them down,
      // so the image takes the CSS viewport size rather than the view's.
      webView.evaluateJavaScript("[innerWidth, innerHeight]", in: nil, in: Self.world) {
        [webView] result in
        guard case .success(let value) = result, let size = value as? [NSNumber], size.count == 2
        else {
          completion(.failure(BrowserError.unavailable("The tab has no document to capture.")))
          return
        }
        webView.takeSnapshot(with: nil) { image, error in
          #if canImport(UIKit)
            let cgImage = image?.cgImage
          #else
            let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
          #endif
          guard let cgImage else {
            completion(
              .failure(error ?? BrowserError.unavailable("WebKit did not produce a screenshot.")))
            return
          }
          completion(Self.png(cgImage, width: size[0].intValue, height: size[1].intValue))
        }
      }
      return
    }
    webView.evaluateJavaScript(
      "({width:Math.max(document.documentElement.scrollWidth,innerWidth),height:Math.max(document.documentElement.scrollHeight,innerHeight)})",
      in: nil, in: Self.world
    ) { [webView] result in
      guard case .success(let value) = result, let size = value as? [String: NSNumber],
        let width = size["width"]?.doubleValue, let height = size["height"]?.doubleValue,
        width > 0, height > 0, width * height <= 32_000_000
      else {
        completion(
          .failure(
            BrowserError.unavailable(
              "Full-page capture exceeds the 32 megapixel limit or has no document.")))
        return
      }
      // takeSnapshot only paints the visible WebKit surface. PDF capture also paints
      // content outside the viewport, then rasterizes it without resizing the live tab.
      let configuration = WKPDFConfiguration()
      configuration.rect = CGRect(x: 0, y: 0, width: width, height: height)
      webView.createPDF(configuration: configuration) { result in
        do {
          let pdf = try result.get()
          let rect = CGRect(x: 0, y: 0, width: ceil(width), height: ceil(height))
          guard let provider = CGDataProvider(data: pdf as CFData),
            let document = CGPDFDocument(provider), let page = document.page(at: 1),
            let context = CGContext(
              data: nil, width: Int(rect.width), height: Int(rect.height),
              bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
          else { throw BrowserError.unavailable("Unable to render the full-page capture.") }
          context.setFillColor(CGColor(gray: 1, alpha: 1))
          context.fill(rect)
          context.concatenate(
            page.getDrawingTransform(.mediaBox, rect: rect, rotate: 0, preserveAspectRatio: true))
          context.drawPDFPage(page)
          guard let image = context.makeImage() else {
            throw BrowserError.unavailable("Unable to render the full-page image.")
          }
          completion(Self.png(image, width: image.width, height: image.height))
        } catch { completion(.failure(error)) }
      }
    }
  }

  /// Abandons the navigation and script in progress without calling their completions; the
  /// owner reports the command's outcome. A dispatched DOM event cannot be undone.
  func cancel() {
    precondition(Thread.isMainThread)
    let script = activeScript
    activeScript = nil
    navigationCompletion = nil
    requestedNavigation = nil
    pageNavigation = nil
    pageNavigationWaiters.removeAll()
    declinedDownload = nil
    webView.stopLoading()
    if let script {
      webView.callAsyncJavaScript(
        "globalThis.__browserClient?.cancel(requestId);", arguments: ["requestId": script.id],
        in: nil, in: Self.world, completionHandler: nil)
    }
  }

  /// Runs `action` once the windows this page asked for exist, or after a second if WebKit
  /// blocked one.
  private func afterRequestedWindows(_ action: @escaping () -> Void) {
    guard requestedWindows > 0 else {
      action()
      return
    }
    var isDone = false
    let run = {
      guard !isDone else { return }
      isDone = true
      action()
    }
    requestedWindowWaiters.append(run)
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
      requestedWindows = 0
      run()
    }
  }

  /// Runs `action` with the outcome of the navigation the page started, once it has loaded or
  /// failed, and forgets it.
  private func afterPageNavigation(_ action: @escaping (PageNavigation?) -> Void) {
    if case .pending = pageNavigation {
      pageNavigationWaiters.append { [self] in afterPageNavigation(action) }
      return
    }
    let navigation = pageNavigation
    pageNavigation = nil
    action(navigation)
  }

  private func beginPageNavigation(to url: URL?) {
    // Following a link to a fragment of this document only scrolls it.
    if let url, url.fragment != nil, let current = webView.url {
      var target = URLComponents(url: url, resolvingAgainstBaseURL: false)
      var document = URLComponents(url: current, resolvingAgainstBaseURL: false)
      target?.fragment = nil
      document?.fragment = nil
      if target != nil && target == document { return }
    }
    pageNavigation = .pending(nil)
    // WebKit starts an allowed navigation at once; one it drops would otherwise hold the command.
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
      if case .pending(.none) = pageNavigation { settlePageNavigation(nil) }
    }
  }

  private func settlePageNavigation(_ outcome: PageNavigation?) {
    pageNavigation = outcome
    let waiters = pageNavigationWaiters
    pageNavigationWaiters.removeAll()
    waiters.forEach { $0() }
  }

  /// The script's output after the navigation it started: the address and title of the page it
  /// loaded, or a note that says why it did not load.
  private func output(
    _ output: String, after navigation: PageNavigation?, completion: @escaping (String) -> Void
  ) {
    guard let navigation,
      var object = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
    else {
      completion(output)
      return
    }
    let annotate = { (note: String) in
      object["notes"] = (object["notes"] as? [String] ?? []) + [note]
      guard
        let data = try? JSONSerialization.data(
          withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
      else { return completion(output) }
      completion(String(decoding: data, as: UTF8.self))
    }
    switch navigation {
    case .pending: completion(output)
    case .finished:
      let url = webView.url?.absoluteString ?? "about:blank"
      // WKWebView can still report the previous title when a load finishes.
      webView.evaluateJavaScript("document.title", in: nil, in: Self.world) { result in
        object["url"] = url
        object["title"] = (try? result.get()) as? String ?? ""
        object["documentId"] = nil
        annotate("The page navigated to \(url). Observe it before continuing.")
      }
    case .failed(let error as BrowserError): annotate(error.localizedDescription)
    case .failed(let error):
      annotate("A navigation the page started failed: \(error.localizedDescription)")
    }
  }

  private func finishScript(_ id: String, _ result: Result<String, Error>) {
    guard let activeScript, activeScript.id == id else { return }
    self.activeScript = nil
    activeScript.completion(result)
  }

  private func finishNavigation(_ result: Result<Void, Error>) {
    let completion = navigationCompletion
    navigationCompletion = nil
    requestedNavigation = nil
    completion?(result)
  }

  private static func scriptError(_ error: Error, url: URL?) -> Error {
    let error = error as NSError
    if error.domain == WKError.errorDomain {
      switch error.code {
      case WKError.webContentProcessTerminated.rawValue:
        return BrowserError.pageCrashed(url)
      default: break
      }
    }
    return BrowserError.script(
      error.userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription)
  }

  /// Encodes one image pixel per CSS pixel, so image coordinates match snapshot boxes.
  private static func png(_ image: CGImage, width: Int, height: Int) -> Result<Data, Error> {
    var image = image
    if image.width != width || image.height != height {
      guard width > 0, height > 0,
        let context = CGContext(
          data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return .failure(BrowserError.unavailable("Unable to scale the screenshot.")) }
      context.interpolationQuality = .high
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      guard let scaled = context.makeImage() else {
        return .failure(BrowserError.unavailable("Unable to scale the screenshot."))
      }
      image = scaled
    }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)
    else { return .failure(BrowserError.unavailable("Unable to encode the screenshot PNG.")) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      return .failure(BrowserError.unavailable("Unable to encode the screenshot PNG."))
    }
    return .success(data as Data)
  }

  private final class ObjCResponder: NSObject, WKNavigationDelegate, WKUIDelegate {
    weak var tab: BrowserTab?

    func webView(
      _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
      // No frame or window loads another scheme, whoever started the navigation.
      if let url = navigationAction.request.url, let scheme = url.scheme?.lowercased(),
        !BrowserTab.loadableSchemes.contains(scheme)
      {
        if let tab, navigationAction.targetFrame?.isMainFrame == true,
          tab.navigationCompletion == nil
        {
          tab.settlePageNavigation(.failed(BrowserError.unsupportedURL(url)))
        }
        decisionHandler(.cancel)
        return
      }
      guard let tab, let frame = navigationAction.targetFrame else {
        tab?.requestedWindows += 1
        decisionHandler(.allow)
        return
      }
      // goto and reload report their own navigations.
      guard frame.isMainFrame, tab.navigationCompletion == nil else {
        decisionHandler(.allow)
        return
      }
      if navigationAction.shouldPerformDownload, let url = navigationAction.request.url {
        tab.settlePageNavigation(.failed(BrowserError.download(url, mimeType: nil)))
        decisionHandler(.cancel)
        return
      }
      tab.beginPageNavigation(to: navigationAction.request.url)
      decisionHandler(.allow)
    }

    func webView(
      _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
      decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
      if navigationResponse.isForMainFrame, !navigationResponse.canShowMIMEType,
        let url = navigationResponse.response.url
      {
        tab?.declinedDownload = .download(url, mimeType: navigationResponse.response.mimeType)
        decisionHandler(.cancel)
        return
      }
      decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
      guard let tab, navigation !== tab.requestedNavigation, case .pending = tab.pageNavigation
      else { return }
      tab.pageNavigation = .pending(navigation)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
      // A committed page has a live content process, however its navigation started: the
      // browser window reloads, goes back and forward, and loads addresses directly.
      tab?.isTerminated = false
      // WebKit never answers a script whose document was replaced.
      guard let tab, let activeScript = tab.activeScript, !activeScript.hasReturned else { return }
      tab.finishScript(
        activeScript.id,
        .failure(
          BrowserError.script(
            "The page navigated before the script finished. Inspect the new page before continuing."
          )))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      guard let tab, let navigation else { return }
      if navigation === tab.requestedNavigation {
        tab.finishNavigation(.success(()))
      } else if case .pending(let pending) = tab.pageNavigation, pending === navigation {
        tab.settlePageNavigation(.finished)
      }
    }

    func webView(
      _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
    ) {
      fail(navigation, error)
    }

    func webView(
      _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
      withError error: Error
    ) {
      // A response the tab declined to show fails the load that asked for it.
      let download = tab?.declinedDownload
      tab?.declinedDownload = nil
      fail(navigation, download ?? error)
    }

    private func fail(_ navigation: WKNavigation?, _ error: Error) {
      guard let tab, let navigation else { return }
      if navigation === tab.requestedNavigation {
        tab.finishNavigation(.failure(error))
      } else if case .pending(let pending) = tab.pageNavigation, pending === navigation {
        // A navigation that a newer one replaced, or that the page stopped, has nothing to report.
        let isCancelled =
          (error as NSError).domain == NSURLErrorDomain
          && (error as NSError).code == NSURLErrorCancelled
        tab.settlePageNavigation(isCancelled ? nil : .failed(error))
      }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
      guard let tab else { return }
      // Settle the tab before calling out: a completion can start the next command at once.
      let error = BrowserError.pageCrashed(webView.url)
      let script = tab.activeScript
      let navigation = tab.navigationCompletion
      tab.activeScript = nil
      tab.navigationCompletion = nil
      tab.requestedNavigation = nil
      tab.pageNavigation = nil
      tab.pageNavigationWaiters.removeAll()
      tab.declinedDownload = nil
      tab.isTerminated = true
      script?.completion(.failure(error))
      navigation?(.failure(error))
    }

    func webView(
      _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
      for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
      guard let tab else { return nil }
      defer {
        tab.requestedWindows = max(tab.requestedWindows - 1, 0)
        if tab.requestedWindows == 0 {
          let waiters = tab.requestedWindowWaiters
          tab.requestedWindowWaiters.removeAll()
          waiters.forEach { $0() }
        }
      }
      return tab.delegate?.browserTab(tab, createTabWith: configuration, for: navigationAction)?
        .webView
    }

    func webViewDidClose(_ webView: WKWebView) {
      guard let tab else { return }
      tab.delegate?.browserTabDidClose(tab)
    }

    // Nobody answers dialogs for the agent: they are recorded for console and dismissed.
    func webView(
      _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
      initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void
    ) {
      tab?.appendConsoleMessage(["level": "dialog", "text": "alert: \(message)"])
      completionHandler()
    }

    func webView(
      _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
      initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void
    ) {
      tab?.appendConsoleMessage(["level": "dialog", "text": "confirm (dismissed): \(message)"])
      completionHandler(false)
    }

    func webView(
      _ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
      defaultText: String?, initiatedByFrame frame: WKFrameInfo,
      completionHandler: @escaping (String?) -> Void
    ) {
      tab?.appendConsoleMessage(["level": "dialog", "text": "prompt (dismissed): \(prompt)"])
      completionHandler(nil)
    }
  }
}
