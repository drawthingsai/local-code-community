import BashToolContext
import Combine
import DeviceLink
import Foundation
import GRPC
import Localization
import ProjectHistoryManager
import QuartzCore
import UIKit

protocol MacThreadControllerDelegate: AnyObject {
  /// The first message made the thread; the drawer shows it as the open one.
  func macThreadController(_ controller: MacThreadController, didStartThread ref: ThreadRef)
  /// The Mac deleted the thread, or it's gone.
  func macThreadControllerDidEnd(_ controller: MacThreadController)
  func macThreadController(_ controller: MacThreadController, didUpdate metrics: Metrics)
  func macThreadController(_ controller: MacThreadController, didFailWith message: String)
  /// The model the thread's next message runs on changed, or the Mac's models arrived.
  func macThreadControllerDidChangeModel(_ controller: MacThreadController)
}

/// A thread on one of the account's Macs, open in a phone's chat: it watches the thread and shows
/// what the Mac says (its history, its queue, and the running turn, rendered as the Mac renders
/// its own), and sends, stops and steers on the Mac. Before its first message the thread doesn't
/// exist yet; sending makes it in the project. Main queue only.
final class MacThreadController {
  let project: MacProject
  let macName: String
  private(set) var ref: ThreadRef?
  weak var delegate: MacThreadControllerDelegate?

  private let connection: MacConnection
  private let viewController: any ChatViewControllable
  private let chatInputController: ChatInputController
  private var watch: MacWatch?
  private var linkSubscription: AnyCancellable?
  /// The models the Mac's threads can run on, once the Mac said.
  private(set) var models: ModelList?
  /// The thread's model on the Mac, once it said.
  private var threadModel: ThreadModel?
  /// Picked here; the thread moves to it with its next message, as on the Mac's composer.
  private var pickedModel: ThreadModel?
  private var history = [HistoryMessage]()
  private var turn: Turn?
  private var isReconnecting = false
  private var isClosed = false
  /// Where the thread's files land, at their paths in the project, so the chat shows and opens
  /// them as it does a project's.
  private let filesURL: URL
  private var localPathResolver: LocalPathResolver
  private var requestedFiles = Set<String>()
  /// A file a message links to is fetched on its own up to this size, and this many per thread.
  private static let maximumFileSize: UInt64 = 32 << 20
  private static let maximumFileCount = 64
  /// A Markdown link's or image's target: `](path)` or `](<path>)`.
  private static let linkExpression = try! NSRegularExpression(
    pattern: #"\]\((<[^>]+>|[^)\s]+)\)"#)

  /// A turn as the Mac reports it: reading, then the step's reasoning, its answer, or its running
  /// tools under the ones that finished.
  private final class Turn {
    let id: String
    let startTime = CACurrentMediaTime()
    let bashUserInteraction = BashUserInteraction()
    var answer = ""
    var thinking = ""
    var isThinking = false
    var tokens = 0
    var finishedTools = [String]()
    var runningTools = [(id: String, subtitle: String)]()
    var reading: (finished: Int, total: Int, isCompacting: Bool)? = (0, 0, false)
    var finished: TurnFinished?

    init(id: String) {
      self.id = id
    }
  }

  init(
    project: MacProject, threadID: Int64?, macName: String, connection: MacConnection,
    viewController: any ChatViewControllable, chatInputController: ChatInputController
  ) {
    self.project = project
    self.macName = macName
    self.connection = connection
    self.viewController = viewController
    self.chatInputController = chatInputController
    let cachesURL =
      FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).last
      ?? FileManager.default.temporaryDirectory
    filesURL = cachesURL.appendingPathComponent("MacThreads", isDirectory: true)
      .appendingPathComponent(
        project.deviceID.replacingOccurrences(of: "/", with: "_"), isDirectory: true
      )
      .appendingPathComponent(project.projectID, isDirectory: true)
    try? FileManager.default.createDirectory(at: filesURL, withIntermediateDirectories: true)
    localPathResolver = LocalPathResolver(projectPath: filesURL.path, workspacePath: filesURL.path)
    viewController.setLocalPathResolver(localPathResolver, refreshVisibleCells: false)
    viewController.setHistory([])
    viewController.setQueuedItems([], animated: false)
    viewController.setSteeringQueuedItems([])
    chatInputController.sendState = .idle
    // While the link is down, a running turn says so in place of its status.
    var wasConnected = false
    linkSubscription = connection.linkState.removeDuplicates().receive(on: DispatchQueue.main)
      .sink { [weak self] linkState in
        guard let self else { return }
        if linkState == .connected { wasConnected = true }
        let isReconnecting = wasConnected && linkState == .lost
        guard isReconnecting != self.isReconnecting else { return }
        self.isReconnecting = isReconnecting
        self.renderTurn()
      }
    if let threadID { startWatching(project.thread(threadID)) }
    loadModels()
  }

