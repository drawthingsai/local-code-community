import DataModels
import Foundation
import LLM
import ModelZoo
import ProjectHistoryManager
import RemoteAPI
import Tokenizer

extension ChatWorkflow {
  /// Moves a thread to a local model, converting its history for the model, and returns whether
  /// the thread is on it. Its next turn's context then comes from the converted history.
  func moveThread(
    _ threadId: Int64, toLocalModel file: String, in projectHistoryManager: ProjectHistoryManager
  ) -> Bool {
    guard let thread = projectHistoryManager.thread(id: threadId) else { return false }
    guard thread.model != file else { return true }
    let history = projectHistoryManager.history(threadId: threadId)
    guard
      let convertedHistory = convertedHistoryForLocalModel(
        history, sourceModel: thread.model ?? file, targetModel: file)
    else { return false }
    let historyIsUnchanged = convertedHistory.elementsEqual(
      history,
      by: { lhs, rhs in
        lhs.threadId == rhs.threadId && lhs.datetime == rhs.datetime
          && lhs.logTokens == rhs.logTokens && lhs.embedSpans == rhs.embedSpans
          && lhs.tokens == rhs.tokens
          && lhs.plaintext == rhs.plaintext && lhs.logPlaintext == rhs.logPlaintext
      })
    return historyIsUnchanged
      ? projectHistoryManager.updateThreadModel(id: threadId, model: file)
      : projectHistoryManager.rewriteHistory(
        threadId: threadId, nodes: convertedHistory, model: file)
  }

  /// Moves a thread to a cloud model (`remoteThreadModelIdentifier`), and returns whether the
  /// thread is on it. Its history becomes plain text, which cloud models read.
  func moveThread(
    _ threadId: Int64, toRemoteModel threadModel: String,
    in projectHistoryManager: ProjectHistoryManager
  ) -> Bool {
    guard let thread = projectHistoryManager.thread(id: threadId) else { return false }
    guard thread.model != threadModel else { return true }
    guard let sourceModel = thread.model ?? selectedLLM else { return false }
    // Only local models store tokens; any other thread (a remote provider's, including one this
    // build no longer knows) already keeps plain text and only needs its model updated.
    guard parseRemoteThreadModelIdentifier(sourceModel) == nil,
      LLMZoo.specificationForModel(sourceModel) != nil
    else { return projectHistoryManager.updateThreadModel(id: threadId, model: threadModel) }
    guard
      let convertedHistory = convertedHistoryForRemoteModel(
        projectHistoryManager.history(threadId: threadId), sourceModel: sourceModel)
    else { return false }
    return projectHistoryManager.rewriteHistory(
      threadId: threadId, nodes: convertedHistory, model: threadModel)
  }

