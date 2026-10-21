import Foundation

// App bundles carry these resources directly. Bazel command-line tools also run
// from the source tree or a runfiles tree, where the same payloads are separate.
enum Resources {
  static let repositoryURL: URL? = {
    #if os(macOS)
      var candidates = [URL]()
      if let workspace = ProcessInfo.processInfo.environment["BUILD_WORKSPACE_DIRECTORY"] {
        candidates.append(URL(fileURLWithPath: workspace, isDirectory: true))
      }
      candidates.append(
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
      let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
      var runfiles = [executable.appendingPathExtension("runfiles")]
      for name in ["RUNFILES_DIR", "TEST_SRCDIR"] {
        if let path = ProcessInfo.processInfo.environment[name] {
          runfiles.append(URL(fileURLWithPath: path, isDirectory: true))
        }
      }
      for root in runfiles {
        for name in ["_main", "__main__"] { candidates.append(root.appendingPathComponent(name)) }
      }
      var directory = executable.resolvingSymlinksInPath().deletingLastPathComponent()
      while directory.path != "/" {
        candidates.append(directory)
        directory.deleteLastPathComponent()
      }
      for candidate in candidates {
        let marker = candidate.appendingPathComponent("Apps/LocalCode/Resources/Skills/README.txt")
        guard FileManager.default.fileExists(atPath: marker.path) else { continue }
        // Runfiles symlink individual files. Resolve a real file before choosing
        // the root, so SkillCatalog's containment checks see the same namespace.
        var root = marker.resolvingSymlinksInPath()
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return root
      }
    #endif
    return nil
  }()

  static var resourceURL: URL? {
    if let url = Bundle.main.resourceURL,
      FileManager.default.fileExists(atPath: url.appendingPathComponent("Skills").path)
    {
      return url
    }
    return repositoryURL?.appendingPathComponent("Apps/LocalCode/Resources", isDirectory: true)
  }

  static var appBundleURL: URL {
    resourceURL ?? Bundle.main.resourceURL ?? Bundle.main.bundleURL
  }

  static var nodeCommandArchiveURL: URL? {
    repositoryURL?.appendingPathComponent(
      "Vendors/NodeJS/Resources/NodeMobile/Commands/npm-11.19.0.zip")
  }
}