  /// What the thread's next message runs on: the model picked here, the thread's own, or the Mac's
  /// selection for a new thread.
  var model: ThreadModel? {
    pickedModel ?? threadModel ?? models.flatMap { $0.hasDefaultModel ? $0.defaultModel : nil }
  }

  /// Asks the Mac which models its threads can run on, as when the model selector opens.
  func loadModels() {
    connection.listModels { [weak self] result in
      guard case .success(let models) = result else { return }
      DispatchQueue.main.async {
        guard let self, !self.isClosed else { return }
        self.models = models
        self.delegate?.macThreadControllerDidChangeModel(self)
      }
    }
  }

  /// The thread's next message runs on `model`, one of the Mac's.
  func pick(_ model: ThreadModel) {
    pickedModel = model == threadModel ? nil : model
    delegate?.macThreadControllerDidChangeModel(self)
  }

  /// Ends the watch; the thread goes on on the Mac.
  func close() {
    isClosed = true
    watch?.cancel()
    watch = nil
    linkSubscription = nil
  }

  private func startWatching(_ ref: ThreadRef) {
    self.ref = ref
    watch = connection.watchThread(ref) { [weak self] event in
      DispatchQueue.main.async { self?.handle(event) }
    } ended: { [weak self] status in
      DeviceLinkService.logger.info(
        "a Mac ended a thread watch: \(String(describing: status.code), privacy: .public)")
      DispatchQueue.main.async {
        guard let self, !self.isClosed else { return }
        self.delegate?.macThreadControllerDidEnd(self)
      }
    }
  }

  // MARK: - What the Mac says

  private func handle(_ event: ThreadEvent) {
    guard !isClosed else { return }
    switch event.event {
    case .history(let history):
      // In place of every message after the history's start.
      self.history.removeAll { $0.datetimeMs > history.afterMessageDatetimeMs }
      history.messages.forEach(merge)
      renderAll()
      fetchFiles(of: history.messages)
    case .message(let message):
      merge(message)
      // The turn's answer, saved: the history shows it now.
      if let finished = turn?.finished, finished.messageDatetimeMs == message.datetimeMs {
        turn = nil
      }
      renderAll()
      fetchFiles(of: [message])
    case .queue(let queue):
      let threadID = ref?.threadID ?? -1
      viewController.setQueuedItems(
        queue.messages.map {
          ProjectQueuedItem(
            threadId: threadID, datetime: $0.datetimeMs, text: $0.text, imagePaths: [])
        }, animated: true)
    case .turn(let event):
      handle(event)
    case .deleted:
      delegate?.macThreadControllerDidEnd(self)
    case .model(let model):
      threadModel = model
      if pickedModel == model { pickedModel = nil }
      delegate?.macThreadControllerDidChangeModel(self)
    case nil:
      break
    }
  }

  /// A message once, by when it was saved, the history kept in order.
  private func merge(_ message: HistoryMessage) {
    if let index = history.firstIndex(where: { $0.datetimeMs == message.datetimeMs }) {
      history[index] = message
    } else {
      history.append(message)
      history.sort { $0.datetimeMs < $1.datetimeMs }
    }
  }