  func convertedHistoryForLocalModel(
    _ history: [ProjectHistoryNode], sourceModel: String, targetModel: String
  ) -> [ProjectHistoryNode]? {
    guard let targetVersion = LLMZoo.specificationForModel(targetModel)?.version else {
      return nil
    }
    let targetSafeTokenizer: TiktokenTokenizer
    switch targetVersion {
    case .qwen_3_5_4b, .qwen_3_5_9b, .qwen_3_5_27b:
      targetSafeTokenizer = Qwen3_5TextGenerator.safeTokenizer
    case .deepseek_4_flash:
      targetSafeTokenizer = DeepSeek4TextGenerator.safeTokenizer
    case .deepseek_4_1_flash:
      targetSafeTokenizer = DeepSeek4_1TextGenerator.safeTokenizer
    }
    if parseRemoteThreadModelIdentifier(sourceModel) != nil {
      do {
        return try history.map { node in
          let plaintext = node.plaintext ?? ""
          switch node.role {
          case .memory:
            return node
          case .user:
            return ProjectHistoryNode(
              threadId: node.threadId, datetime: node.datetime, role: node.role,
              logTokens: [],
              tokens: targetSafeTokenizer.tokenize(
                text: plaintext, truncation: false, maxLength: 0, paddingToken: nil,
                addSpecialTokens: false
              ).1,
              toolCalls: node.toolCalls, textEdits: node.textEdits,
              textLineage: node.textLineage, plaintext: nil, logPlaintext: nil,
              compacted: node.compacted, duration: node.duration,
              memoryContext: node.memoryContext,
              systemSeenMemoryContext: node.systemSeenMemoryContext, imagePaths: node.imagePaths)
          case .assistant:
            let logTokens: [Int32]
            if let logPlaintext = node.logPlaintext, !logPlaintext.isEmpty {
              let entries = try RemoteTranscriptCodec.decode(logPlaintext)
              let transcript = try RemoteAgentTranscriptAdapter.parse(entries)
              logTokens = localTokens(for: transcript, version: targetVersion)
            } else {
              logTokens = []
            }
            return ProjectHistoryNode(
              threadId: node.threadId, datetime: node.datetime, role: node.role,
              logTokens: logTokens,
              tokens: targetSafeTokenizer.tokenize(
                text: plaintext, truncation: false, maxLength: 0, paddingToken: nil,
                addSpecialTokens: false
              ).1,
              toolCalls: node.toolCalls, textEdits: node.textEdits,
              textLineage: node.textLineage, plaintext: nil, logPlaintext: nil,
              compacted: node.compacted, duration: node.duration,
              memoryContext: node.memoryContext,
              systemSeenMemoryContext: node.systemSeenMemoryContext, imagePaths: node.imagePaths)
          }
        }
      } catch {
        return nil
      }
    }

    guard let sourceVersion = LLMZoo.specificationForModel(sourceModel)?.version else {
      return nil
    }
    switch sourceVersion {
    case .qwen_3_5_4b, .qwen_3_5_9b, .qwen_3_5_27b:
      switch targetVersion {
      case .qwen_3_5_4b, .qwen_3_5_9b, .qwen_3_5_27b:
        return history
      case .deepseek_4_flash, .deepseek_4_1_flash:
        break
      }
    case .deepseek_4_flash, .deepseek_4_1_flash:
      switch targetVersion {
      case .qwen_3_5_4b, .qwen_3_5_9b, .qwen_3_5_27b:
        break
      case .deepseek_4_flash, .deepseek_4_1_flash:
        return history
      }
    }
    let sourceSafeTokenizer: TiktokenTokenizer
    switch sourceVersion {
    case .qwen_3_5_4b, .qwen_3_5_9b, .qwen_3_5_27b:
      sourceSafeTokenizer = Qwen3_5TextGenerator.safeTokenizer
    case .deepseek_4_flash:
      sourceSafeTokenizer = DeepSeek4TextGenerator.safeTokenizer
    case .deepseek_4_1_flash:
      sourceSafeTokenizer = DeepSeek4_1TextGenerator.safeTokenizer
    }

    return history.map { node in
      guard node.role != .memory else { return node }
      let visibleText =
        node.plaintext
        ?? sourceSafeTokenizer.decode(node.tokens)
      let logTokens: [Int32]
      if node.role == .assistant, !node.logTokens.isEmpty {
        let transcript = agentTranscript(from: node.logTokens, version: sourceVersion)
        logTokens = localTokens(for: transcript, version: targetVersion)
      } else {
        logTokens = []
      }
      return ProjectHistoryNode(
        threadId: node.threadId, datetime: node.datetime, role: node.role,
        logTokens: logTokens,
        tokens: targetSafeTokenizer.tokenize(
          text: visibleText, truncation: false, maxLength: 0, paddingToken: nil,
          addSpecialTokens: false
        ).1,
        toolCalls: node.toolCalls, textEdits: node.textEdits,
        textLineage: node.textLineage, plaintext: nil, logPlaintext: nil,
        compacted: node.compacted, duration: node.duration,
        memoryContext: node.memoryContext, systemSeenMemoryContext: node.systemSeenMemoryContext,
        imagePaths: node.imagePaths)
    }
  }

