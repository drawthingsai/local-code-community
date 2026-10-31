import Foundation
import MarkdownEngine
import MarkdownEngineCodeBlocks
import MarkdownEngineLatex
import Nuke
import Style
import UIKit
import UniformTypeIdentifiers

struct ProjectDirectoryImageProvider: EmbeddedImageProvider, EmbeddedVideoProvider,
  EmbeddedHTMLProvider
{
  private final class RemoteImageDownloadTracker: @unchecked Sendable {
    private var loadingURLs = Set<URL>()
    private let lock = NSLock()

    func beginLoading(_ url: URL) -> Bool {
      lock.lock()
      defer { lock.unlock() }
      return loadingURLs.insert(url).inserted
    }

    func finishLoading(_ url: URL) {
      lock.lock()
      loadingURLs.remove(url)
      lock.unlock()
    }
  }

  private static let remoteImageDownloadTracker = RemoteImageDownloadTracker()
  var localPathResolver: LocalPathResolver?

  func image(for request: EmbeddedImageRequest) -> UIImage? {
    var path = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
    if path.first == "<", path.last == ">", path.count >= 2 {
      path = String(path.dropFirst().dropLast())
    }
    if let url = remoteURL(for: path) {
      return image(forRemoteURL: url)
    }
    path = path.removingPercentEncoding ?? path
    guard let url = localPathResolver?.resolve(path)?.url else {
      return nil
    }
    return UIImage(contentsOfFile: url.path)
  }

  func fingerprint() -> AnyHashable {
    localPathResolver?.fingerprint ?? AnyHashable("")
  }

  func localVideoURL(for name: String) -> URL? {
    var path = name.trimmingCharacters(in: .whitespacesAndNewlines)
    if path.first == "<", path.last == ">", path.count >= 2 {
      path = String(path.dropFirst().dropLast())
    }
    if let url = URL(string: path), url.scheme != nil, !url.isFileURL {
      return nil
    }
    path = path.removingPercentEncoding ?? path
    guard let url = localPathResolver?.resolve(path)?.url,
      let values = try? url.resourceValues(forKeys: [.contentTypeKey, .isRegularFileKey]),
      values.isRegularFile == true,
      let type = values.contentType, type.conforms(to: .movie)
    else { return nil }
    return url
  }

  func htmlURL(for name: String, isExplicitHTML: Bool) -> URL? {
    var path = name.trimmingCharacters(in: .whitespacesAndNewlines)
    if path.first == "<", path.last == ">", path.count >= 2 {
      path = String(path.dropFirst().dropLast())
    }
    if let url = URL(string: path), let scheme = url.scheme, !url.isFileURL {
      guard ["http", "https"].contains(scheme.lowercased()),
        let host = url.host, !host.isEmpty,
        isExplicitHTML || ["html", "htm"].contains(url.pathExtension.lowercased())
      else { return nil }
      return url
    }
    path = path.removingPercentEncoding ?? path
    guard let url = localPathResolver?.resolve(path)?.url,
      let values = try? url.resourceValues(forKeys: [.contentTypeKey, .isRegularFileKey]),
      values.isRegularFile == true,
      let type = values.contentType, type.conforms(to: .html)
    else { return nil }
    return url
  }

  private func remoteURL(for path: String) -> URL? {
    guard let url = URL(string: path), url.scheme?.lowercased() == "https", url.host != nil else {
      return nil
    }
    return url
  }

  private func image(forRemoteURL url: URL) -> UIImage? {
    let request = ImageRequest(url: url)
    if let image = ImagePipeline.shared.cache.cachedImage(for: request, caches: [.memory])?.image {
      return image
    }
    let urlRequest = URLRequest(url: url)
    if let cachedResponse = DataLoader.sharedUrlCache.cachedResponse(for: urlRequest),
      let image = UIImage(data: cachedResponse.data)
    {
      ImagePipeline.shared.cache[request] = ImageContainer(image: image)
      return image
    }
    guard Self.remoteImageDownloadTracker.beginLoading(url) else { return nil }
    ImagePipeline.shared.loadImage(with: request) { result in
      Self.remoteImageDownloadTracker.finishLoading(url)
      guard case .success = result else { return }
      NotificationCenter.default.post(
        name: .projectHistoryRemoteImageDidLoad, object: nil, userInfo: ["url": url])
    }
    return nil
  }
}

struct ProjectDirectoryLinkResolver: MarkdownLinkResolver {
  var localPathResolver: LocalPathResolver?

  func url(for destination: String) -> URL? {
    if let url = URL(string: destination), url.scheme != nil {
      guard url.isFileURL else { return ExternalURLPolicy.allows(url) ? url : nil }
      return localPathResolver?.resolve(url.path.removingPercentEncoding ?? url.path)?.url
    }
    let path = destination.removingPercentEncoding ?? destination
    return localPathResolver?.resolve(path)?.url
  }

  // Only links the app opens are tappable, so text like itms-services://… stays plain.
  func url(forDetected url: URL) -> URL? {
    ExternalURLPolicy.allows(url) ? url : nil
  }
}

enum ProjectHistoryMarkdownConfiguration {
  // In-progress text sits below the finished text's label color; markers one step below that. Kept
  // in one instance because the text view restyles when the theme's color identities change.
  private static let transientTheme = MarkdownEditorTheme(
    bodyText: .tertiaryText,
    mutedText: .senaryText,
    disabledText: .senaryText,
    headingMarker: .senaryText,
    latexLightModeText: .tertiaryText,
    latexDarkModeText: .tertiaryText,
    strikethroughColor: .tertiaryText
  )

  static func make(
    localPathResolver: LocalPathResolver?, isTransient: Bool = false,
    allowsEmbeddedMedia: Bool = true
  ) -> MarkdownEditorConfiguration {
    let syntaxHighlighter: any SyntaxHighlighter
    if isTransient {
      syntaxHighlighter = MarkdownSyntaxHighlighter.transient
    } else {
      syntaxHighlighter = MarkdownSyntaxHighlighter.shared
    }
    return MarkdownEditorConfiguration(
      theme: isTransient ? transientTheme : .default,
      services: MarkdownEditorServices(
        links: ProjectDirectoryLinkResolver(localPathResolver: localPathResolver),
        images: ProjectDirectoryImageProvider(localPathResolver: localPathResolver),
        videos: allowsEmbeddedMedia
          ? ProjectDirectoryImageProvider(localPathResolver: localPathResolver)
          : NoOpEmbeddedVideoProvider(),
        html: allowsEmbeddedMedia
          ? ProjectDirectoryImageProvider(localPathResolver: localPathResolver)
          : NoOpEmbeddedHTMLProvider(),
        syntaxHighlighter: syntaxHighlighter,
        latex: SwiftMathBridge()
      ),
      link: LinkStyle(automaticLinkDetectionEnabled: !isTransient),
      textInsets: TextInsets(horizontal: 0, vertical: 0),
      extensions: [StrikethroughExtension()]
    )
  }
}

extension Notification.Name {
  static let projectHistoryRemoteImageDidLoad = Notification.Name(
    "ProjectHistoryRemoteImageDidLoad")
}
