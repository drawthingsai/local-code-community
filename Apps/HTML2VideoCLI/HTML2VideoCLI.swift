import ArgumentParser
import Foundation
import HTMLVideoExporter

public struct HTML2VideoCLI: ParsableCommand {
  public static let configuration = CommandConfiguration(
    commandName: "html2video", abstract: "Export a local HTML animation to MP4 or MOV.",
    discussion:
      "Accepts an HTML file or a project directory containing index.html. For HyperFrames projects, first save the preview server's /__hyperframes_composition.html as .hyperframes-export.htm beside index.html, then run html2video .hyperframes-export.htm --output out.mp4. Fetch a fresh compiled page after source edits; html2video does not compile HyperFrames source files. Dimensions and duration default to the page's data attributes or window.html2video contract. Existing output files are never overwritten. Runs without Chrome, FFmpeg, or Node addons.",
    version: "1.0.0"
  )

  @Argument(help: "Local HTML file or project directory.") var input = "."
  @Option(name: .shortAndLong, help: "Destination MP4 or MOV path.") var output: String
  @Option(help: "Output container: mp4 or mov; inferred from output extension.") var format: String?
  @Flag(help: "Preserve transparency in HEVC-with-alpha MOV output.") var alpha = false
  @Option(help: "Output width in pixels; even integer.") var width: Int?
  @Option(help: "Output height in pixels; even integer.") var height: Int?
  @Option(help: "Duration in seconds; rounded up to a whole output frame.") var duration: Double?
  @Option(help: "Frames per second, e.g. 30 or 30000/1001.") var fps = "30"
  @Option(help: "Maximum seconds without a completed frame or page load.") var timeout: Double = 60
  @Option(help: "JSON object overriding HyperFrames composition variables.") var variables: String?
  @Option(help: "JSON file overriding HyperFrames composition variables.") var variablesFile:
    String?
  @Flag(help: "Print a machine-readable result on stdout.") var json = false

  public init() {}

  public static func start(
    arguments: [String], resolvePath: (String) -> URL,
    cancellationRequested: @escaping () -> Bool = { false },
    write: @escaping (String, Bool) -> Void,
    completion: @escaping (Int32) -> Void
  ) {
    precondition(Thread.isMainThread)
    do {
      let command = try parse(arguments)
      guard command.variables == nil || command.variablesFile == nil else {
        throw ValidationError("Use either --variables or --variables-file.")
      }
      let data: Data?
      if let path = command.variablesFile {
        data = try Data(contentsOf: resolvePath(path))
      } else {
        data = command.variables.map { Data($0.utf8) }
      }
      var variables = [String: Any]()
      if let data {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
          throw ValidationError("Variables must be a JSON object.")
        }
        variables = object
      }
      let options = try HTMLVideoExportOptions(
        input: resolvePath(command.input), output: resolvePath(command.output),
        width: command.width, height: command.height, duration: command.duration,
        fps: command.fps, timeout: command.timeout, variables: variables,
        format: command.format, alpha: command.alpha)
      // Retain until its single completion, including cancellation and failure paths.
      var exporter: HTMLVideoExporter?
      exporter = HTMLVideoExporter(options: options, cancellationRequested: cancellationRequested) {
        frame, count in
        if frame == 1 || frame == count || frame % 30 == 0 {
          write("html2video: \(frame)/\(count) frames\n", true)
        }
      }
      exporter?.start { result in
        defer { exporter = nil }
        switch result {
        case .success(let result):
          if command.json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            do {
              write(String(decoding: try encoder.encode(result), as: UTF8.self) + "\n", false)
            } catch {
              write("html2video: \(error.localizedDescription)\n", true)
              completion(1)
              return
            }
          } else {
            write(
              "Wrote: \(result.output)\n\(result.width)×\(result.height), \(result.frames) frames, \(result.duration)s\n",
              false)
          }
          completion(0)
        case .failure(let error):
          write("html2video: \(error.localizedDescription)\n", true)
          if case HTMLVideoExportError.cancelled = error { completion(130) } else { completion(1) }
        }
      }
    } catch {
      let status = exitCode(for: error).rawValue
      write(fullMessage(for: error) + "\n", status != 0)
      completion(status)
    }
  }
}
