import AppKit
import ArgumentParser
import Darwin
import Foundation
import WebKit
import WebSearch

@main
struct BrowserAPITests {
  static func main() throws {
    precondition(
      CommandLine.arguments.count == 4, "Pass runtime directory, fixture, and output directory")
    _ = NSApplication.shared
    let scripts = try BrowserScripts(directory: URL(fileURLWithPath: CommandLine.arguments[1]))
    let fixture = URL(fileURLWithPath: CommandLine.arguments[2]).resolvingSymlinksInPath()
    let output = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    try checkRequests(fixture: fixture)
    print("Verified request parsing and destination resolution.")
    let session = BrowserSession(scripts: scripts, dataStore: .nonPersistent())
    let silentPort = try silentServerPort()
    let resolvePath = { (path: String) -> (URL, URL)? in
      guard !path.hasPrefix("/forbidden/") else { return nil }
      let url = URL(fileURLWithPath: path).standardizedFileURL
      return (url, url.deletingLastPathComponent())
    }
    var queuedResult: Result<String, Error>?
    var done = false
    var failureMessage: String?
    var nodeId = ""
    var openerId = ""
    var popupId = ""
    var windowId = ""
    var cancelled = false
    var started = Date()
    let elapsed = { Date().timeIntervalSince(started) }
    let run: (String) -> [String] = { ["run", "--code", $0] }
    let cases: [(String, () -> [String], (Result<String, Error>) throws -> Void)] = [
      (
        "navigation and client bootstrap", { ["open", fixture.path] },
        { value in
          let result = try object(value)
          try expect((result["url"] as? String)?.hasSuffix("fixture.html") == true)
          openerId = result["id"] as! String
        }
      ),
      (
        "presents as Safari, with no host objects in the page's world",
        {
          run(
            "async tab => ({userAgent: navigator.userAgent, page: JSON.parse(document.documentElement.dataset.pageIdentity)})"
          )
        },
        { value in
          let result = try scriptResult(value) as! [String: Any]
          try expect(
            (result["userAgent"] as? String)?.hasSuffix(
              "(KHTML, like Gecko) \(SafariUserAgent.desktopApplicationName)") == true)
          let page = result["page"] as! [String: Any]
          try expect(page["webkit"] as? String == "undefined")
          try expect(
            page["consoleNative"] as? Bool == true && page["consoleName"] as? String == "log")
        }
      ),
      (
        "upstream role names and hidden exclusion",
        {
          run(
            "async tab => ({count: await tab.playwright.getByRole('button', {name:'Save profile',exact:true}).count(), label:await tab.playwright.getByLabel('Full name').getAttribute('id')})"
          )
        },
        { value in
          let result = try scriptResult(value) as! [String: Any]
          try expect(result["count"] as? Int == 1 && result["label"] as? String == "name")
          try expect(try object(value)["tab"] as? String == openerId)
        }
      ),
      (
        "controlled input, checkbox, select, and application submission",
        {
          run(
            "async tab => { await tab.playwright.getByLabel('Full name').fill('Liu Liu'); await tab.playwright.getByRole('checkbox', {name:'Enabled'}).check(); await tab.playwright.getByLabel('Country', {exact:true}).selectOption('ca'); await tab.playwright.getByRole('button', {name:'Save profile',exact:true}).click(); return JSON.parse(await tab.playwright.getByRole('status', {name:'Result'}).innerText()); }"
          )
        },
        { value in
          let result = try scriptResult(value) as! [String: Any]
          try expect(result["name"] as? String == "Liu Liu" && result["enabled"] as? Bool == true)
          try expect(result["country"] as? String == "ca" && result["inputEvents"] as? Int == 1)
        }
      ),
      (
        "strict locator rejects ambiguous actions",
        {
          run(
            "async tab => await tab.playwright.getByRole('button',{name:'Duplicate',exact:true}).click()"
          )
        },
        { value in
          try expect(try failure(value).localizedDescription.contains("Strict locator"))
        }
      ),
      (
        "disabled actions honor the Playwright timeout option",
        {
          run(
            "async tab => await tab.playwright.getByRole('button',{name:'Disabled',exact:true}).click({timeout:100})"
          )
        },
        { value in
          try expect(try failure(value).localizedDescription.contains("timed out"))
          // The five-second default would take far longer.
          try expect(elapsed() < 2)
        }
      ),
      (
        "shadow DOM and locator composition",
        {
          run(
            "async tab => {const input=tab.playwright.locator('#shadow').getByTestId('shadow-input'); await input.click(); await input.fill('Shadow'); return {value:await input.inputValue(),clicked:await input.getAttribute('data-clicked')};}"
          )
        },
        { value in
          let result = try scriptResult(value) as! [String: Any]
          try expect(
            result["value"] as? String == "Shadow" && result["clicked"] as? String == "yes")
        }
      ),
      (
        "ARIA snapshot with element refs",
        {
          ["snapshot", "--boxes", "--depth", "5"]
        },
        { value in
          let snapshot = try scriptResult(value) as! String
          try expect(snapshot.contains("Browser API fixture") && snapshot.contains("[ref="))
          try expect(snapshot.contains("[box=") && (try object(value)["notes"]) == nil)
        }
      ),
      (
        "viewport DOM and qualified node IDs", { ["dom"] },
        { value in
          let dom = try scriptResult(value) as! [String: Any]
          let nodes = dom["nodes"] as! [[String: Any]]
          nodeId =
            nodes.first(where: { $0["name"] as? String == "Replace control" })!["node_id"]
            as! String
          try expect(nodeId.contains(":"))
          // Compact entries: no unnamed containers repeating the page text, short text fields.
          try expect(nodes.allSatisfy { ($0["text"] as? String)?.count ?? 0 <= 121 })
          try expect(
            !nodes.contains { $0["role"] as? String == nil && $0["name"] as? String == "" })
        }
      ),
      (
        "DOM node click and re-render",
        {
          run(
            "async tab => { await tab.dom_cua.click({node_id:\(literal(nodeId))}); return await tab.playwright.getByRole('button',{name:'Replacement control'}).count(); }"
          )
        },
        { value in
          let result = try scriptResult(value)
          try expect(result as? Int == 1)
        }
      ),
      (
        "detached ref rejects action",
        { run("async tab => await tab.dom_cua.click({node_id:\(literal(nodeId))})") },
        { value in _ = try failure(value) }
      ),
      (
        "query and inspection", { ["inspect", "#name"] },
        { value in
          let result = try scriptResult(value) as! [String: Any]
          try expect(
            result["value"] as? String == "Liu Liu" && result["role"] as? String == "textbox")
        }
      ),
      (
        "viewport PNG at one pixel per CSS pixel",
        { ["screenshot", "--file", output.appendingPathComponent("viewport.png").path] },
        { value in
          let result = try object(value)
          let data = try Data(contentsOf: URL(fileURLWithPath: result["file"] as! String))
          let bitmap = NSBitmapImageRep(data: data)!
          try expect(bitmap.pixelsWide == 1100 && bitmap.pixelsHigh == 850)
        }
      ),
      (
        "full-page PNG",
        {
          ["screenshot", "--file", output.appendingPathComponent("full.png").path, "--full-page"]
        },
        { value in
          let result = try object(value)
          let bitmap = NSBitmapImageRep(
            data: try Data(contentsOf: URL(fileURLWithPath: result["file"] as! String)))!
          try expect(bitmap.pixelsHigh > 1500)
          let color = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh - 60)!
            .usingColorSpace(.deviceRGB)!
          try expect(color.blueComponent > color.redComponent + 0.3)
        }
      ),
      (
        "screenshot file outside the permitted directories",
        { ["screenshot", "--file", "/forbidden/shot.png"] },
        { value in
          try expect(
            try failure(value).localizedDescription.contains("outside the permitted directories"))
        }
      ),
      (
        "text snapshot stops at the character budget", { ["snapshot", "--max-chars", "300"] },
        { value in
          try expect((try scriptResult(value) as! String).count <= 300)
          try expect(
            (try object(value)["notes"] as? [String])?.first?.contains("--max-chars") == true)
        }
      ),
      (
        "structured snapshot stops at the character budget",
        { ["snapshot", "--json", "--max-chars", "300"] },
        { value in
          let nodes = try scriptResult(value)
          try expect(
            String(decoding: try JSONSerialization.data(withJSONObject: nodes), as: UTF8.self)
              .count < 400)
          try expect((try object(value)["notes"] as? [String])?.isEmpty == false)
        }
      ),
      (
        "DOM listing stops at the character budget", { ["dom", "--max-chars", "400"] },
        { value in
          let dom = try scriptResult(value) as! [String: Any]
          try expect((dom["nodes"] as! [Any]).count < 5)
          try expect((try object(value)["notes"] as? [String])?.isEmpty == false)
        }
      ),
      (
        "click focuses and Tab moves focus",
        {
          run(
            "async tab => { const name = tab.playwright.getByLabel('Full name'); await name.click(); const clicked = document.activeElement.id; await name.press('Tab'); return [clicked, document.activeElement.id]; }"
          )
        },
        { value in
          try expect(try scriptResult(value) as? [String] == ["name", "enabled"])
        }
      ),
      (
        "pointerdown menus open and Escape closes them",
        {
          run(
            "async tab => { await tab.playwright.getByRole('button', {name: 'Actions'}).click(); const opened = await tab.playwright.getByRole('menu').isVisible(); await tab.playwright.keyboard.press('Escape'); return [opened, await tab.playwright.getByRole('menu').isVisible()]; }"
          )
        },
        { value in
          try expect(try scriptResult(value) as? [Bool] == [true, false])
        }
      ),
      (
        "hover enters ancestors and leaves them",
        {
          run(
            "async tab => { await tab.playwright.getByText('Hover target').hover(); const shown = await tab.playwright.getByRole('tooltip').isVisible(); await tab.playwright.getByRole('button', {name: 'Actions'}).hover(); return [shown, await tab.playwright.getByRole('tooltip').isVisible()]; }"
          )
        },
        { value in
          try expect(try scriptResult(value) as? [Bool] == [true, false])
        }
      ),
      (
        "typing and Enter submit a form without a submit button",
        {
          run(
            "async tab => { const query = tab.playwright.getByLabel('Query'); await query.pressSequentially('abc'); await query.press('Enter'); return await tab.playwright.getByRole('status', {name: 'Search outcome'}).innerText(); }"
          )
        },
        { value in
          try expect(try scriptResult(value) as? String == "Searched abc")
        }
      ),
      (
        "key events carry legacy key codes",
        {
          run(
            "async tab => { await tab.page.evaluate(() => { window.legacyCodes = []; for (const type of ['keydown', 'keypress']) document.addEventListener(type, e => legacyCodes.push([e.type, e.key, e.keyCode, e.which, e.charCode].join(' '))); }); const query = tab.playwright.getByLabel('Query'); for (const key of ['a', 'Escape', '/']) await query.press(key); return await tab.page.evaluate(() => legacyCodes); }"
          )
        },
        { value in
          try expect(
            try scriptResult(value) as? [String] == [
              "keydown a 65 65 0", "keypress a 97 97 97", "keydown Escape 27 27 0",
              "keydown / 191 191 0", "keypress / 47 47 47",
            ])
        }
      ),
      (
        "caret, selection, and deletion keys edit a field",
        {
          run(
            "async tab => { const query = tab.playwright.getByLabel('Query'); const values = []; await query.fill('abc'); await query.press('ArrowLeft'); await query.pressSequentially('X'); values.push(await query.inputValue()); await query.press('Meta+A'); await query.pressSequentially('Z'); values.push(await query.inputValue()); await query.fill('one two three'); await query.press('Alt+Backspace'); values.push(await query.inputValue()); await query.press('Home'); await query.pressSequentially('>'); await query.press('Shift+End'); await query.press('Backspace'); values.push(await query.inputValue()); await query.press('Control+A'); await query.press('Delete'); values.push(await query.inputValue()); try { await query.press('ControlOrMeta+Z'); values.push(await query.inputValue()); } catch (error) { values.push(error.message); } return values; }"
          )
        },
        { value in
          let values = try scriptResult(value) as! [String]
          try expect(values.prefix(5) == ["abXc", "Z", "one two ", ">", ""])
          // This web view has no window, so WebKit has no undo manager; undo must say so.
          try expect(values[5].hasSuffix("WebKit had no edit to undo"))
        }
      ),
      (
        "arrows step numbers and navigation keys scroll the page",
        {
          run(
            "async tab => { const quantity = tab.playwright.getByLabel('Quantity'); await quantity.press('ArrowUp'); const stepped = await quantity.inputValue(); await quantity.blur(); const keyboard = tab.playwright.keyboard; await keyboard.press('Home'); await keyboard.press('PageDown'); const paged = scrollY; await keyboard.press('End'); const end = scrollY; await keyboard.press('Home'); return {stepped, paged, end, top: scrollY}; }"
          )
        },
        { value in
          let result = try scriptResult(value) as! [String: Any]
          let paged = result["paged"] as! Double
          try expect(result["stepped"] as? String == "2" && result["top"] as? Double == 0)
          try expect(paged > 700 && paged < 800 && result["end"] as! Double > paged)
        }
      ),
      (
        "keys without a default here are errors",
        {
          run(
            "async tab => { const errors = []; for (const [label, key] of [['Query', 'Meta+C'], ['Country', 'ArrowDown']]) { try { await tab.playwright.getByLabel(label, {exact: true}).press(key); errors.push(null); } catch (error) { errors.push(error.message); } } return errors; }"
          )
        },
        { value in
          let errors = try scriptResult(value) as! [Any]
          try expect((errors[0] as? String)?.contains("no clipboard") == true)
          try expect((errors[1] as? String)?.contains("selectOption") == true)
        }
      ),
      (
        "page globals through page.evaluate, DOM through the isolated world",
        {
          run(
            "async tab => ({page: await tab.page.evaluate(() => window.appState.count), isolated: await tab.playwright.evaluate(() => typeof window.appState), expression: await tab.page.evaluate('document.title'), doubled: await tab.page.evaluate(n => n * 2, 21), missing: await tab.page.evaluate(() => undefined)})"
          )
        },
        { value in
          let result = try scriptResult(value) as! [String: Any]
          try expect(result["page"] as? Int == 3 && result["isolated"] as? String == "undefined")
          try expect(result["expression"] as? String == "Browser API fixture")
          try expect(result["doubled"] as? Int == 42 && result["missing"] is NSNull)
        }
      ),
      (
        "dialogs are dismissed",
        {
          run(
            "async tab => { const button = tab.playwright.getByRole('button', {name: 'Confirm delete'}); await button.click(); return await button.getAttribute('data-confirmed'); }"
          )
        },
        { value in
          try expect(try scriptResult(value) as? String == "false")
        }
      ),
      (
        "console output, errors, and dialogs", { ["console", "--clear"] },
        { value in
          let messages = try object(value)["messages"] as! [[String: Any]]
          try expect(
            messages.contains {
              $0["level"] as? String == "error" && $0["text"] as? String == "fixture error"
            })
          try expect(
            messages.contains {
              $0["level"] as? String == "dialog"
                && $0["text"] as? String == "confirm (dismissed): Delete everything?"
            })
        }
      ),
      (
        "console clears", { ["console"] },
        { value in
          try expect((try object(value)["messages"] as! [Any]).isEmpty)
        }
      ),
      (
        "a link opens a selected tab",
        {
          run("async tab => await tab.playwright.getByRole('link', {name: 'Open popup'}).click()")
        },
        { value in
          guard let opened = try object(value)["openedTabs"] as? [[String: Any]] else {
            throw BrowserError.script("No openedTabs with \(session.tabs.count) tabs")
          }
          try expect(opened.count == 1)
          popupId = opened[0]["id"] as! String
          try expect((opened[0]["url"] as? String)?.hasSuffix("popup.html") == true)
        }
      ),
      (
        "tabs report the selection", { ["tabs"] },
        { value in
          let tabs =
            try JSONSerialization.jsonObject(with: Data(value.get().utf8)) as! [[String: Any]]
          try expect(tabs.count == 2)
          try expect(
            tabs.first(where: { $0["selected"] as? Bool == true })?["id"] as? String == popupId)
        }
      ),
      (
        "tabs --tab switches tabs", { ["tabs", "--tab", openerId] },
        { value in
          let tabs =
            try JSONSerialization.jsonObject(with: Data(value.get().utf8)) as! [[String: Any]]
          try expect(
            tabs.first(where: { $0["selected"] as? Bool == true })?["id"] as? String == openerId)
        }
      ),
      (
        "tabs --tab rejects an unknown tab", { ["tabs", "--tab", "missing"] },
        { value in
          try expect(try failure(value).localizedDescription.contains("No matching tab"))
        }
      ),
      (
        "addressing a tab selects it",
        {
          [
            "run", "--tab", openerId, "--code",
            "async tab => { await new Promise(r => setTimeout(r, 500)); return tab.id; }",
          ]
        },
        { value in
          try expect(try scriptResult(value) as? String == openerId)
        }
      ),
      (
        "the opened tab loaded its page",
        { ["run", "--tab", popupId, "--code", "async tab => await tab.title()"] },
        { value in
          try expect(try scriptResult(value) as? String == "Popup page")
        }
      ),
      (
        "window.open opens a tab",
        {
          [
            "run", "--tab", openerId, "--code",
            "async tab => { await tab.playwright.getByRole('button', {name: 'Open window'}).click(); await new Promise(r => setTimeout(r, 500)); }",
          ]
        },
        { value in
          let opened = try object(value)["openedTabs"] as! [[String: Any]]
          try expect(opened.count == 1)
          windowId = opened[0]["id"] as! String
        }
      ),
      (
        "window.close closes the tab and selects its opener",
        {
          run(
            "async tab => { await tab.playwright.getByRole('button', {name: 'Close window'}).click(); await new Promise(r => setTimeout(r, 2000)); }"
          )
        },
        { value in
          try expect(try failure(value).localizedDescription.contains("closed its tab"))
          try expect(session.tabs.count == 2 && !session.tabs.contains { $0.id == windowId })
        }
      ),
      (
        "close selects the opener", { ["close", "--tab", popupId] },
        { value in
          try expect(try object(value)["selected"] as? String == openerId)
        }
      ),
      (
        "a click that loads a page reports the new page",
        {
          run(
            "async tab => await tab.playwright.getByRole('link', {name: 'Same tab link'}).click()")
        },
        { value in
          let output = try object(value)
          try expect((output["url"] as? String)?.hasSuffix("popup.html") == true)
          try expect(output["title"] as? String == "Popup page")
          try expect((output["notes"] as? [String])?.first?.contains("navigated") == true)
        }
      ),
      ("return to the fixture", { ["goto", fixture.path] }, { value in _ = try value.get() }),
      (
        "a form submission that loads a page reports the new page",
        {
          run(
            "async tab => await tab.playwright.getByRole('button', {name: 'Submit to popup'}).click()"
          )
        },
        { value in
          let output = try object(value)
          try expect((output["url"] as? String)?.contains("popup.html") == true)
          try expect(output["title"] as? String == "Popup page")
          try expect((output["notes"] as? [String])?.first?.contains("navigated") == true)
        }
      ),
      ("return to the fixture", { ["goto", fixture.path] }, { value in _ = try value.get() }),
      (
        "a download link reports its file",
        {
          run(
            "async tab => await tab.playwright.getByRole('link', {name: 'Download archive'}).click()"
          )
        },
        { value in
          let output = try object(value)
          try expect((output["url"] as? String)?.hasSuffix("fixture.html") == true)
          try expect(
            (output["notes"] as? [String])?.first?.contains("archive.zip is a file download")
              == true)
        }
      ),
      (
        "goto a download names the file",
        {
          ["goto", fixture.deletingLastPathComponent().appendingPathComponent("archive.zip").path]
        },
        { value in
          try expect(
            try failure(value).localizedDescription.contains("archive.zip is a file download"))
        }
      ),
      (
        "a navigation during a script is reported",
        {
          run(
            "async tab => { await tab.playwright.getByRole('link', {name: 'Same tab link'}).click(); await new Promise(r => setTimeout(r, 5000)); }"
          )
        },
        { value in
          try expect(try failure(value).localizedDescription.contains("navigated"))
          try expect(elapsed() < 4)
        }
      ),
      (
        "navigation invalidates DOM node IDs", { ["goto", fixture.path] },
        { value in _ = try value.get() }
      ),
      (
        "stale document ref rejects action",
        { run("async tab => await tab.dom_cua.click({node_id:\(literal(nodeId))})") },
        { value in
          try expect(try failure(value).localizedDescription.contains("Stale DOM node"))
        }
      ),
      (
        "cancel ends pending locator work",
        {
          _ = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { _ in cancelled = true }
          return run(
            "async tab => {await tab.playwright.getByRole('button',{name:'Cancellation target'}).waitFor(); await tab.playwright.getByLabel('Full name').fill('Should not happen');}"
          )
        },
        { value in
          let error = try failure(value)
          try expect(error is BrowserError && error.localizedDescription.contains("cancelled"))
          cancelled = false
        }
      ),
      (
        "next command cannot revive cancelled actions",
        {
          run(
            "async tab => {await tab.playwright.evaluate(() => {const button=document.createElement('button'); button.textContent='Cancellation target'; document.body.append(button);}); await new Promise(resolve=>setTimeout(resolve,200)); return await tab.playwright.getByLabel('Full name').inputValue();}"
          )
        },
        { value in
          let result = try scriptResult(value)
          try expect(result as? String == "Initial")
        }
      ),
      (
        "a crashed page fails the running command at once",
        {
          _ = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in
            // Kill the WebContent process the way jetsam does; WebKit reports only
            // terminations that its client did not request.
            let pid = session.tabs.first!.webView.value(forKey: "_webProcessIdentifier") as! Int32
            precondition(pid > 0 && kill(pid, SIGKILL) == 0, "Unable to kill the web process")
          }
          return run("async tab => await new Promise(r => setTimeout(r, 10000))")
        },
        { value in
          try expect(try failure(value).localizedDescription.contains("web process ended"))
          try expect(elapsed() < 5)
        }
      ),
      (
        "a crashed tab says so", { ["tabs"] },
        { value in
          let tabs =
            try JSONSerialization.jsonObject(with: Data(value.get().utf8)) as! [[String: Any]]
          try expect(tabs.first?["crashed"] as? Bool == true)
        }
      ),
      (
        "goto reloads a crashed tab", { ["goto", fixture.path] },
        { value in
          try expect(try object(value)["crashed"] == nil)
        }
      ),
      (
        "a command cancelled during client bootstrap does not run",
        {
          // The goto above replaced the document, so this script must install the client first.
          let tab = session.tabs.first!
          tab.run(
            "async tab => await tab.playwright.getByLabel('Full name').fill('Cancelled')",
            timeoutMs: 5000
          ) { _ in }
          tab.cancel()
          return run(
            "async tab => { await new Promise(r => setTimeout(r, 500)); return await tab.playwright.getByLabel('Full name').inputValue(); }"
          )
        },
        { value in
          try expect(try scriptResult(value) as? String == "Initial")
        }
      ),
      (
        "a screenshot cancelled while the page is busy",
        {
          // The web process answers the capture only after this loop, well after cancellation.
          session.tabs.first!.webView.evaluateJavaScript(
            "{ const end = Date.now() + 700; while (Date.now() < end); }")
          _ = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { _ in cancelled = true }
          return ["screenshot", "--file", output.appendingPathComponent("cancelled.png").path]
        },
        { value in
          try expect(try failure(value).localizedDescription.contains("cancelled"))
          cancelled = false
        }
      ),
      (
        "a cancelled screenshot writes no file",
        { run("async tab => await new Promise(r => setTimeout(r, 1000))") },
        { value in
          _ = try value.get()
          try expect(
            !FileManager.default.fileExists(
              atPath: output.appendingPathComponent("cancelled.png").path))
        }
      ),
      (
        "a cancelled navigation leaves the next command intact",
        {
          DispatchQueue.main.async {
            session.execute(
              arguments: run("async tab => location.pathname"), resolvePath: resolvePath,
              isCancelled: { false }
            ) { queuedResult = $0 }
          }
          _ = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in cancelled = true }
          return ["goto", "http://127.0.0.1:\(silentPort)/"]
        },
        { value in
          try expect(try failure(value).localizedDescription.contains("cancelled"))
          cancelled = false
        }
      ),
      (
        "the command queued behind the navigation ran", { ["tabs"] },
        { value in
          _ = try value.get()
          let path = try queuedResult.map { try scriptResult($0) } as? String
          try expect(path?.hasSuffix("fixture.html") == true)
        }
      ),
      (
        "tabs persist between commands", { ["tabs"] },
        { value in
          let tabs =
            try JSONSerialization.jsonObject(with: Data(value.get().utf8)) as! [[String: Any]]
          try expect(tabs.count == 1)
        }
      ),
      (
        "close releases tab", { ["close"] },
        { value in
          _ = try value.get()
          try expect(session.tabs.isEmpty)
        }
      ),
    ]
    var index = 0
    var next: (() -> Void)!
    next = {
      guard index < cases.count else {
        done = true
        return
      }
      let (name, arguments, validate) = cases[index]
      index += 1
      started = Date()
      session.execute(
        arguments: arguments(),
        resolvePath: resolvePath, isCancelled: { cancelled }
      ) { result in
        do {
          try validate(result)
          print("PASS: \(name)")
          next()
        } catch {
          failureMessage = "\(name): \(error.localizedDescription) (\(result))"
          done = true
        }
      }
    }
    next()
    while !done { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    if let failureMessage {
      fputs(failureMessage + "\n", stderr)
      _Exit(1)
    }
    print("Verified \(cases.count) browser API cases on real WKWebView.")
    do {
      try BrowserBashTests.run(session: session, fixture: fixture, output: output)
    } catch {
      fputs("\(error.localizedDescription)\n", stderr)
      fflush(nil)
      _Exit(1)
    }
    fflush(nil)
    // ios_system overrides exit() for its shell threads.
    _Exit(0)
  }

  private static func checkRequests(fixture: URL) throws {
    let parse = { (arguments: [String]) in try BrowserRequest(arguments: arguments) }
    try expect(try parse(["run", "--code", "--tab"]).command == .run(.code("--tab")))
    try expect(try parse(["snapshot", "--tab", "a", "--json"]).tabId == "a")
    try expect(try parse(["tabs", "--tab", "a"]).tabId == "a")
    try expect(
      try parse(["screenshot", "--file", "a.png", "--inline"]).command
        == .screenshot(file: "a.png", inline: true, fullPage: false))
    // Rejections and help leave ArgumentParser's message and exit status to web_browse_main.
    let rejection = { (arguments: [String]) throws -> (status: Int32, message: String) in
      do {
        _ = try parse(arguments)
      } catch {
        return (
          BrowserCommand.exitCode(for: error).rawValue, BrowserCommand.fullMessage(for: error)
        )
      }
      throw BrowserError.script("Accepted \(arguments)")
    }
    for invalid in [
      ["snapshot", "--depth", "0"], ["open", "a", "--tab", "b"], ["run"], ["dom", "extra"],
      ["tabs", "--json"], ["navigate"], ["run", "--code", "1", "--file", "a.js"],
    ] {
      try expect(try rejection(invalid).status == 64)
    }
    try expect(try rejection(["snapshot", "--depth", "0"]).message.contains("at least 1"))
    for help in [[], ["--help"], ["help"]] {
      let (status, message) = try rejection(help)
      try expect(status == 0 && message.contains("SUBCOMMANDS:") && message.contains("screenshot"))
    }
    let (status, message) = try rejection(["help", "snapshot"])
    try expect(status == 0 && message.contains("--max-chars"))
    let resolve = { (path: String) -> (URL, URL)? in
      guard !path.hasPrefix("/forbidden/") else { return nil }
      let url = URL(fileURLWithPath: path, relativeTo: fixture.deletingLastPathComponent())
        .standardizedFileURL
      return (url, url.deletingLastPathComponent())
    }
    let destination = { (argument: String) in
      try BrowserSession.destination(argument, resolvePath: resolve).url.absoluteString
    }
    try expect(try destination("example.com/docs") == "https://example.com/docs")
    try expect(try destination("localhost:5173") == "http://localhost:5173")
    try expect(try destination("127.0.0.1:8000/app") == "http://127.0.0.1:8000/app")
    try expect(try destination("https://example.com") == "https://example.com")
    try expect(try destination("fixture.html") == fixture.absoluteString)
    for (argument, message) in [
      ("missing.html", "No such file"), ("javascript:alert(1)", "Unsupported URL scheme"),
      ("/forbidden/page.html", "outside the permitted directories"),
    ] {
      do {
        _ = try destination(argument)
        throw BrowserError.script("Resolved \(argument)")
      } catch let error as BrowserError {
        try expect(error.localizedDescription.contains(message))
      }
    }
  }

  /// Accepts connections and never answers, so a navigation to it stays in flight.
  private static func silentServerPort() throws -> UInt16 {
    let listener = socket(AF_INET, SOCK_STREAM, 0)
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let isListening = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(listener, $0, length) == 0 && listen(listener, 8) == 0
          && getsockname(listener, $0, &length) == 0
      }
    }
    guard listener >= 0, isListening else {
      throw BrowserError.script("Unable to listen on 127.0.0.1")
    }
    return UInt16(bigEndian: address.sin_port)
  }

  private static func expect(
    _ condition: @autoclosure () throws -> Bool, file: String = #fileID, line: Int = #line
  ) throws {
    if !(try condition()) { throw BrowserError.script("Assertion failed at \(file):\(line)") }
  }

  private static func failure(_ result: Result<String, Error>) throws -> Error {
    guard case .failure(let error) = result else {
      throw BrowserError.script("Expected a failure")
    }
    return error
  }

  private static func object(_ result: Result<String, Error>) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data(result.get().utf8)) as! [String: Any]
  }
  private static func scriptResult(_ result: Result<String, Error>) throws -> Any {
    try object(result)["result"]!
  }
  private static func literal(_ text: String) -> String {
    String(
      decoding: try! JSONSerialization.data(withJSONObject: text, options: .fragmentsAllowed),
      as: UTF8.self)
  }
}