  func convertedHistoryForRemoteModel(
    _ history: [ProjectHistoryNode], sourceModel: String
  ) -> [ProjectHistoryNode]? {
    guard let sourceVersion = LLMZoo.specificationForModel(sourceModel)?.version else {
      return nil
    }
    let sourceSafeTokenizer: TiktokenTokenizer
    switch sourceVersion {
    case .qwen_3_5_4b, .qwen_3_5_9b, .qwen_3_5_27b:
      sourceSafeTokenizer = Qwen3_5TextGenerator.safeTokenizer
    case .deepseek_4_flash:
      sourceSafeTokenizer = DeepSeek4TextGenerator.safeTokenizer
    case .deepseek_4_1_flash:
      sourceSafeTokenizer = DeepSeek4_1TextGenerator.safeTokenizer
    }
    do {
      return try history.map { node in
        let plaintext: String
        if let nodePlaintext = node.plaintext {
          plaintext = nodePlaintext
        } else {
          switch node.role {
          case .memory:
            return node
          case .user:
            plaintext = sourceSafeTokenizer.decode(node.tokens)
          case .assistant:
            let text: String
            switch sourceVersion {
            case .qwen_3_5_4b, .qwen_3_5_9b, .qwen_3_5_27b:
              text = sourceSafeTokenizer.decode(
                node.tokens, specialTokens: Qwen3_5ToolCallParser.toolCallSpecialTokens)
            case .deepseek_4_flash, .deepseek_4_1_flash:
              text = sourceSafeTokenizer.decode(
                node.tokens, specialTokens: DeepSeek4ToolCallParser.toolCallSpecialTokens)
            }
            plaintext = text.trimmingCharacters(in: .whitespacesAndNewlines)
          }
        }
        let logPlaintext: String?
        if node.role == .assistant, !node.logTokens.isEmpty {
          let transcript = agentTranscript(from: node.logTokens, version: sourceVersion)
          let entries = RemoteConversationCodec.remoteMessages(
            from: transcript, model: sourceModel,
            idPrefix: "local-\(node.threadId)-\(node.datetime)")
          logPlaintext = try RemoteTranscriptCodec.encode(entries)
        } else {
          logPlaintext = nil
        }
        return ProjectHistoryNode(
          threadId: node.threadId, datetime: node.datetime, role: node.role,
          logTokens: [], tokens: [], toolCalls: node.toolCalls, textEdits: node.textEdits,
          textLineage: node.textLineage, plaintext: plaintext,
          logPlaintext: logPlaintext, compacted: node.compacted, duration: node.duration,
          memoryContext: node.memoryContext, systemSeenMemoryContext: node.systemSeenMemoryContext,
          imagePaths: node.imagePaths)
      }
    } catch {
      return nil
    }
  }

