import AVFoundation
import Darwin
import Foundation
import HTMLVideoExporter
import NodeMobile
import QuartzCore

#if canImport(UIKit)
  import UIKit
#else
  import AppKit
#endif

public enum HyperFramesCLI {
  public static let version = "0.8.78"
  private static var sessions = [UInt64: HyperFramesSession]()
  public static func start(
    arguments: [String], directory: URL, resources: URL? = nil,
    errorDescriptor: Int32 = STDERR_FILENO, cancellationRequested: @escaping () -> Bool = { false },
    write: @escaping (String, Bool) -> Void, completion: @escaping (Int32) -> Void
  ) {
    dispatchPrecondition(condition: .onQueue(.main))
    if arguments == ["--version"] {
      write(version + "\n", false)
      completion(0)
      return
    }
    guard let resources = resources ?? resourcesURL() else {
      write("hyperframes: Missing bundled runtime.\n", true)
      completion(1)
      return
    }
    let identifier = UInt64.random(in: (1 << 63)...UInt64.max)
    let session = HyperFramesSession(
      identifier: identifier, directory: directory, resources: resources,
      errorDescriptor: errorDescriptor, cancellationRequested: cancellationRequested, write: write
    ) { status in
      sessions.removeValue(forKey: identifier)
      completion(status)
    }
    sessions[identifier] = session
    session.start(arguments: arguments)
  }

  public static func resourcesURL() -> URL? {
    let relativePath = "Apps/HyperFramesCLI/Resources/HyperFrames"
    var candidates = [Bundle.main.resourceURL?.appendingPathComponent("HyperFrames")]
    if let workspace = ProcessInfo.processInfo.environment["BUILD_WORKSPACE_DIRECTORY"] {
      candidates.append(URL(fileURLWithPath: workspace).appendingPathComponent(relativePath))
    }
    if let runfiles = ProcessInfo.processInfo.environment["TEST_SRCDIR"] {
      let workspace = ProcessInfo.processInfo.environment["TEST_WORKSPACE"] ?? "__main__"
      candidates.append(
        URL(fileURLWithPath: runfiles).appendingPathComponent(workspace).appendingPathComponent(
          relativePath))
    }
    var ancestor = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
      .deletingLastPathComponent()
    while ancestor.path != "/" {
      candidates.append(ancestor.appendingPathComponent(relativePath))
      ancestor.deleteLastPathComponent()
    }
    candidates.append(
      URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(
        relativePath))
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    candidates.append(
      executable.appendingPathExtension("runfiles").appendingPathComponent(
        "__main__/" + relativePath))
    return candidates.compactMap { $0 }.first {
      FileManager.default.fileExists(atPath: $0.appendingPathComponent("worker.cjs").path)
    }
  }
}

private final class HyperFramesSession {
  private let identifier: UInt64
  private let directory: URL
  private let resources: URL
  private let errorDescriptor: Int32
  private let cancellationRequested: () -> Bool
  private let write: (String, Bool) -> Void
  private let completion: (Int32) -> Void
  private let input = Pipe()
  private let output = Pipe()
  private let inspector = HTMLCompositionInspector()
  private var timer: Timer?
  private var deadline: CFTimeInterval = .infinity
  private var finished = false
  private var cancelled = false
  private var workerReturned = false
  private var readerEnded = false
  private var workerStatus: Int32?
  private let replyQueue = DispatchQueue(label: "hyperframes.rpc")
  private var server: HyperFramesServer?

  init(
    identifier: UInt64, directory: URL, resources: URL, errorDescriptor: Int32,
    cancellationRequested: @escaping () -> Bool, write: @escaping (String, Bool) -> Void,
    completion: @escaping (Int32) -> Void
  ) {
    self.identifier = identifier
    self.directory = directory
    self.resources = resources
    self.errorDescriptor = errorDescriptor
    self.cancellationRequested = cancellationRequested
    self.write = write
    self.completion = completion
  }

