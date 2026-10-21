import AppleUtilities
import BashToolContext
import Foundation
import ImageIO
import Localization
import PDFKit
import ProjectHistoryManager

public struct ViewTool {
  public var path: String
  public var offset: Int
  public var pages: Int
  public var projectPath: String?
  public var workspacePath: String?

  public static func parse(
    _ request: ToolCall.Request, projectPath: String?, workspacePath: String?
  ) -> ViewTool? {
    guard
      let path = request.parameters["path"]?.value.trimmingCharacters(in: .whitespacesAndNewlines),
      !path.isEmpty
    else { return nil }
    let offset: Int
    if let parameter = request.parameters["offset"] {
      guard let value = Int(parameter.value), value > 0 else { return nil }
      offset = value
    } else {
      offset = 1
    }
    let pages: Int
    if let parameter = request.parameters["pages"] {
      guard let value = Int(parameter.value), value > 0 else { return nil }
      pages = value
    } else {
      pages = 1
    }
    return ViewTool(
      path: path, offset: offset, pages: pages, projectPath: projectPath,
      workspacePath: workspacePath)
  }

  public func subtitle(for moment: ToolSubtitleMoment) -> String {
    let title: String
    switch moment {
    case .now: title = LocalizedString.forKey("tool_view_now")
    case .past: title = LocalizedString.forKey("tool_view_past")
    }
    // A photos:// path is not a file to link to.
    let target =
      PhotoLibrary.assetID(inPath: path) != nil
      ? "`\(path)`"
      : fileMarkdownLink(for: path, projectPath: projectPath, workspacePath: workspacePath)
    return "**\(title)**: \(target)"
  }

  public func invoke(
    context: BashToolContext = .init(), completion: @escaping (ToolResponse) -> Void
  ) {
    guard let projectPath, !projectPath.isEmpty else {
      completion(ToolResponse(text: "Error: View requires a project to store viewed content."))
      return
    }
    if let assetID = PhotoLibrary.assetID(inPath: path) {
      viewPhoto(
        assetID, store: EmbedsFileStore(projectPath: projectPath), context: context,
        completion: completion)
      return
    }
    let resolver = LocalPathResolver(
      projectPath: projectPath, workspacePath: workspacePath,
      permittedDirectoryURLs: context.permittedDirectoryURLs())
    guard let resolution = resolver.resolve(path) else {
      completion(
        ToolResponse(text: "Error: Cannot view file outside permitted directories: \(path)"))
      return
    }
    do {
      let store = EmbedsFileStore(projectPath: projectPath)
      let digest = try store.insert(filePath: resolution.url.path)
      let url = URL(fileURLWithPath: store.filePath(for: digest))
      if let document = PDFDocument(url: url) {
        viewPDF(
          document, url: resolution.url, store: store, context: context, incorrectPassword: false,
          completion: completion)
        return
      }
      guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
        CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
      else {
        completion(ToolResponse(text: "Error: Invalid or unsupported image or PDF: \(path)"))
        return
      }
      completion(ToolResponse([.text("Image from \(path):"), .imageDigest(digest)]))
    } catch {
      completion(ToolResponse(text: "Error: Could not view \(path): \(error.localizedDescription)"))
    }
  }

  /// Views a photo, or a video's poster frame, from Photos, which asks for Photos access first.
  private func viewPhoto(
    _ assetID: String, store: EmbedsFileStore, context: BashToolContext,
    completion: @escaping (ToolResponse) -> Void
  ) {
    guard let accessPhotos = context.accessPhotos else {
      completion(ToolResponse(text: "Error: Photos are only available in Local Code: \(path)"))
      return
    }
    accessPhotos(true, context.bashUserInteraction) { result in
      // Photos may download the photo from iCloud, so this waits off the host's thread.
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          try result.get()
          // Like PDF pages; the vision encoder applies its own resize afterward.
          let image = try PhotoLibrary.pngData(forAssetID: assetID, maxPixelSize: 2048)
          let digest = try store.insert(data: image.data)
          completion(
            ToolResponse([
              .text("\(image.isVideo ? "Poster frame of video" : "Image") from \(path):"),
              .imageDigest(digest),
            ]))
        } catch {
          completion(
            ToolResponse(text: "Error: Could not view \(path): \(error.localizedDescription)"))
        }
      }
    }
  }

  private func viewPDF(
    _ document: PDFDocument, url: URL, store: EmbedsFileStore, context: BashToolContext,
    incorrectPassword: Bool, completion: @escaping (ToolResponse) -> Void
  ) {
    if document.isLocked {
      guard let requestPassword = context.requestPDFPassword else {
        completion(ToolResponse(text: "Error: PDF requires a password: \(path)"))
        return
      }
      requestPassword(url, incorrectPassword, context.bashUserInteraction) { password in
        guard let password else {
          completion(ToolResponse(text: "Error: PDF password entry was cancelled: \(path)"))
          return
        }
        let unlocked = document.unlock(withPassword: password)
        self.viewPDF(
          document, url: url, store: store, context: context,
          incorrectPassword: !unlocked, completion: completion)
      }
      return
    }
    do {
      guard offset <= document.pageCount else {
        completion(
          ToolResponse(
            text: "Error: Page \(offset) is out of range for \(path) (\(document.pageCount) pages)."
          ))
        return
      }
      var content = [ToolResponse.Content]()
      let start = offset - 1
      let end = start + min(pages, document.pageCount - start)
      for index in start..<end {
        let digest = try autoreleasepool {
          guard let page = document.page(at: index) else { throw ViewError.renderPage(index + 1) }
          let bounds = page.bounds(for: .cropBox)
          var size = bounds.size
          if page.rotation % 180 != 0 { swap(&size.width, &size.height) }
          guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            throw ViewError.renderPage(index + 1)
          }
          // Render at up to 144 dpi, bounded for large page sizes. The vision encoder
          // applies its own model-specific resize afterward.
          let scale = min(2, 2048 / max(size.width, size.height))
          let thumbnail = page.thumbnail(
            of: CGSize(
              width: max(1, ceil(size.width * scale)), height: max(1, ceil(size.height * scale))),
            for: .cropBox)
          #if os(macOS)
            let image = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil)
          #else
            let image = thumbnail.cgImage
          #endif
          guard let image else { throw ViewError.renderPage(index + 1) }
          let data = NSMutableData()
          guard
            let destination = CGImageDestinationCreateWithData(
              data, "public.png" as CFString, 1, nil)
          else { throw ViewError.renderPage(index + 1) }
          CGImageDestinationAddImage(destination, image, nil)
          guard CGImageDestinationFinalize(destination) else {
            throw ViewError.renderPage(index + 1)
          }
          return try store.insert(data: data as Data)
        }
        content += [.text("Page \(index + 1) from \(path):\n"), .imageDigest(digest)]
      }
      completion(ToolResponse(content))
    } catch {
      completion(ToolResponse(text: "Error: Could not view \(path): \(error.localizedDescription)"))
    }
  }
}

private enum ViewError: LocalizedError {
  case renderPage(Int)

  var errorDescription: String? {
    switch self {
    case .renderPage(let page): return "Could not render PDF page \(page)."
    }
  }
}
