import AppKit
import BashToolContext
import Foundation
import ProjectHistoryManager
import ios_system

enum BrowserBashTests {
  static func run(session: BrowserSession, fixture: URL, output: URL) throws {
    initializeEnvironment()
    guard ios_registerCommand("web-browse-cli", web_browse_main) != 0 else {
      throw BrowserError.unavailable("Could not register the browser command")
    }
    let context = BashToolContext(
      projectURL: output,
      browseWeb: { arguments, directory, _, _, isCancelled, completion in
        DispatchQueue.main.async {
          let resolver = LocalPathResolver(
            projectPath: directory.path, workspacePath: output.path,
            permittedDirectoryURLs: [fixture.deletingLastPathComponent()])
          session.execute(
            arguments: arguments,
            resolvePath: { resolver.resolve($0).map { ($0.url, $0.rootURL) } },
            isCancelled: isCancelled, completion: completion)
        }
      }, permittedDirectoryURLs: { [fixture.deletingLastPathComponent()] })
    let saved = output.appendingPathComponent("bash-screenshot.png")
    let fileOnly = output.appendingPathComponent("bash-file-only.png")
    let cases: [(String, String, Bool, (ToolResponse) throws -> Void)] = [
      (
        "help answers without the browser", "web-browse-cli --help", false,
        { try expect(text($0).contains("SUBCOMMANDS:") && text($0).contains("--tab <id>")) }
      ),
      (
        "shell navigation", "web-browse-cli open \(quote(fixture.path))", true,
        { try expect(text($0).contains("fixture.html")) }
      ),
      (
        "ARIA and viewport image in one bash response",
        "web-browse-cli snapshot --image --boxes", true,
        { response in
          let text = text(response)
          try expect(text.contains("Browser API fixture") && text.contains("[ref="))
          try expect(text.contains("[box="))
          let bitmap = try bitmap(response, project: output)
          try expect(bitmap.pixelsWide > 100 && bitmap.pixelsHigh > 100)
        }
      ),
      (
        "structured snapshot with image", "web-browse-cli snapshot --json --image", true,
        { response in
          try expect(
            text(response).contains("\"result\":") && text(response).contains("Browser API fixture")
          )
          _ = try bitmap(response, project: output)
        }
      ),
      (
        "default inline viewport screenshot", "web-browse-cli screenshot", true,
        { response in
          let bitmap = try bitmap(response, project: output)
          try expect(bitmap.pixelsWide > 100 && bitmap.pixelsHigh > 100)
        }
      ),
      (
        "save and display the same PNG",
        "web-browse-cli screenshot --file \(quote(saved.path)) --inline", true,
        { response in
          try expect(try png(response, project: output) == Data(contentsOf: saved))
          try expect(text(response).contains(saved.lastPathComponent))
        }
      ),
      (
        "file output remains text only",
        "web-browse-cli screenshot --file \(quote(fileOnly.path))", true,
        { response in
          try expect(digests(response).isEmpty)
          try expect(NSBitmapImageRep(data: Data(contentsOf: fileOnly)) != nil)
        }
      ),
      (
        "full-page inline screenshot", "web-browse-cli screenshot --full-page", true,
        { response in
          let bitmap = try bitmap(response, project: output)
          try expect(bitmap.pixelsHigh > 1500)
          let color = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh - 60)!
            .usingColorSpace(.deviceRGB)!
          try expect(color.blueComponent > color.redComponent + 0.3)
        }
      ),
      (
        "text-only model does not receive base64", "web-browse-cli screenshot", false,
        { response in
          try expect(digests(response).isEmpty)
          try expect(!text(response).contains("iVBOR") && !text(response).contains("1337;File="))
        }
      ),
    ]
    var index = 0
    var done = false
    var failure: Error?
    var next: (() -> Void)!
    next = {
      guard index < cases.count else {
        done = true
        return
      }
      let (name, command, supportsImages, validate) = cases[index]
      index += 1
      var content = [ToolResponse.Content]()
      func consume(_ response: ToolResponse) {
        DispatchQueue.main.async {
          content.append(contentsOf: response.content)
          do {
            let report = text(response)
            guard let line = report.components(separatedBy: "\n").first,
              line.hasPrefix("job="), let job = Int(line.dropFirst(4))
            else { throw BrowserError.script("Missing bash job: \(report)") }
            if report.contains("status=running") || report.contains("status=pending") {
              BashWaitTool(jobID: job, refresh: 30).invoke(completion: consume)
              return
            }
            try expect(report.contains("exit=0"))
            let combined = ToolResponse(content)
            try expect(!text(combined).contains("1337;File=") && !text(combined).contains("iVBOR"))
            try validate(combined)
            BashStatusTool(jobID: job).invoke { repeated in
              do {
                try expect(digests(repeated).isEmpty)
                print("PASS: \(name)")
                next()
              } catch {
                failure = error
                done = true
              }
            }
          } catch {
            failure = BrowserError.script("\(name): \(error.localizedDescription)")
            done = true
          }
        }
      }
      // Capture immediately, then consume through bash_wait while WebKit finishes.
      BashTool(
        command: command, timeout: 30, refresh: 0,
        projectPath: output.path, workspacePath: output.path
      ).invoke(context: context, isImageSupported: supportsImages, completion: consume)
    }
    next()
    let deadline = Date().addingTimeInterval(60)
    while !done && Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    guard done else { throw BrowserError.timedOut }
    if let failure { throw failure }
    print(
      "Verified \(cases.count) browser commands through bash capture and the project image store.")
  }

  private static func quote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  private static func text(_ response: ToolResponse) -> String {
    response.content.compactMap {
      if case .text(let text) = $0 { return text }
      return nil
    }.joined(separator: "\n")
  }

  private static func digests(_ response: ToolResponse) -> [Data] {
    response.content.compactMap {
      if case .imageDigest(let digest) = $0 { return digest }
      return nil
    }
  }

  private static func png(_ response: ToolResponse, project: URL) throws -> Data {
    let images = digests(response)
    try expect(images.count == 1)
    let path = EmbedsFileStore(projectPath: project.path).filePath(for: images[0])
    return try Data(contentsOf: URL(fileURLWithPath: path))
  }

  private static func bitmap(_ response: ToolResponse, project: URL) throws -> NSBitmapImageRep {
    guard let image = NSBitmapImageRep(data: try png(response, project: project)) else {
      throw BrowserError.script("Stored browser image is not a PNG")
    }
    return image
  }

  private static func expect(_ condition: Bool, file: String = #fileID, line: Int = #line) throws {
    if !condition { throw BrowserError.script("Assertion failed at \(file):\(line)") }
  }
}