  func start(arguments: [String]) {
    guard node_mobile_prepare_command(identifier) == 0 else {
      finish(1)
      return
    }
    let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
      guard let self, !self.finished else { return }
      if !self.cancelled && (self.cancellationRequested() || CACurrentMediaTime() >= self.deadline)
      {
        self.cancelled = true
        self.inspector.close()
        self.server?.stop()
        try? self.input.fileHandleForWriting.close()
        if self.workerReturned {
          self.finish(130)
        } else {
          _ = node_mobile_cancel_command(self.identifier)
        }
      }
    }
    self.timer = timer
    RunLoop.main.add(timer, forMode: .common)
    // This is the command boundary: Node owns a blocking environment and WebKit owns
    // the main queue. Pipes carry private RPC messages, never a network endpoint.
    DispatchQueue.global(qos: .userInitiated).async {
      var bytes = Data()
      while true {
        let data = self.output.fileHandleForReading.availableData
        if data.isEmpty { break }
        bytes.append(data)
        while let end = bytes.firstIndex(of: 10) {
          let line = bytes.prefix(upTo: end)
          bytes.removeSubrange(...end)
          do {
            guard let message = try JSONSerialization.jsonObject(with: line) as? [String: Any]
            else { continue }
            DispatchQueue.main.async { self.receive(message) }
          } catch {
            DispatchQueue.main.async {
              self.write("hyperframes: Invalid worker response: \(error)\n", true)
            }
          }
        }
      }
      DispatchQueue.main.async {
        self.readerEnded = true
        self.workerFinished()
      }
    }
    DispatchQueue.global(qos: .userInitiated).async {
      let args = (["node", self.resources.appendingPathComponent("worker.cjs").path] + arguments)
        .map { (value: String) in strdup(value)! }
      let env = [
        "HYPERFRAMES_RESOURCES=\(self.resources.path)", "HOME=\(NSHomeDirectory())",
        "TMPDIR=\(NSTemporaryDirectory())", "NO_COLOR=1",
      ].map { (value: String) in strdup(value)! }
      let cwd = strdup(self.directory.path)!
      defer {
        args.forEach { free($0) }
        env.forEach { free($0) }
        free(cwd)
      }
      var argv = args.map { Optional($0) } + [nil]
      var environment = env.map { Optional(UnsafePointer($0)) } + [nil]
      let status = environment.withUnsafeMutableBufferPointer { environment in
        var options = node_mobile_command_options(
          command_identifier: self.identifier,
          working_directory: UnsafePointer(cwd), preload_path: nil,
          environment: UnsafePointer(environment.baseAddress!),
          stdin_fd: self.input.fileHandleForReading.fileDescriptor,
          stdout_fd: self.output.fileHandleForWriting.fileDescriptor,
          stderr_fd: self.errorDescriptor)
        return node_mobile_run_command(Int32(args.count), &argv, &options)
      }
      var wasCancelled: Int32 = 0
      _ = node_mobile_finish_command(self.identifier, &wasCancelled)
      try? self.output.fileHandleForWriting.close()
      DispatchQueue.main.async {
        self.workerReturned = true
        self.workerStatus = wasCancelled != 0 || self.cancelled ? 130 : status
        self.workerFinished()
      }
    }
  }

  private func receive(_ message: [String: Any]) {
    guard !finished else { return }
    if message["event"] as? String == "done" {
      try? input.fileHandleForWriting.close()
      return
    }
    if let text = message["text"] as? String, message["event"] as? String == "output" {
      write(text, false)
      return
    }
    guard let id = message["id"] as? Int, let method = message["method"] as? String else { return }
    deadline = CACurrentMediaTime() + max(30, (message["timeout"] as? Double ?? 30) + 5)
    let reply: (Result<Any, Error>) -> Void = { result in
      guard !self.finished else { return }
      self.deadline = .infinity
      var response: [String: Any] = ["id": id]
      switch result {
      case .success(let value): response["result"] = value
      case .failure(let error): response["error"] = error.localizedDescription
      }
      do {
        var data = try JSONSerialization.data(
          withJSONObject: response, options: [.fragmentsAllowed])
        data.append(10)
        // Large screenshots must not block the WebKit queue while Node drains its pipe.
        self.replyQueue.async { try? self.input.fileHandleForWriting.write(contentsOf: data) }
      } catch { self.write("hyperframes: \(error)\n", true) }
    }
    switch method {
    case "load":
      guard let path = message["directory"] as? String, let html = message["html"] as? String else {
        reply(.failure(CommandError.invalid("Invalid page request")))
        return
      }
      inspector.load(
        directory: URL(fileURLWithPath: path), html: html,
        timeout: message["timeout"] as? Double ?? 30, completion: reply)
    case "evaluate":
      inspector.evaluate(
        message["source"] as? String ?? "", arguments: ["args": message["args"] ?? []],
        completion: reply)
    case "seek": inspector.seek(message["time"] as? Double ?? 0, completion: reply)
    case "runtimeFindings":
      inspector.evaluate("return window.__hyperframesNativeFindings;", completion: reply)
    case "snapshot":
      inspector.snapshot(
        zoom: message["zoom"] as? String, scale: message["scale"] as? Double ?? 1, completion: reply
      )
    case "contactSheet":
      do {
        reply(
          .success(
            try HTMLCompositionInspector.contactSheet(
              images: message["images"] as? [String] ?? [],
              times: message["times"] as? [Double] ?? [])))
      } catch { reply(.failure(error)) }
    case "probe":
      guard let path = message["path"] as? String, !path.contains("://") else {
        reply(.failure(CommandError.invalid("Media probes require a local file")))
        return
      }
      let asset = AVURLAsset(url: URL(fileURLWithPath: path))
      asset.loadValuesAsynchronously(forKeys: ["duration", "tracks"]) {
        let duration = CMTimeGetSeconds(asset.duration)
        let track = asset.tracks(withMediaType: .video).first
        var codec = ""
        if let description = track?.formatDescriptions.first {
          let value = CMFormatDescriptionGetMediaSubType(description as! CMFormatDescription)
          codec =
            value == kCMVideoCodecType_HEVC
            ? "hevc" : value == kCMVideoCodecType_H264 ? "h264" : String(value)
        }
        DispatchQueue.main.async {
          guard duration.isFinite, duration > 0 else {
            reply(.failure(CommandError.invalid("Cannot probe media: \(path)")))
            return
          }
          reply(.success(["duration": duration, "codec": codec]))
        }
      }
    case "serve":
      do {
        guard let path = message["directory"] as? String else {
          throw CommandError.invalid("Invalid server request")
        }
        let server = try HyperFramesServer(
          directory: URL(fileURLWithPath: path), resources: resources,
          port: UInt16(message["port"] as? Int ?? 0))
        self.server = server
        server.compile = { [weak self] entry, complete in
          guard let self else {
            complete(.failure(CommandError.invalid("Preview stopped")))
            return
          }
          var html = ""
          HyperFramesCLI.start(
            arguments: ["__compile", path, "--entry", entry]
              + (entry == "index.html"
                ? [message["present"] as? Bool == true ? "--presentation" : "--preview-page"] : []),
            directory: self.directory, resources: self.resources,
            errorDescriptor: self.errorDescriptor, cancellationRequested: { self.cancelled },
            write: { text, isError in if isError { self.write(text, true) } else { html += text } },
            completion: { status in
              if status == 0 {
                complete(.success(html))
              } else {
                complete(.failure(CommandError.invalid("Cannot compile " + entry)))
              }
            })
        }
        server.start { result in
          if message["open"] as? Bool == true, case .success(let value) = result,
            let url = URL(string: value)
          {
            #if canImport(UIKit)
              UIApplication.shared.open(url)
            #else
              NSWorkspace.shared.open(url)
            #endif
          }
          reply(result.map { ["url": $0] })
        }
      } catch { reply(.failure(error)) }
    default: reply(.failure(CommandError.invalid("Unknown native operation: \(method)")))
    }
  }

  private func workerFinished() {
    guard readerEnded, let status = workerStatus else { return }
    if status != 0 || server == nil { finish(status) }
  }

  private func finish(_ status: Int32) {
    guard !finished else { return }
    finished = true
    timer?.invalidate()
    timer = nil
    inspector.close()
    server?.stop()
    server = nil
    try? input.fileHandleForWriting.close()
    completion(status)
  }
}

enum CommandError: LocalizedError {
  case invalid(String)
  var errorDescription: String? {
    switch self {
    case .invalid(let message): return message
    }
  }
}
