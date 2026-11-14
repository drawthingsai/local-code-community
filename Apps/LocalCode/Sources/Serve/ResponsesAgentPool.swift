/// Agents between turns, each holding the KV cache of the prompt it last evaluated. Expiring one
/// follows 2Q: conversations that never came back go first, oldest first, and then the ones that
/// did, least recently used first. A one-off request can't push out a conversation in use.
struct ResponsesAgentPool<Agent: AnyObject> {
  private struct Entry {
    let agent: Agent
    let prompt: ResponsesPrompt
    let conversation: ResponsesPrompt
  }

  private var firstUse = [Entry]()
  private var reused = [Entry]()

  var count: Int { firstUse.count + reused.count }
  var agents: [Agent] { (firstUse + reused).map(\.agent) }

  /// Takes the agent whose prompt `prompt` continues, the longest if there are several. Comparing
  /// the tokens costs far less than the tokenizing it follows, so there's no hash to keep in step.
  mutating func takeAgent(continuing prompt: ResponsesPrompt) -> Agent? {
    takeLongest { prompt.continues($0.prompt) ? $0.prompt.tokens.count : nil }
  }

  /// Takes the agent whose last turn replied to a conversation that `prompt` goes on with, the
  /// longest if there are several. That's the conversation coming back with the reply in another
  /// form than the model's, or asking again, so nothing will continue the agent's KV cache. The
  /// conversation starts over in it rather than in a new agent, which would leave this one holding
  /// a cache of no use until it expires.
  mutating func takeAgent(supersededBy prompt: ResponsesPrompt) -> Agent? {
    takeLongest { prompt.continues($0.conversation) ? $0.conversation.tokens.count : nil }
  }

  /// `conversation` is the prompt of the request the turn answered, without its reply opening.
  /// `wasReused` says the turn's conversation came back to the agent.
  mutating func add(
    _ agent: Agent, prompt: ResponsesPrompt, conversation: ResponsesPrompt, wasReused: Bool
  ) {
    let entry = Entry(agent: agent, prompt: prompt, conversation: conversation)
    if wasReused {
      reused.append(entry)
    } else {
      firstUse.append(entry)
    }
  }

  mutating func expire() -> Agent? {
    if !firstUse.isEmpty {
      return firstUse.removeFirst().agent
    }
    return reused.isEmpty ? nil : reused.removeFirst().agent
  }

  mutating func removeAll() -> [Agent] {
    let agents = self.agents
    firstUse = []
    reused = []
    return agents
  }

  mutating func remove(_ agents: [Agent]) {
    let isListed: (Entry) -> Bool = { entry in agents.contains { $0 === entry.agent } }
    firstUse.removeAll(where: isListed)
    reused.removeAll(where: isListed)
  }

  /// Takes the agent of the longest match, as `length` measures the entries that match and gives
  /// nil for the rest. A tie goes to the conversation that came back.
  private mutating func takeLongest(_ length: (Entry) -> Int?) -> Agent? {
    let firstUseMatch = firstUse.indices.compactMap { index in
      length(firstUse[index]).map { (index: index, length: $0) }
    }.max { $0.length < $1.length }
    let reusedMatch = reused.indices.compactMap { index in
      length(reused[index]).map { (index: index, length: $0) }
    }.max { $0.length < $1.length }
    if let firstUseMatch, firstUseMatch.length > reusedMatch?.length ?? 0 {
      return firstUse.remove(at: firstUseMatch.index).agent
    }
    return reusedMatch.map { reused.remove(at: $0.index).agent }
  }
}