  /// - Parameter project: A project other than the open one, such as one whose thread another
  ///   device works in, with its context and skills.
  func codeAgentWrapper(
    model: String, prefixTokens: [Int32], prefixEmbedSpans: [EmbedSpan],
    history: [ProjectHistoryNode], fromSuspension: Bool,
    project: (url: URL, context: ProjectContext, skillCatalog: SkillCatalog)? = nil
  ) -> CodeAgentWrapper? {
    guard let textGenerator = textGenerator(for: model) else { return nil }
    let codeAgent: any CodeAgent
    let projectURL = project?.url ?? self.projectURL
    let projectContext = project?.context ?? self.projectContext
    let skillCatalog = project?.skillCatalog ?? self.skillCatalog
    let memoryContext =
      (workspace.dictionary["is_memory_enabled", Bool.self] ?? true)
      ? MemoryContext.load(projectPath: projectURL?.path) : .empty
    // Keep the memory the thread's system prompt / reminder was built with, so its prefix and
    // context cache stay valid, unless memory now holds something the conversation has not seen.
    let savedMemory = ProjectHistoryManager.memoryContext(history: history)
    // An unfinished turn resumes its original prompt; any new snapshot is in its suspension.
    let systemSeenMemoryContext: MemoryContext
    let shouldInjectSystemSeenMemoryContext: Bool
    if fromSuspension || savedMemory.memoryContext == memoryContext,
      let savedContext = savedMemory.systemSeenMemoryContext
    {
      systemSeenMemoryContext = savedContext
      shouldInjectSystemSeenMemoryContext = false
    } else {
      systemSeenMemoryContext = memoryContext
      shouldInjectSystemSeenMemoryContext = true
    }
    let reasoningEffort = workspace.dictionary["reasoning_effort", ReasoningEffort.self] ?? .high
    let environmentContext = EnvironmentContext(
      model: LLMZoo.humanReadableNameForModel(model), provider: "Local, via s4nnc",
      pythonLibraryURL: Bundle.main.resourceURL?.appendingPathComponent(
        "Library", isDirectory: true))
    let systemPromptModel = (model as NSString).deletingPathExtension
    switch textGenerator {
    case let textGenerator as Qwen3_5TextGenerator:
      let systemPromptTemplate = SystemPromptTemplate.load(
        projectURL: projectURL, model: systemPromptModel,
        template: systemPromptForQwen3_5)
      codeAgent = Qwen3_5CodeAgent(
        textGenerator: textGenerator, graph: graph, streamContext: streamContext,
        unsafeTokenizer: Qwen3_5TextGenerator.unsafeTokenizer,
        safeTokenizer: textGenerator.safeTokenizer,
        systemPromptTemplate: systemPromptTemplate,
        reasoningEffort: .init(reasoningEffort),
        skillCatalog: skillCatalog,
        projectContext: projectContext,
        environmentContext: environmentContext,
        memoryContext: systemSeenMemoryContext,
        prefixTokens: prefixTokens, prefixEmbedSpans: prefixEmbedSpans,
        bashToolContext: bashToolContext,
        shouldInjectSystemSeenMemoryContext: shouldInjectSystemSeenMemoryContext)
    case let textGenerator as DeepSeek4TextGenerator:
      guard prefixEmbedSpans.isEmpty else { return nil }
      let systemPromptTemplate = SystemPromptTemplate.load(
        projectURL: projectURL, model: systemPromptModel,
        template: systemPromptForDeepSeek4)
      codeAgent = DeepSeek4CodeAgent(
        textGenerator: textGenerator, graph: graph, streamContext: streamContext,
        unsafeTokenizer: DeepSeek4TextGenerator.unsafeTokenizer,
        safeTokenizer: textGenerator.safeTokenizer,
        systemPromptTemplate: systemPromptTemplate,
        reasoningEffort: .init(reasoningEffort),
        skillCatalog: skillCatalog,
        projectContext: projectContext,
        environmentContext: environmentContext,
        memoryContext: systemSeenMemoryContext,
        prefixTokens: prefixTokens, prefixEmbedSpans: prefixEmbedSpans,
        bashToolContext: bashToolContext,
        shouldInjectSystemSeenMemoryContext: shouldInjectSystemSeenMemoryContext)
    case let textGenerator as DeepSeek4_1TextGenerator:
      let systemPromptTemplate = SystemPromptTemplate.load(
        projectURL: projectURL, model: systemPromptModel,
        template: systemPromptForDeepSeek4_1)
      codeAgent = DeepSeek4CodeAgent(
        textGenerator: textGenerator, graph: graph, streamContext: streamContext,
        unsafeTokenizer: DeepSeek4_1TextGenerator.unsafeTokenizer,
        safeTokenizer: textGenerator.safeTokenizer,
        systemPromptTemplate: systemPromptTemplate,
        reasoningEffort: .init(reasoningEffort),
        skillCatalog: skillCatalog,
        projectContext: projectContext,
        environmentContext: environmentContext,
        memoryContext: systemSeenMemoryContext,
        prefixTokens: prefixTokens, prefixEmbedSpans: prefixEmbedSpans,
        bashToolContext: bashToolContext,
        shouldInjectSystemSeenMemoryContext: shouldInjectSystemSeenMemoryContext)
    default:
      preconditionFailure("Unsupported text generator")
    }
    let thinkingBudget = workspace.dictionary["thinking_budget", Int.self] ?? 65_536
    codeAgent.thinkingBudget = Int32(min(max(thinkingBudget, 0), 128 * 1024))
    let workAttitude = workspace.dictionary["work_attitude", WorkAttitude.self] ?? .deterministic
    codeAgent.deterministic = workAttitude == .deterministic
    return .local(textGenerator, codeAgent)
  }

  private func agentTranscript(
    from tokens: [Int32], version: LLMVersion
  ) -> [AgentTranscriptEntry] {
    switch version {
    case .qwen_3_5_4b, .qwen_3_5_9b, .qwen_3_5_27b:
      return Qwen3_5CodeAgent.parse(tokens)
    case .deepseek_4_flash:
      return DeepSeek4CodeAgent<DeepSeek4TextGenerator>.parse(tokens)
    case .deepseek_4_1_flash:
      return DeepSeek4CodeAgent<DeepSeek4_1TextGenerator>.parse(tokens)
    }
  }

  private func localTokens(
    for transcript: [AgentTranscriptEntry], version: LLMVersion
  ) -> [Int32] {
    switch version {
    case .qwen_3_5_4b, .qwen_3_5_9b, .qwen_3_5_27b:
      return Qwen3_5CodeAgent.parse(transcript)
    case .deepseek_4_flash:
      return DeepSeek4CodeAgent<DeepSeek4TextGenerator>.parse(transcript)
    case .deepseek_4_1_flash:
      return DeepSeek4CodeAgent<DeepSeek4_1TextGenerator>.parse(transcript)
    }
  }

}
