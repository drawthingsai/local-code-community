import DeviceLink
import Foundation
import GRPC
import RemoteAPI

/// A Mac's own model as Remote Access names it for a device's threads (`RemoteProvider.deviceLink`):
/// the model's file on the Mac, then the Mac.
struct MacModel: Equatable {
  let file: String
  let deviceID: String

  init(file: String, deviceID: String) {
    self.file = file
    self.deviceID = deviceID
  }

  init?(_ model: String) {
    guard let separator = model.lastIndex(of: "@") else { return nil }
    file = String(model[..<separator])
    deviceID = String(model[model.index(after: separator)...])
    guard !file.isEmpty, !deviceID.isEmpty else { return nil }
  }

  var model: String { "\(file)@\(deviceID)" }
}

/// One of a Mac's own models as a remote agent's chat provider: each request is a step the Mac
/// runs over the device's link (Inference), while the agent and its tools stay on the device.
final class MacModelChatProvider: RemoteChatProviding {
  let modelIdentity: RemoteModelIdentity
  /// The Mac reads the transcript's text; images stay links the tools can open.
  var supportsImageInput: Bool { false }

  private let connection: MacConnection
  private let file: String
  private let sessionID: String
  private let maximumOutputTokens: Int

  /// `sessionID` names the device's thread, so the Mac reuses what it read of it.
  init(
    connection: MacConnection, model: MacModel, sessionID: String, maximumOutputTokens: Int,
    modelIdentity: RemoteModelIdentity
  ) {
    self.connection = connection
    file = model.file
    self.sessionID = sessionID
    self.maximumOutputTokens = maximumOutputTokens
    self.modelIdentity = modelIdentity
  }

  @discardableResult
  func streamChat(
    messages: [RemoteTranscriptEntry], tools: [RemoteFunctionTool],
    progress: @escaping (RemoteStreamProgress) -> Void,
    completion: @escaping (Result<RemoteCompletion, RemoteChatError>) -> Void
  ) -> RemoteRequestCancellable {
    let cancellation = Cancellation()
    guard let transcript = try? JSONEncoder().encode(messages),
      let toolsJSON = try? JSONEncoder().encode(tools)
    else {
      completion(.failure(.malformedStream("The thread couldn't be sent to the Mac.")))
      return cancellation
    }
    let request = StepRequest.with {
      $0.modelID = file
      $0.sessionID = sessionID
      $0.transcriptJson = transcript
      $0.toolsJson = toolsJSON
      $0.maximumOutputTokens = UInt32(clamping: maximumOutputTokens)
    }
    // Events and the end come on the connection's queue, in order.
    var result: InferenceStepCompletion?
    cancellation.cancelStep = connection.step(request) { event in
      switch event.event {
      case .progressJson(let data):
        guard let content = try? JSONDecoder().decode([RemoteContentBlock].self, from: data)
        else { return }
        progress(RemoteStreamProgress(content: content))
      case .completionJson(let data):
        result = try? JSONDecoder().decode(InferenceStepCompletion.self, from: data)
      case .reading, nil:
        break
      }
    } completion: { status in
      guard status.isOk else {
        completion(
          .failure(
            status.code == .cancelled
              ? .cancelled
              : .provider(
                statusCode: status.code.rawValue,
                message: status.message ?? "Couldn't reach the Mac.")))
        return
      }
      guard let result else {
        completion(.failure(.emptyResponse))
        return
      }
      completion(
        .success(
          RemoteCompletion(
            content: result.content, usage: result.usage, stopReason: result.stopReason)))
    }
    return cancellation
  }

  private final class Cancellation: RemoteRequestCancellable {
    var cancelStep: (() -> Void)?

    func cancel() {
      cancelStep?()
    }
  }
}
