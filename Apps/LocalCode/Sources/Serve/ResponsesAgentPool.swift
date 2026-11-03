/// Agents between turns, each holding the KV cache of the tokens it last evaluated. Expiring one
/// follows 2Q: conversations that never came back go first, oldest first, and then the ones that
/// did, least recently used first. A one-off request can't push out a conversation in use.
struct ResponsesAgentPool<Agent: AnyObject> {
  private struct Entry {
    let agent: Agent
    let tokens: [Int32]
  }

  private var firstUse = [Entry]()
  private var reused = [Entry]()

  var count: Int { firstUse.count + reused.count }
  var agents: [Agent] { (firstUse + reused).map(\.agent) }

  /// Takes the agent whose tokens `tokens` continues, the longest if there are several. Comparing
  /// the tokens costs far less than the tokenizing it follows, so there's no hash to keep in step.
  mutating func takeAgent(continuing tokens: [Int32]) -> Agent? {
    let continues: (Entry) -> Bool = {
      $0.tokens.count < tokens.count && tokens.starts(with: $0.tokens)
    }
    let longestFirstUse = firstUse.indices.filter { continues(firstUse[$0]) }.max {
      firstUse[$0].tokens.count < firstUse[$1].tokens.count
    }
    let longestReused = reused.indices.filter { continues(reused[$0]) }.max {
      reused[$0].tokens.count < reused[$1].tokens.count
    }
    if let longestFirstUse,
      firstUse[longestFirstUse].tokens.count > longestReused.map({ reused[$0].tokens.count }) ?? 0
    {
      return firstUse.remove(at: longestFirstUse).agent
    }
    return longestReused.map { reused.remove(at: $0).agent }
  }

  /// `wasReused` says the turn that just ended continued an earlier one.
  mutating func add(_ agent: Agent, tokens: [Int32], wasReused: Bool) {
    let entry = Entry(agent: agent, tokens: tokens)
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
