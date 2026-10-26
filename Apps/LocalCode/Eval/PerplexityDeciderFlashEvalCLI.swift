import ArgumentParser
import Foundation
import LLM

private enum PerplexityDeciderFlashEvalError: LocalizedError {
  case missingFile(String)
  case unsortedRequests(String)

  var errorDescription: String? {
    switch self {
    case .missingFile(let path):
      return "File does not exist: \(path)"
    case .unsortedRequests(let id):
      return "The lines of \(id) are not consecutive."
    }
  }
}

/// One tokenized sequence from `clef_monitoringbench_eval.py requests`, with its questions in marker order.
private struct PerplexityDeciderFlashRequest: Decodable {
  struct Question: Decodable {
    var key: String
    var type: String
    var options: [String]
  }
  var id: String
  var tokens: [Int32]
  var markers: [Int]
  var questions: [Question]
}

/// Answers MonitoringBench reviews with SwiftLLM's pplx-decider-flash and writes predictions in the format of
/// `clef_monitoringbench_eval.py run`, for its `score`.
@main
private struct PerplexityDeciderFlashEvalCLI: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "PerplexityDeciderFlashEvalCLI",
    abstract: "Run pplx-decider-flash on tokenized MonitoringBench requests.")

  @Option(help: "pplx-decider-flash checkpoint from PerplexityDeciderFlashConverter.")
  var model: String

  @Option(help: "Tokenized requests from clef_monitoringbench_eval.py requests.")
  var requests: String

  @Option(help: "Predictions JSONL. Appends, and skips ids already in it.")
  var out: String

  @Option(help: "Stop after this many items; 0 runs them all.")
  var limit = 0

  mutating func run() throws {
    let modelPath = (model as NSString).expandingTildeInPath
    let requestsPath = (requests as NSString).expandingTildeInPath
    let outPath = (out as NSString).expandingTildeInPath
    for path in [modelPath, requestsPath] where !FileManager.default.fileExists(atPath: path) {
      throw PerplexityDeciderFlashEvalError.missingFile(path)
    }
    var done = Set<String>()
    if FileManager.default.fileExists(atPath: outPath) {
      for line in try String(contentsOfFile: outPath, encoding: .utf8).split(separator: "\n") {
        if let prediction = try JSONSerialization.jsonObject(with: Data(line.utf8))
          as? [String: Any], let id = prediction["id"] as? String
        {
          done.insert(id)
        }
      }
    } else {
      FileManager.default.createFile(atPath: outPath, contents: nil)
    }
    // An item's sequences are consecutive lines, so group them in order.
    var items = [(id: String, sequences: [PerplexityDeciderFlashRequest])]()
    var seen = Set<String>()
    for line in try String(contentsOfFile: requestsPath, encoding: .utf8).split(separator: "\n") {
      let request = try JSONDecoder().decode(
        PerplexityDeciderFlashRequest.self, from: Data(line.utf8))
      if items.last?.id == request.id {
        items[items.count - 1].sequences.append(request)
      } else {
        guard seen.insert(request.id).inserted else {
          throw PerplexityDeciderFlashEvalError.unsortedRequests(request.id)
        }
        items.append((request.id, [request]))
      }
    }
    var pending = items.filter { !done.contains($0.id) }
    if limit > 0 {
      pending = Array(pending.prefix(limit))
    }
    print("\(done.count) done, \(pending.count) pending")
    guard !pending.isEmpty else { return }

    let decision = PerplexityDeciderFlashDecision<Float16>(filePath: modelPath)
    let output = try FileHandle(forWritingTo: URL(fileURLWithPath: outPath))
    defer { try? output.close() }
    try output.seekToEnd()
    let started = Date.timeIntervalSinceReferenceDate
    for (index, item) in pending.enumerated() {
      let itemStarted = Date.timeIntervalSinceReferenceDate
      var prediction: [String: Any] = ["id": item.id]
      var tokenCount = 0
      for sequence in item.sequences {
        let logits = try decision.logits(tokenIds: sequence.tokens, markers: sequence.markers)
        tokenCount += sequence.tokens.count
        for (question, questionLogits) in zip(sequence.questions, logits) {
          let probabilities = PerplexityDeciderFlashDecision<Float16>.probabilities(
            logits: questionLogits, count: question.options.count)
          var answer = [String: Double]()
          for (option, probability) in zip(question.options, probabilities) {
            answer[option] = probability
          }
          if question.type == "noul" {
            // Options are false, true. `score` ranks by this margin, as for the Python model.
            answer["margin"] = Double(questionLogits[1] - questionLogits[0])
          }
          prediction[question.key] = answer
        }
      }
      prediction["tokens"] = tokenCount
      prediction["seconds"] =
        ((Date.timeIntervalSinceReferenceDate - itemStarted) * 1000).rounded() / 1000
      try output.write(contentsOf: try JSONSerialization.data(withJSONObject: prediction))
      try output.write(contentsOf: Data("\n".utf8))
      if (index + 1) % 100 == 0 || index + 1 == pending.count {
        let minutes = (Date.timeIntervalSinceReferenceDate - started) / 60
        print("\(index + 1)/\(pending.count) items, \(String(format: "%.1f", minutes)) min")
      }
    }
  }
}
