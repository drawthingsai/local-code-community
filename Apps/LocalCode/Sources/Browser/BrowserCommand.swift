import ArgumentParser
import BashToolContext
import Darwin
import Foundation
import ios_system

/// The single ios_system entry. Only this synchronous command boundary waits for WebKit callbacks.
func web_browse_main(
  _ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32 {
  var previous: Int32 = 0
  pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, &previous)
  defer { pthread_setcancelstate(previous, nil) }
  return autoreleasepool {
    guard let argv, argc > 0 else { return 2 }
    let arguments = (1..<Int(argc)).compactMap { argv[$0].map { String(cString: $0) } }
    let output = ios_stdout() ?? stdout
    let errors = ios_stderr() ?? stderr
    // Help and usage errors need no browser. ArgumentParser's `exit` would end the host app, so
    // its message and status are returned instead.
    do {
      _ = try BrowserRequest(arguments: arguments)
    } catch {
      let status = BrowserCommand.exitCode(for: error).rawValue
      fputs(BrowserCommand.fullMessage(for: error) + "\n", status == 0 ? output : errors)
      return status
    }
    guard !Thread.isMainThread, let context = BashToolContext.current,
      let browseWeb = context.browseWeb
    else {
      fputs("web-browse-cli: browser commands require a Local Code app chat.\n", errors)
      return 1
    }
    let cancellation = ios_getCommandCancellationContext()
    let isCancelled = { ios_commandCancellationRequested(cancellation) != 0 }
    guard !isCancelled() else { return 130 }
    let directory = URL(
      fileURLWithPath: ios_getenv("PWD").map { String(cString: $0) }
        ?? context.projectURL?.path ?? FileManager.default.currentDirectoryPath,
      isDirectory: true)
    let group = DispatchGroup()
    var result: Result<String, Error>?
    group.enter()
    // BashToolContext carries the arguments as typed; the session parses them again.
    browseWeb(arguments, directory, context.projectURL, context.threadId, isCancelled) {
      result = $0
      group.leave()
    }
    group.wait()
    guard !isCancelled() else { return 130 }
    switch result {
    case .success(let text):
      fputs(text + "\n", output)
      return 0
    case .failure(let error):
      fputs("web-browse-cli: \(error.localizedDescription)\n", errors)
      return 1
    case nil: return 1
    }
  }
}

/// One web-browse-cli invocation. Paths and URLs stay as typed until the session resolves them.
struct BrowserRequest: Equatable {
  enum Script: Equatable {
    case code(String)
    case file(String)
  }

  enum Command: Equatable {
    case tabs
    case open(String)
    case goto(String)
    case reload(fromOrigin: Bool)
    case close
    case show
    case snapshot(json: Bool, boxes: Bool, depth: Int?, maxChars: Int?, image: Bool)
    case dom(maxChars: Int?)
    case inspect(String)
    case run(Script)
    case console(clear: Bool)
    case screenshot(file: String?, inline: Bool, fullPage: Bool)
    case clearCache
  }

  let command: Command
  let tabId: String?
}

extension BrowserRequest {
  /// Throws ArgumentParser's errors, including the CleanExit that carries help.
  init(arguments: [String]) throws {
    var command = try BrowserCommand.parseAsRoot(arguments)
    guard let subcommand = command as? BrowserSubcommand else {
      // The bare command and the help subcommand throw their help.
      try command.run()
      throw CleanExit.helpRequest(command)
    }
    self = subcommand.request
  }
}

/// A web-browse-cli subcommand. The session performs its request.
protocol BrowserSubcommand: ParsableCommand {
  var request: BrowserRequest { get }
}

