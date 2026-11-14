/// Agents between turns, each holding the KV cache of the prompt it last evaluated. Expiring one
/// follows 2Q: conversations that never came back go first, oldest first, and then the ones that
/// did, least recently used first. A one-off request can't push out a conversation in use.
struct ResponsesAgentPool<Agent: AnyObject> {
  private struct Entry {
    let agent: Agent
    let prompt: ResponsesPrompt
  }

  private var firstUse = [Entry]()
  private var reused = [Entry]()

  var count: Int { firstUse.count + reused.count }
  var agents: [Agent] { (firstUse + reused).map(\.agent) }

  /// Takes the agent whose prompt `prompt` continues, the longest if there are several. Comparing
  /// the tokens costs far less than the tokenizing it follows, so there's no hash to keep in step.
  mutating func takeAgent(continuing prompt: ResponsesPrompt) -> Agent? {
    let longestFirstUse = firstUse.indices.filter { prompt.continues(firstUse[$0].prompt) }.max {
      firstUse[$0].prompt.tokens.count < firstUse[$1].prompt.tokens.count
    }
    let longestReused = reused.indices.filter { prompt.continues(reused[$0].prompt) }.max {
      reused[$0].prompt.tokens.count < reused[$1].prompt.tokens.count
    }
    if let longestFirstUse,
      firstUse[longestFirstUse].prompt.tokens.count
        > longestReused.map({ reused[$0].prompt.tokens.count }) ?? 0
    {
      return firstUse.remove(at: longestFirstUse).agent
    }
    return longestReused.map { reused.remove(at: $0).agent }
  }

  /// `wasReused` says the turn that just ended continued an earlier one.
  mutating func add(_ agent: Agent, prompt: ResponsesPrompt, wasReused: Bool) {
    let entry = Entry(agent: agent, prompt: prompt)
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
}
