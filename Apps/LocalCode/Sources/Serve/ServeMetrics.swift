import Foundation

/// What the Serve page plots, since the app launched. Nothing here outlives the app.
struct ServeMetrics: Equatable {
  /// How the Mac was doing at a moment, whether or not a request was running.
  struct Sample: Equatable {
    let date: Date
    let generationTokensPerSecond: Double
    let memoryBytes: Int64
    let contextCacheBytes: Int64
  }

  /// A request that reached the model, however it ended.
  struct Request: Equatable, Identifiable {
    /// Counts up from 1.
    var id = 0
    let date: Date
    /// "completed", "incomplete", "failed" or "cancelled".
    let status: String
    let inputTokens: Int
    let cachedInputTokens: Int
    let outputTokens: Int
    let timing: ServeRequestTiming
    /// 0 when nothing was processed, as when everything came from the cache.
    let prefillTokensPerSecond: Double
    /// 0 when nothing was generated.
    let generationTokensPerSecond: Double
  }

  static let sampleInterval: TimeInterval = 2
  static let sampleWindow: TimeInterval = 300
  static let requestWindow = 30

  private(set) var samples = [Sample]()
  private(set) var requests = [Request]()
  private(set) var requestCount = 0
  private(set) var failedRequestCount = 0
  private(set) var inputTokens = 0
  private(set) var cachedInputTokens = 0
  private(set) var outputTokens = 0
  private var generatedTokens = 0
  private var sampledGeneratedTokens = 0

  /// The share of input tokens that didn't have to be processed again.
  var cacheReuse: Double? {
    inputTokens > 0 ? Double(cachedInputTokens) / Double(inputTokens) : nil
  }

  var medianTimeToFirstToken: Double? {
    let delays = requests.compactMap(\.timing.timeToFirstToken).sorted()
    guard !delays.isEmpty else { return nil }
    let middle = delays.count / 2
    return delays.count % 2 == 1 ? delays[middle] : (delays[middle - 1] + delays[middle]) / 2
  }

  /// The tokens a running request has just generated, for the next sample's rate. A rate from the
  /// agent only covers its own request, and misses the pauses behind the chat.
  mutating func addGeneratedTokens(_ count: Int) {
    generatedTokens += max(count, 0)
  }

  mutating func sample(at date: Date, memoryBytes: Int64, contextCacheBytes: Int64) {
    let elapsed = samples.last.map { date.timeIntervalSince($0.date) } ?? Self.sampleInterval
    let generated = generatedTokens - sampledGeneratedTokens
    sampledGeneratedTokens = generatedTokens
    samples.append(
      Sample(
        date: date, generationTokensPerSecond: elapsed > 0 ? Double(generated) / elapsed : 0,
        memoryBytes: memoryBytes, contextCacheBytes: contextCacheBytes))
    samples.removeAll { date.timeIntervalSince($0.date) > Self.sampleWindow }
  }

  mutating func add(_ request: Request) {
    var request = request
    requestCount += 1
    request.id = requestCount
    if request.status == "failed" {
      failedRequestCount += 1
    }
    inputTokens += request.inputTokens
    cachedInputTokens += request.cachedInputTokens
    outputTokens += request.outputTokens
    requests.append(request)
    if requests.count > Self.requestWindow {
      requests.removeFirst(requests.count - Self.requestWindow)
    }
  }
}

/// Where a request's time went, from the moment it arrived.
struct ServeRequestTiming: Equatable {
  enum Phase: Equatable {
    /// In line, or behind the chat.
    case waiting
    case prefilling
    case generating
  }

  private(set) var waitingSeconds: TimeInterval = 0
  private(set) var prefillSeconds: TimeInterval = 0
  private(set) var generationSeconds: TimeInterval = 0
  /// From arriving to the first token generated, however long it waited.
  private(set) var timeToFirstToken: TimeInterval?
  private let startDate: Date
  private var phase = Phase.waiting
  private var phaseDate: Date

  init(startDate: Date) {
    self.startDate = startDate
    phaseDate = startDate
  }

  mutating func enter(_ newPhase: Phase, at date: Date) {
    let elapsed = max(date.timeIntervalSince(phaseDate), 0)
    switch phase {
    case .waiting: waitingSeconds += elapsed
    case .prefilling: prefillSeconds += elapsed
    case .generating: generationSeconds += elapsed
    }
    if newPhase == .generating, timeToFirstToken == nil {
      timeToFirstToken = max(date.timeIntervalSince(startDate), 0)
    }
    phase = newPhase
    phaseDate = date
  }
}
