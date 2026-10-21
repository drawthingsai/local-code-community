import Foundation
import ModelZoo
import ProjectHistoryManager
import RemoteAPI

struct ProjectRemoteConversation {
  var state: RemoteAgentState
  var forceCheckpoint: Bool

  static func load(
    history: [ProjectHistoryNode], model: String
  ) -> ProjectRemoteConversation {
    guard let lastAssistantIndex = history.lastIndex(where: { $0.role == .assistant }) else {
      return ProjectRemoteConversation(
        state: RemoteAgentState(), forceCheckpoint: false)
    }
    let history = Array(history[...lastAssistantIndex])
    let compactedIndex = history.lastIndex {
      $0.role == .assistant && $0.compacted
    }
    var transcript = [RemoteTranscriptEntry]()
    var forceCheckpoint = false
    var previousAssistantIndex = -1
    let parseLogTokens: (([Int32]) -> [AgentTranscriptEntry])?
    if let specification = LLMZoo.specificationForModel(model) {
      switch specification.version {
      case .qwen_3_5_4b, .qwen_3_5_9b, .qwen_3_5_27b:
        parseLogTokens = Qwen3_5CodeAgent.parse
      case .deepseek_4_flash:
        parseLogTokens = DeepSeek4CodeAgent<DeepSeek4TextGenerator>.parse
      case .deepseek_4_1_flash:
        parseLogTokens = DeepSeek4CodeAgent<DeepSeek4_1TextGenerator>.parse
      }
    } else {
      parseLogTokens = nil
    }
    if let compactedIndex {
      let node = history[compactedIndex]
      previousAssistantIndex = compactedIndex
      if let logPlaintext = node.logPlaintext, !logPlaintext.isEmpty,
        let checkpoint = try? RemoteTranscriptCodec.decode(logPlaintext)
      {
        transcript = checkpoint
      } else if !node.logTokens.isEmpty, let parseLogTokens {
        transcript = RemoteConversationCodec.remoteMessages(
          from: parseLogTokens(node.logTokens), model: model,
          idPrefix: "local-\(node.threadId)-\(node.datetime)")
        forceCheckpoint = true
      }
    }

    for assistantIndex in history.indices
    where assistantIndex > previousAssistantIndex && history[assistantIndex].role == .assistant {
      let node = history[assistantIndex]
      if let logPlaintext = node.logPlaintext, !logPlaintext.isEmpty {
        if let turn = try? RemoteTranscriptCodec.decode(logPlaintext) {
          transcript += turn
          previousAssistantIndex = assistantIndex
          continue
        }
        forceCheckpoint = true
      }
      let turnStart = previousAssistantIndex + 1
      let turnHistory = Array(history[turnStart...assistantIndex])
      if let parseLogTokens,
        let messages = try? RemoteConversationCodec.remoteMessages(
          from: turnHistory, model: model, parseLogTokens: parseLogTokens)
      {
        transcript += messages
      } else {
        let visibleMessages = turnHistory.compactMap { node -> RemoteTranscriptEntry? in
          guard let plaintext = node.plaintext?.trimmingCharacters(in: .whitespacesAndNewlines),
            !plaintext.isEmpty
          else { return nil }
          switch node.role {
          case .memory:
            return nil
          case .user:
            return .user(plaintext)
          case .assistant:
            return .assistant(plaintext)
          }
        }
        transcript += visibleMessages
      }
      forceCheckpoint = true
      previousAssistantIndex = assistantIndex
    }
    return ProjectRemoteConversation(
      state: RemoteAgentState(transcript: transcript), forceCheckpoint: forceCheckpoint)
  }
}
