import CLICloudAuth
import Downloader
import Foundation
import ImageGenerator
import ios_system

/// Host capabilities available to commands during one Bash job. The callbacks
/// own their threading; this object does not expose an agent or its graph.
public final class BashToolContext {
  public typealias PermitDirectory = (
    URL, BashUserInteraction, @escaping () -> Bool, @escaping (Result<URL, Error>) -> Void
  ) -> Void

  /// The host returns an app's data folder, such as the Messages folder, with its security scope
  /// started, from the saved read-only grant or, when the Boolean is true, by asking the user.
  /// The caller stops the scope. These grants are kept apart from permitted directories.
  public typealias AccessAppDataDirectory = (
    Bool, BashUserInteraction, @escaping () -> Bool, @escaping (Result<URL, Error>) -> Void
  ) -> Void

  /// The host succeeds when access to a protected resource, such as Calendar or Photos, is
  /// allowed, asking the user on first use when the Boolean is true.
  public typealias AccessProtectedResource = (
    Bool, BashUserInteraction, @escaping (Result<Void, Error>) -> Void
  ) -> Void

  /// The host presents a secure password prompt. A nil response cancels the request.
  /// The Boolean indicates that a previous password was incorrect.
  public typealias RequestPDFPassword = (
    URL, Bool, BashUserInteraction, @escaping (String?) -> Void
  ) -> Void

  /// App-owned browser commands. The host retains tabs and owns main-thread WebKit work.
  public typealias BrowseWeb = (
    [String], URL, URL?, Int64?, @escaping () -> Bool, @escaping (Result<String, Error>) -> Void
  ) -> Void

  public let requestPDFPassword: RequestPDFPassword?
  public let browseWeb: BrowseWeb?
  public let accountProvider: ToolAccountProvider?
  public let resloveDrawThingsModelsDirectory:
    ((URL?, BashUserInteraction, @escaping (Result<URL, Error>) -> Void) -> Void)?
  public let bashUserInteraction: BashUserInteraction
  public let unloadTextGenerator: (() -> Void)?
  public let modelDownloadEvent: ((ModelDownloadEvent, URL, Int64) -> Void)?
  public let imageGenerationEvent: ((ImageGenerationEvent, URL, Int64) -> Void)?
  public let projectURL: URL?
  public let threadId: Int64?
  public let permitDirectory: PermitDirectory?
  public let accessMessagesDirectory: AccessAppDataDirectory?
  public let accessMailDirectory: AccessAppDataDirectory?
  public let accessNotesDirectory: AccessAppDataDirectory?
  public let accessCalendar: AccessProtectedResource?
  public let accessPhotos: AccessProtectedResource?
  public let permittedDirectoryURLs: () -> [URL]

  public init(
    accountProvider: ToolAccountProvider? = nil,
    resloveDrawThingsModelsDirectory:
      ((URL?, BashUserInteraction, @escaping (Result<URL, Error>) -> Void) -> Void)? = nil,
    bashUserInteraction: BashUserInteraction = BashUserInteraction(),
    unloadTextGenerator: (() -> Void)? = nil,
    modelDownloadEvent: ((ModelDownloadEvent, URL, Int64) -> Void)? = nil,
    imageGenerationEvent: ((ImageGenerationEvent, URL, Int64) -> Void)? = nil,
    projectURL: URL? = nil, threadId: Int64? = nil,
    permitDirectory: PermitDirectory? = nil,
    accessMessagesDirectory: AccessAppDataDirectory? = nil,
    accessMailDirectory: AccessAppDataDirectory? = nil,
    accessNotesDirectory: AccessAppDataDirectory? = nil,
    accessCalendar: AccessProtectedResource? = nil,
    accessPhotos: AccessProtectedResource? = nil,
    requestPDFPassword: RequestPDFPassword? = nil,
    browseWeb: BrowseWeb? = nil,
    permittedDirectoryURLs: @escaping () -> [URL] = { [] }
  ) {
    self.accountProvider = accountProvider
    self.resloveDrawThingsModelsDirectory = resloveDrawThingsModelsDirectory
    self.bashUserInteraction = bashUserInteraction
    self.unloadTextGenerator = unloadTextGenerator
    self.modelDownloadEvent = modelDownloadEvent
    self.imageGenerationEvent = imageGenerationEvent
    self.projectURL = projectURL
    self.threadId = threadId
    self.requestPDFPassword = requestPDFPassword
    self.browseWeb = browseWeb
    self.permitDirectory = permitDirectory
    self.accessMessagesDirectory = accessMessagesDirectory
    self.accessMailDirectory = accessMailDirectory
    self.accessNotesDirectory = accessNotesDirectory
    self.accessCalendar = accessCalendar
    self.accessPhotos = accessPhotos
    self.permittedDirectoryURLs = permittedDirectoryURLs
  }

  public func with(
    bashUserInteraction: BashUserInteraction? = nil, unloadTextGenerator: (() -> Void)? = nil,
    projectURL: URL? = nil, threadId: Int64? = nil
  ) -> BashToolContext {
    BashToolContext(
      accountProvider: accountProvider,
      resloveDrawThingsModelsDirectory: resloveDrawThingsModelsDirectory,
      bashUserInteraction: bashUserInteraction ?? self.bashUserInteraction,
      unloadTextGenerator: unloadTextGenerator ?? self.unloadTextGenerator,
      modelDownloadEvent: modelDownloadEvent, imageGenerationEvent: imageGenerationEvent,
      projectURL: projectURL ?? self.projectURL, threadId: threadId ?? self.threadId,
      permitDirectory: permitDirectory, accessMessagesDirectory: accessMessagesDirectory,
      accessMailDirectory: accessMailDirectory, accessNotesDirectory: accessNotesDirectory,
      accessCalendar: accessCalendar,
      accessPhotos: accessPhotos,
      requestPDFPassword: requestPDFPassword,
      browseWeb: browseWeb,
      permittedDirectoryURLs: permittedDirectoryURLs)
  }

  public static var current: BashToolContext? {
    get { Thread.current.threadDictionary[ios_commandContextKey] as? BashToolContext }
    set {
      if let newValue {
        Thread.current.threadDictionary[ios_commandContextKey] = newValue
      } else {
        Thread.current.threadDictionary.removeObject(forKey: ios_commandContextKey)
      }
    }
  }
}
