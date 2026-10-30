import CryptoKit
import DeviceLink
import Foundation
import GRPC
import ModelZoo
import RemoteAPI
import os.lock

/// Whether a device stopped waiting for its step; set on the main queue, read on the generation
/// queue.
private final class StepCancellation: @unchecked Sendable {
  private var lock = os_unfair_lock()
  private var cancelled = false

  var isCancelled: Bool {
    os_unfair_lock_lock(&lock)
    defer { os_unfair_lock_unlock(&lock) }
    return cancelled
  }

  func cancel() {
    os_unfair_lock_lock(&lock)
    cancelled = true
    os_unfair_lock_unlock(&lock)
  }
}

/// The Mac's own models, one step at a time, for another device's threads (the Inference service;
/// see RemoteAccessServices.md). Steps run on the generation queue, between the Mac's own turns.
extension ChatWorkflow: InferenceBackend {
  /// The context another device's agent gets on one of the Mac's models; 0 for a model that can't
  /// run its steps.
  static func inferenceContextWindow(forModel file: String) -> Int {
    switch LLMZoo.specificationForModel(file)?.version {
    case .qwen_3_5_4b, .qwen_3_5_9b, .qwen_3_5_27b:
      return Qwen3_5CodeAgent.maximumContextLength
    case .deepseek_4_flash, .deepseek_4_1_flash, nil:
      return 0
    }
  }

  func step(
    _ request: StepRequest, from deviceID: String, event: @escaping (StepEvent) -> Void,
    finished: @escaping (GRPCStatus) -> Void
  ) -> () -> Void {
    dispatchPrecondition(condition: .onQueue(.main))
    let file = request.modelID
    guard let specification = LLMZoo.specificationForModel(file),
      LLMZoo.isModelDownloaded(specification)
    else {
      finished(GRPCStatus(code: .notFound, message: "That model isn't on this Mac."))
      return {}
    }
    guard Self.inferenceContextWindow(forModel: file) > 0 else {
      finished(
        GRPCStatus(
          code: .failedPrecondition, message: "That model can't run another device's threads."))
      return {}
    }
    guard
      let transcript = try? JSONDecoder().decode(
        [RemoteTranscriptEntry].self, from: request.transcriptJson)
    else {
      finished(GRPCStatus(code: .invalidArgument, message: "The Mac couldn't read the thread."))
      return {}
    }
    // The Mac runs one of its models at a time.
    guard !waitsForModel(file) else {
      finished(
        GRPCStatus(
          code: .unavailable, message: "This Mac is answering on another of its models."))
      return {}
    }
    agentSchedulerActivation(for: file)
    guard let textGenerator = textGenerator(for: file) as? Qwen3_5TextGenerator,
      let cachePath = Self.inferenceCachePath(for: deviceID)
    else {
      finished(GRPCStatus(code: .unavailable, message: "The Mac couldn't load its model."))
      return {}
    }
    let step = Qwen3_5Step(
      textGenerator: textGenerator, graph: graph, streamContext: streamContext,
      reasoningEffort: workspace.dictionary["reasoning_effort", ReasoningEffort.self] ?? .high,
      thinkingBudget: min(
        max(workspace.dictionary["thinking_budget", Int.self] ?? 65_536, 0), 128 * 1_024),
      deterministic: (workspace.dictionary["work_attitude", WorkAttitude.self] ?? .deterministic)
        == .deterministic,
      cachePath: cachePath)
    let maximumOutputTokens =
      request.maximumOutputTokens > 0 ? Int(request.maximumOutputTokens) : 32_768
    let cancellation = StepCancellation()
    self.queue.async {
      do {
        let completion = try step.run(
          transcript, maximumOutputTokens: maximumOutputTokens,
          isCancelled: { cancellation.isCancelled },
          reading: { finishedTokens, totalTokens in
            event(
              StepEvent.with {
                $0.reading = TokenProgress.with {
                  $0.finishedTokens = UInt32(clamping: finishedTokens)
                  $0.totalTokens = UInt32(clamping: totalTokens)
                }
              })
          },
          progress: { content in
            guard let data = try? JSONEncoder().encode(content) else { return }
            event(StepEvent.with { $0.progressJson = data })
          })
        let data = try JSONEncoder().encode(completion)
        event(StepEvent.with { $0.completionJson = data })
        finished(.ok)
      } catch Qwen3_5Step.Error.cancelled {
        finished(GRPCStatus(code: .cancelled, message: "The device stopped the step."))
      } catch {
        finished(GRPCStatus(code: .invalidArgument, message: "The Mac couldn't read the thread."))
      }
    }
    return { cancellation.cancel() }
  }

  /// A folder on the Mac for the device's context cache, named for the device without its ID.
  private static func inferenceCachePath(for deviceID: String) -> String? {
    let name = SHA256.hash(data: Data(deviceID.utf8)).prefix(8).map { String(format: "%02x", $0) }
      .joined()
    guard
      let cachesURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    else { return nil }
    let url = cachesURL.appendingPathComponent("RemoteAccessSessions", isDirectory: true)
      .appendingPathComponent(name, isDirectory: true)
    guard (try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true))
      != nil
    else { return nil }
    return url.path
  }
}
