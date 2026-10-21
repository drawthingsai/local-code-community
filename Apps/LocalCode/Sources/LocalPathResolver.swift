import Foundation

struct LocalPathResolver: Equatable, Sendable {
  enum Namespace: Equatable, Sendable {
    case project
    case home
    case tilde
    case temporary
    case appBundle
    case permitted
  }

  struct Resolution: Equatable, Sendable {
    let url: URL
    let rootURL: URL
    let namespace: Namespace

    fileprivate init(url: URL, rootURL: URL, namespace: Namespace) {
      self.url = url
      self.rootURL = rootURL
      self.namespace = namespace
    }

    func reference(for relativePath: String) -> String {
      var relativePath = relativePath
      while relativePath.hasPrefix("./") {
        relativePath.removeFirst(2)
      }
      while relativePath.hasPrefix("/") {
        relativePath.removeFirst()
      }
      switch namespace {
      case .project:
        return relativePath.isEmpty ? "." : relativePath
      case .home:
        return relativePath.isEmpty ? "/home" : "/home/\(relativePath)"
      case .tilde:
        return relativePath.isEmpty ? "~" : "~/\(relativePath)"
      case .temporary:
        return relativePath.isEmpty ? "/tmp" : "/tmp/\(relativePath)"
      case .appBundle:
        return relativePath.isEmpty ? "/app_bundle" : "/app_bundle/\(relativePath)"
      case .permitted:
        return relativePath.isEmpty
          ? rootURL.path : rootURL.appendingPathComponent(relativePath).path
      }
    }
  }

  let projectURL: URL
  let workspaceURL: URL
  let temporaryURL: URL
  let appBundleURL: URL
  let permittedDirectoryURLs: [URL]