  private func handle(_ event: TurnEvent) {
    // The Mac no longer has the turn: one still showing as running ends, with the history as the
    // Mac has it.
    if case .finished(let finished)? = event.event, finished.outcome == .gone {
      guard turn?.id == event.turnID, turn?.finished == nil else { return }
      turn = nil
      chatInputController.sendState = .idle
      renderAll()
      return
    }
    if turn?.id != event.turnID {
      turn = Turn(id: event.turnID)
      renderAll()
    }
    guard let turn else { return }
    switch event.event {
    case .reading(let progress), .compacting(let progress):
      var isCompacting = false
      if case .compacting = event.event { isCompacting = true }
      turn.reading = (Int(progress.finishedTokens), Int(progress.totalTokens), isCompacting)
    case .thinking(let update):
      turn.reading = nil
      turn.isThinking = true
      turn.thinking = update.replaces ? update.text : turn.thinking + update.text
      turn.tokens = Int(update.tokens)
    case .answer(let update):
      turn.reading = nil
      turn.isThinking = false
      turn.answer = update.replaces ? update.text : turn.answer + update.text
      turn.tokens = Int(update.tokens)
    case .toolStarted(let started):
      turn.reading = nil
      turn.runningTools.append((started.callID, started.subtitle))
    case .toolFinished(let finished):
      turn.runningTools.removeAll { $0.id == finished.callID }
      turn.finishedTools.append(finished.subtitle)
    case .metrics(let metrics):
      delegate?.macThreadController(self, didUpdate: metrics)
      return
    case .finished(let finished):
      turn.finished = finished
      chatInputController.sendState = .idle
      let isSaved =
        finished.messageDatetimeMs != 0
        && history.contains { $0.datetimeMs == finished.messageDatetimeMs }
      // Saved already, or stopped with nothing to save: the history is the whole thread again.
      // Otherwise the turn stays as it ended until its answer arrives, or says why it failed.
      if isSaved || finished.messageDatetimeMs == 0 && finished.outcome != .failed {
        self.turn = nil
        renderAll()
        return
      }
    case nil:
      return
    }
    renderTurn()
  }

  // MARK: - Rendering

  /// The history, then the running turn's message.
  private func renderAll() {
    viewController.setHistory(
      history.map { message in
        let datetime = Date(timeIntervalSince1970: Double(message.datetimeMs) / 1_000)
        switch message.role {
        case .assistant:
          return .assistant(message.text, datetime: datetime, duration: message.durationSeconds)
        default:
          return .user(message.text, datetime: datetime)
        }
      })
    guard let turn else { return }
    if turn.finished == nil { chatInputController.sendState = .sending }
    viewController.appendAssistant(
      "", isTransient: true,
      mode: .reading(
        0, 0, startTime: turn.startTime, bashUserInteraction: turn.bashUserInteraction))
    renderTurn()
  }

  /// The running turn's message, as the Mac shows its own (updatePartialResult).
  private func renderTurn() {
    guard let turn else { return }
    let viewController = viewController
    let startTime = turn.startTime
    let bashUserInteraction = turn.bashUserInteraction
    let history = turn.finishedTools.joined(separator: "\n")
    if let finished = turn.finished {
      // Failed, or stopped before saving: what the turn said, and why it ended.
      let text = [history, turn.answer, finished.errorMessage].filter { !$0.isEmpty }
        .joined(separator: "\n---\n")
      viewController.setLastMessage(text, isTransient: false, mode: .none)
      return
    }
    if isReconnecting {
      let notice = String(format: LocalizedString.forKey("device_link_reconnecting_to"), macName)
      viewController.setLastMessage(
        [history, notice].filter { !$0.isEmpty }.joined(separator: "\n---\n"), isTransient: true,
        mode: .reading(0, 0, startTime: startTime, bashUserInteraction: bashUserInteraction))
    } else if let reading = turn.reading {
      viewController.setLastMessage(
        history, isTransient: true,
        mode: reading.isCompacting
          ? .compacting(
            reading.finished, reading.total, startTime: startTime,
            bashUserInteraction: bashUserInteraction)
          : .reading(
            reading.finished, reading.total, startTime: startTime,
            bashUserInteraction: bashUserInteraction))
    } else if !turn.runningTools.isEmpty {
      viewController.setLastMessage(
        history, thinking: "",
        output: [turn.answer, turn.runningTools.map(\.subtitle).joined(separator: "\n")].filter {
          !$0.isEmpty
        }.joined(separator: "\n---\n"), datetime: nil, duration: 0, isTransient: true,
        mode: .working(turn.tokens, startTime: startTime, bashUserInteraction: bashUserInteraction)
      )
    } else if turn.isThinking || turn.answer.isEmpty {
      viewController.setLastMessage(
        history, thinking: ChatWorkflow.chainOfThoughtExcerpt(turn.thinking), output: "",
        datetime: nil,
        duration: 0, isTransient: true,
        mode: .thinking(
          turn.tokens, startTime: startTime, bashUserInteraction: bashUserInteraction))
    } else {
      viewController.setLastMessage(
        [history, turn.answer].filter { !$0.isEmpty }.joined(separator: "\n---\n"),
        isTransient: false, mode: .none)
    }
  }

  // MARK: - Files