struct BrowserCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "web-browse-cli",
    abstract: "Open and drive the browser tabs this chat keeps.",
    discussion: """
      --tab <id> addresses a tab and selects it for later commands. A tab a page opens is \
      selected and listed under openedTabs. Bare hosts such as localhost:5173 or example.com \
      are web addresses unless a file by that name exists.

      API: tab.playwright.getByRole, getByLabel, getByText, and locator; click, hover, fill, \
      press, pressSequentially, check, selectOption, and waitFor; tab.playwright.keyboard.press \
      and type; tab.playwright.evaluate (DOM, isolated world); tab.page.evaluate (page \
      globals); tab.dom_cua.get_visible_dom, click, and scroll. Options use Playwright names \
      such as timeout.

      Results are JSON; snapshots and dom stop at 20000 characters unless --max-chars is \
      given. screenshot returns an inline PNG to bash unless --file is used; add --inline to \
      also see it. WebKit input uses DOM events. Tabs last while the app runs; cookies, the \
      cache, and other site data are shared by this project's chats and kept between launches.
      """,
    subcommands: [
      Open.self, Goto.self, Reload.self, Tabs.self, Snapshot.self, Dom.self, Inspect.self,
      Run.self, Console.self, Screenshot.self, Show.self, Close.self, ClearCache.self,
    ])

  struct Target: ParsableArguments {
    @Option(
      help: ArgumentHelp("Address this tab and select it for later commands.", valueName: "id"))
    var tab: String?
  }

  struct Open: BrowserSubcommand {
    static let configuration = CommandConfiguration(
      abstract: "Create a tab, select it, and navigate.")

    @Argument(help: ArgumentHelp("A URL, a bare host, or a local HTML file.", valueName: "url"))
    var destination: String

    var request: BrowserRequest { BrowserRequest(command: .open(destination), tabId: nil) }
  }

  struct Goto: BrowserSubcommand {
    static let configuration = CommandConfiguration(abstract: "Navigate the selected tab.")

    @Argument(help: ArgumentHelp("A URL, a bare host, or a local HTML file.", valueName: "url"))
    var destination: String
    @OptionGroup var target: Target

    var request: BrowserRequest { BrowserRequest(command: .goto(destination), tabId: target.tab) }
  }

  struct Reload: BrowserSubcommand {
    static let configuration = CommandConfiguration(abstract: "Reload the selected tab.")

    @Flag(help: "Load the page and its resources from their servers, bypassing the cache.")
    var fromOrigin = false
    @OptionGroup var target: Target

    var request: BrowserRequest {
      BrowserRequest(command: .reload(fromOrigin: fromOrigin), tabId: target.tab)
    }
  }

  struct Tabs: BrowserSubcommand {
    static let configuration = CommandConfiguration(
      abstract: "List tabs and which one is selected; --tab <id> switches tabs.")

    @OptionGroup var target: Target

    var request: BrowserRequest { BrowserRequest(command: .tabs, tabId: target.tab) }
  }

  struct Snapshot: BrowserSubcommand {
    static let configuration = CommandConfiguration(
      abstract: "Accessibility text with element references.")

    @Flag(help: "Return structured nodes.") var json = false
    @Flag(help: "Add each element's bounds.") var boxes = false
    @Option(help: ArgumentHelp("Stop at this depth.", valueName: "n")) var depth: Int?
    @Option(help: ArgumentHelp("Stop at this many characters.", valueName: "n")) var maxChars: Int?
    @Flag(help: "Also return the viewport PNG.") var image = false
    @OptionGroup var target: Target

    func validate() throws {
      guard depth ?? 1 > 0 else { throw ValidationError("--depth must be at least 1.") }
      guard maxChars ?? 1 > 0 else { throw ValidationError("--max-chars must be at least 1.") }
    }

    var request: BrowserRequest {
      BrowserRequest(
        command: .snapshot(
          json: json, boxes: boxes, depth: depth, maxChars: maxChars, image: image),
        tabId: target.tab)
    }
  }

  struct Dom: BrowserSubcommand {
    static let configuration = CommandConfiguration(
      abstract: "Visible elements with node IDs and bounds.")

    @Option(help: ArgumentHelp("Stop at this many characters.", valueName: "n")) var maxChars: Int?
    @OptionGroup var target: Target

    func validate() throws {
      guard maxChars ?? 1 > 0 else { throw ValidationError("--max-chars must be at least 1.") }
    }

    var request: BrowserRequest {
      BrowserRequest(command: .dom(maxChars: maxChars), tabId: target.tab)
    }
  }

  struct Inspect: BrowserSubcommand {
    static let configuration = CommandConfiguration(abstract: "Inspect one Playwright locator.")

    @Argument(help: "A Playwright selector.") var selector: String
    @OptionGroup var target: Target

    var request: BrowserRequest { BrowserRequest(command: .inspect(selector), tabId: target.tab) }
  }

  struct Run: BrowserSubcommand {
    static let configuration = CommandConfiguration(
      abstract: "Execute an async (tab) => ... function.")

    @Option(
      parsing: .unconditional,
      help: ArgumentHelp("The function's source.", valueName: "function"))
    var code: String?
    @Option(help: ArgumentHelp("A file that holds the function.", valueName: "script.js"))
    var file: String?
    @OptionGroup var target: Target

    func validate() throws {
      guard (code == nil) != (file == nil) else {
        throw ValidationError("run needs --code '<function>' or --file <script.js>.")
      }
    }

    var request: BrowserRequest {
      BrowserRequest(command: .run(file.map { .file($0) } ?? .code(code ?? "")), tabId: target.tab)
    }
  }

  struct Console: BrowserSubcommand {
    static let configuration = CommandConfiguration(
      abstract: "Page console output, errors, and dialogs.")

    @Flag(help: "Empty the log after reading it.") var clear = false
    @OptionGroup var target: Target

    var request: BrowserRequest {
      BrowserRequest(command: .console(clear: clear), tabId: target.tab)
    }
  }

  struct Screenshot: BrowserSubcommand {
    static let configuration = CommandConfiguration(
      abstract: "Capture the viewport as a PNG, returned inline to bash.")

    @Flag(help: "Return the PNG inline as well as saving it.") var inline = false
    @Option(help: ArgumentHelp("Save the PNG instead of returning it.", valueName: "path.png"))
    var file: String?
    @Flag(help: "Capture the whole page.") var fullPage = false
    @OptionGroup var target: Target

    var request: BrowserRequest {
      BrowserRequest(
        command: .screenshot(file: file, inline: inline, fullPage: fullPage), tabId: target.tab)
    }
  }

  struct Show: BrowserSubcommand {
    static let configuration = CommandConfiguration(
      abstract: "Present the live tab for inspection.")

    @OptionGroup var target: Target

    var request: BrowserRequest { BrowserRequest(command: .show, tabId: target.tab) }
  }

  struct Close: BrowserSubcommand {
    static let configuration = CommandConfiguration(abstract: "Close the selected tab.")

    @OptionGroup var target: Target

    var request: BrowserRequest { BrowserRequest(command: .close, tabId: target.tab) }
  }

  struct ClearCache: BrowserSubcommand {
    static let configuration = CommandConfiguration(
      abstract: "Empty the cache this project's chats share; cookies and site storage stay.")

    var request: BrowserRequest { BrowserRequest(command: .clearCache, tabId: nil) }
  }
}