  init(projectPath: String?, workspacePath: String?, permittedDirectoryURLs: [URL] = []) {
    let projectPath =
      projectPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let cachesURL =
      FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).last
      ?? URL(fileURLWithPath: "", isDirectory: true)
    let trimmedWorkspacePath = workspacePath?.trimmingCharacters(in: .whitespacesAndNewlines)
    let workspacePath: String
    if let trimmedWorkspacePath, !trimmedWorkspacePath.isEmpty {
      workspacePath = trimmedWorkspacePath
    } else {
      workspacePath = projectPath
    }
    self.init(
      projectURL: URL(fileURLWithPath: projectPath, isDirectory: true),
      workspaceURL: URL(fileURLWithPath: workspacePath, isDirectory: true),
      temporaryURL: cachesURL.appendingPathComponent("tmp", isDirectory: true),
      appBundleURL: Resources.appBundleURL, permittedDirectoryURLs: permittedDirectoryURLs)
  }

  init(
    projectURL: URL, workspaceURL: URL, temporaryURL: URL,
    appBundleURL: URL = Resources.appBundleURL, permittedDirectoryURLs: [URL] = []
  ) {
    self.projectURL = Self.canonicalURL(projectURL) ?? projectURL.standardizedFileURL
    self.workspaceURL = Self.canonicalURL(workspaceURL) ?? workspaceURL.standardizedFileURL
    self.temporaryURL = Self.canonicalURL(temporaryURL) ?? temporaryURL.standardizedFileURL
    self.appBundleURL = Self.canonicalURL(appBundleURL) ?? appBundleURL.standardizedFileURL
    self.permittedDirectoryURLs = permittedDirectoryURLs.compactMap(Self.canonicalURL)
  }

  func resolve(_ path: String) -> Resolution? {
    let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.isEmpty, !path.contains("\0") else { return nil }

    if let fileURL = URL(string: path), fileURL.isFileURL {
      return resolve(fileURL.path)
    }
    if path.lowercased().hasPrefix("file://") {
      let pathStart = path.index(path.startIndex, offsetBy: "file://".count)
      let filePath = String(path[pathStart...])
      return resolve(filePath.removingPercentEncoding ?? filePath)
    }
    if path == "/home" || path.hasPrefix("/home/") {
      let relativePath = String(path.dropFirst("/home".count)).dropLeadingSlashes()
      return resolve(relativePath, from: workspaceURL, namespace: .home)
    }
    if path == "/tmp" || path.hasPrefix("/tmp/") {
      let relativePath = String(path.dropFirst("/tmp".count)).dropLeadingSlashes()
      return resolve(relativePath, from: temporaryURL, namespace: .temporary)
    }
    if path == "/app_bundle" || path.hasPrefix("/app_bundle/") {
      let relativePath = String(path.dropFirst("/app_bundle".count)).dropLeadingSlashes()
      return resolve(relativePath, from: appBundleURL, namespace: .appBundle)
    }
    if path == "~" || path.hasPrefix("~/") {
      let relativePath = String(path.dropFirst()).dropLeadingSlashes()
      return resolve(relativePath, from: workspaceURL, namespace: .tilde)
    }
    if path.hasPrefix("/") {
      guard let absoluteURL = Self.canonicalURL(URL(fileURLWithPath: path)) else { return nil }
      return resolution(forAbsoluteURL: absoluteURL)
    }
    return resolve(path.dropLeadingSlashes(), from: projectURL, namespace: .project)
  }

  var fingerprint: AnyHashable {
    "\(projectURL.path)\0\(workspaceURL.path)\0\(temporaryURL.path)\0\(appBundleURL.path)\0"
      + permittedDirectoryURLs.map(\.path).sorted().joined(separator: "\0")
  }

  private func resolve(
    _ relativePath: String, from rootURL: URL, namespace: Namespace
  ) -> Resolution? {
    let candidateURL =
      relativePath.isEmpty ? rootURL : rootURL.appendingPathComponent(relativePath)
    guard let resolvedURL = Self.canonicalURL(candidateURL), Self.contains(resolvedURL, in: rootURL)
    else { return nil }
    return Resolution(url: resolvedURL, rootURL: rootURL, namespace: namespace)
  }

  private func resolution(forAbsoluteURL url: URL) -> Resolution? {
    if Self.contains(url, in: projectURL) {
      return Resolution(url: url, rootURL: projectURL, namespace: .project)
    }
    if Self.contains(url, in: workspaceURL) {
      return Resolution(url: url, rootURL: workspaceURL, namespace: .home)
    }
    if Self.contains(url, in: temporaryURL) {
      return Resolution(url: url, rootURL: temporaryURL, namespace: .temporary)
    }
    if Self.contains(url, in: appBundleURL) {
      return Resolution(url: url, rootURL: appBundleURL, namespace: .appBundle)
    }
    if let root = permittedDirectoryURLs.first(where: { Self.contains(url, in: $0) }) {
      return Resolution(url: url, rootURL: root, namespace: .permitted)
    }
    return nil
  }

  private static func canonicalURL(_ url: URL) -> URL? {
    // Foundation can leave every symlink unresolved when the final file does not exist.
    // Resolve the existing ancestor first, then append the components a write may create.
    var ancestor = url.standardizedFileURL
    var missing = [String]()
    while ancestor.path != "/", !FileManager.default.fileExists(atPath: ancestor.path) {
      // A dangling or inaccessible symlink is not a new path component we can safely append.
      if (try? FileManager.default.destinationOfSymbolicLink(atPath: ancestor.path)) != nil {
        return nil
      }
      missing.append(ancestor.lastPathComponent)
      ancestor.deleteLastPathComponent()
    }
    var resolved = ancestor.resolvingSymlinksInPath()
    for component in missing.reversed() { resolved.appendPathComponent(component) }
    return resolved
  }

  private static func contains(_ url: URL, in rootURL: URL) -> Bool {
    let path = url.path
    let rootPath = rootURL.path
    return path == rootPath || path.hasPrefix(rootPath == "/" ? rootPath : rootPath + "/")
  }
}

extension String {
  fileprivate func dropLeadingSlashes() -> String {
    var value = self
    while value.hasPrefix("/") {
      value.removeFirst()
    }
    return value
  }
}