  /// Fetches the files the messages link to and attach, each once while the thread is open; the
  /// Mac serves only those the thread made. Each one arriving shows in the messages that link to
  /// it.
  private func fetchFiles(of messages: [HistoryMessage]) {
    guard let ref else { return }
    for message in messages {
      let text = message.text as NSString
      let linked = Self.linkExpression.matches(
        in: message.text, range: NSRange(location: 0, length: text.length)
      ).map { match -> String in
        var path = text.substring(with: match.range(at: 1))
        if path.hasPrefix("<"), path.hasSuffix(">") { path = String(path.dropFirst().dropLast()) }
        return path.removingPercentEncoding ?? path
      }
      for path in linked + ChatAttachment.parseSections(message.text).paths {
        guard requestedFiles.count < Self.maximumFileCount, !path.contains("://"),
          let relativePath = ThreadFiles.normalized(path, in: filesURL),
          requestedFiles.insert(relativePath).inserted
        else { continue }
        let destination = filesURL.appendingPathComponent(relativePath)
        let download = filesURL.appendingPathComponent(".\(UUID().uuidString)")
        connection.readFile(
          relativePath, in: ref, to: download, maximumSize: Self.maximumFileSize
        ) { [weak self] result in
          DispatchQueue.main.async {
            guard let self, !self.isClosed, case .success = result else {
              try? FileManager.default.removeItem(at: download)
              return
            }
            let fileManager = FileManager.default
            try? fileManager.createDirectory(
              at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fileManager.removeItem(at: destination)
            guard (try? fileManager.moveItem(at: download, to: destination)) != nil else { return }
            self.localPathResolver.revision += 1
            self.viewController.setLocalPathResolver(
              self.localPathResolver, refreshVisibleCells: true)
          }
        }
      }
    }
  }

  // MARK: - Sending

  /// Starts a turn on the Mac, or queues the message behind the running one. The first message
  /// makes the thread.
  func send(_ prompt: String, attachments: [ChatAttachment], steer: Bool = false) {
    var request = SendMessageRequest()
    if let ref {
      request.thread = ref
    } else {
      request.projectID = project.projectID
    }
    request.text = prompt
    request.steer = steer
    if let model { request.model = model }
    request.attachments = attachments.compactMap { attachment in
      guard let data = try? Data(contentsOf: attachment.url) else { return nil }
      return FileAttachment.with {
        $0.name = attachment.name
        $0.data = data
      }
    }
    if turn == nil || turn?.finished != nil { chatInputController.sendState = .sending }
    connection.send(request) { [weak self] result in
      DispatchQueue.main.async {
        guard let self, !self.isClosed else { return }
        switch result {
        case .success(let response):
          if self.ref == nil {
            self.startWatching(response.thread)
            self.delegate?.macThreadController(self, didStartThread: response.thread)
          }
        case .failure(let status):
          if self.turn == nil || self.turn?.finished != nil {
            self.chatInputController.sendState = .idle
          }
          self.delegate?.macThreadController(
            self,
            didFailWith: status.message
              ?? String(format: LocalizedString.forKey("device_link_connect_failed"), self.macName))
        }
      }
    }
  }

  func stop() {
    guard let ref, let turn, turn.finished == nil else { return }
    chatInputController.sendState = .stopping
    connection.stopTurn(in: ref) { [weak self] result in
      guard case .failure = result else { return }
      // The Mac can't be reached, as when it quit: the turn stops showing here. One the Mac is
      // still running comes back when the watch picks up.
      DispatchQueue.main.async {
        guard let self, !self.isClosed, self.turn === turn, turn.finished == nil else { return }
        self.turn = nil
        self.chatInputController.sendState = .idle
        self.renderAll()
      }
    }
  }

  /// Sends the queued message at once, stopping the running turn, as steering does on the Mac.
  func steer(_ queuedItem: ProjectQueuedItem) {
    guard let ref else { return }
    viewController.setSteeringQueuedItems([queuedItem])
    let text = queuedItem.text ?? ""
    connection.removeQueuedMessage(in: ref, datetime: queuedItem.datetime) { [weak self] result in
      DispatchQueue.main.async {
        guard let self, !self.isClosed else { return }
        self.viewController.setSteeringQueuedItems([])
        guard case .success = result else { return }
        self.send(text, attachments: [], steer: true)
      }
    }
  }

  func remove(_ queuedItem: ProjectQueuedItem) {
    guard let ref else { return }
    connection.removeQueuedMessage(in: ref, datetime: queuedItem.datetime)
  }
}
