import DeviceLink
import Foundation
import RemoteAPI

/// Turns an agent's progress into a turn's events: reading and compacting with their counts, the
/// current step's reasoning and answer as they stream, tool calls as they start and finish, and
/// the speeds, everything a device needs to show the turn as the Mac shows its own.
final class TurnReporter: @unchecked Sendable {
  /// Streamed text and counts go at most this often; tool calls go at once.
  private static let streamInterval: TimeInterval = 0.1

  private let projectPath: String
  private let workspacePath: String
  private let toolCallStart: String
  private let toolCallEnd: String
  private let emit: (TurnEvent.OneOf_Event) -> Void
  private let finished: (TurnEvent.OneOf_Event) -> Void
  private var sentText = ""
  private var sentThinking = ""
  private var lastStreamed = Date.distantPast
  private var finishedTools = 0
  private var startedTools = Set<Int>()
  private var startedCloudTools = Set<String>()
  private var finishedCloudTools = Set<String>()

  /// `emit` is called on the scheduler's queue, `finished` on the main queue.
  init(
    projectPath: String, workspacePath: String, toolCallStart: String, toolCallEnd: String,
    emit: @escaping (TurnEvent.OneOf_Event) -> Void,
    finished: @escaping (TurnEvent.OneOf_Event) -> Void
  ) {
    self.projectPath = projectPath
    self.workspacePath = workspacePath
    self.toolCallStart = toolCallStart
    self.toolCallEnd = toolCallEnd
    self.emit = emit
    self.finished = finished
  }

  /// On the scheduler's queue, one call at a time.
  func report(_ progress: CodeAgentProgress, statistics: CodeAgentStatistics) {
    switch progress {
    case .prefill(_, let finished, let total):
      guard isStreamDue() else { return }
      emit(.reading(Self.tokenProgress(finished, total)))
    case .compact(_, let finished, let total):
      guard isStreamDue() else { return }
      emit(.compacting(Self.tokenProgress(finished, total)))
    case .generate(let result), .toolsWait(let result):
      reportTools(result)
      let output = ToolCallParser.removeToolCalls(
        result.output, toolCallStart: toolCallStart, toolCallEnd: toolCallEnd
      ).trimmingCharacters(in: .whitespacesAndNewlines)
      let tokens = result.thinkTokens.count + result.outputTokens.count
      if output.isEmpty {
        let think = result.think.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !think.isEmpty, think != sentThinking, isStreamDue() else { return }
        emit(.thinking(Self.update(from: sentThinking, to: think, tokens: tokens)))
        sentThinking = think
      } else {
        guard output != sentText, isStreamDue() else { return }
        emit(.answer(Self.update(from: sentText, to: output, tokens: tokens)))
        sentText = output
      }
      emit(
        .metrics(
          Metrics.with {
            $0.prefillTokensPerSecond = statistics.prefillTokensPerSecond
            $0.generatedTokensPerSecond = statistics.tokenGeneratedPerSecond
            $0.contextUsedTokens = UInt32(clamping: statistics.contextUsedTokens)
            $0.contextWindowTokens = UInt32(clamping: statistics.contextWindowTokens)
          }))
    }
  }

  /// A cloud model's progress, on the main queue: its tools as they start and finish, then the
  /// current request's reasoning until its answer begins, then the answer.
  func report(_ progress: RemoteAgentProgress) {
    for tool in progress.tools {
      if tool.isCompleted {
        guard finishedCloudTools.insert(tool.id).inserted else { continue }
        emit(
          .toolFinished(
            ToolFinished.with {
              $0.callID = tool.id
              $0.subtitle = tool.subtitle
            }))
      } else if startedCloudTools.insert(tool.id).inserted {
        emit(
          .toolStarted(
            ToolStarted.with {
              $0.callID = tool.id
              $0.subtitle = tool.subtitle
            }))
      }
    }
    let text = progress.text.trimmingCharacters(in: .whitespacesAndNewlines)
    // Counted as the Mac counts a cloud model's output.
    let tokens = (progress.thinking + progress.text).utf8.count
    if text.isEmpty {
      let thinking = progress.thinking.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !thinking.isEmpty, thinking != sentThinking, isStreamDue() else { return }
      emit(.thinking(Self.update(from: sentThinking, to: thinking, tokens: tokens)))
      sentThinking = thinking
    } else {
      guard text != sentText, isStreamDue() else { return }
      emit(.answer(Self.update(from: sentText, to: text, tokens: tokens)))
      sentText = text
    }
    if let outputTokensPerSecond = progress.metrics.observedOutputTokensPerSecond {
      emit(.metrics(Metrics.with { $0.generatedTokensPerSecond = Float(outputTokensPerSecond) }))
    }
  }

  /// A cloud model's turn ended, once its answer is saved; on the main queue.
  func finish(
    result: Result<RemoteAgentCompletion, RemoteChatError>, wasCancelled: Bool,
    messageDatetime: Int64
  ) {
    switch result {
    case .success:
      finish(wasCancelled ? .stopped : .completed, messageDatetime: messageDatetime)
    case .failure(let error):
      finish(
        wasCancelled ? .stopped : .failed, messageDatetime: messageDatetime,
        error: wasCancelled ? "" : error.localizedDescription)
    }
  }

  /// On the main queue, once the turn's completion has saved what it will.
  func finish(_ outcome: TurnFinished.Outcome, messageDatetime: Int64 = 0, error: String = "") {
    finished(
      .finished(
        TurnFinished.with {
          $0.outcome = outcome
          $0.messageDatetimeMs = messageDatetime
          $0.errorMessage = error
        }))
  }

  /// Calls that finished since the last report, then the ones that started.
  private func reportTools(_ result: CodeAgentResult) {
    for (index, toolCall) in result.toolCallHistory.enumerated().dropFirst(finishedTools) {
      emit(
        .toolFinished(
          ToolFinished.with {
            $0.callID = "\(index)"
            $0.subtitle = subtitle(toolCall, tense: .past)
          }))
    }
    finishedTools = result.toolCallHistory.count
    for (offset, toolCall) in result.toolCalls.enumerated()
    where !startedTools.contains(finishedTools + offset) {
      startedTools.insert(finishedTools + offset)
      emit(
        .toolStarted(
          ToolStarted.with {
            $0.callID = "\(finishedTools + offset)"
            $0.subtitle = subtitle(toolCall, tense: .now)
          }))
    }
  }

  private func isStreamDue() -> Bool {
    let now = Date()
    guard now.timeIntervalSince(lastStreamed) >= Self.streamInterval else { return false }
    lastStreamed = now
    return true
  }

  private static func tokenProgress(_ finished: Int, _ total: Int) -> TokenProgress {
    TokenProgress.with {
      $0.finishedTokens = UInt32(clamping: finished)
      $0.totalTokens = UInt32(clamping: total)
    }
  }

  /// The text after what was sent, or all of it, replacing, when it doesn't continue what was
  /// sent: a new step's reasoning, or an answer a tool call was taken out of.
  private static func update(from sent: String, to text: String, tokens: Int) -> TextUpdate {
    let extends = text.hasPrefix(sent)
    return TextUpdate.with {
      $0.text = extends ? String(text.dropFirst(sent.count)) : text
      $0.replaces = !extends
      $0.tokens = UInt32(clamping: tokens)
    }
  }

  private func subtitle(_ toolCall: ToolCall, tense: ToolSubtitleMoment) -> String {
    ToolsRegistry.parse(toolCall.request, projectPath: projectPath, workspacePath: workspacePath)?
      .subtitle(for: tense) ?? toolCall.request.function
  }
}
