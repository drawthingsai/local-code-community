import CryptoKit
import Foundation
import ZIPFoundation

enum NodeMobileCommandResources {
  struct CommandPaths {
    let npm: URL
    let npx: URL
  }

  enum Error: LocalizedError {
    case archiveMissing
    case archiveChecksum(String)
    case invalidInstallation

    var errorDescription: String? {
      switch self {
      case .archiveMissing:
        return "The signed npm command archive is missing."
      case .archiveChecksum(let checksum):
        return "The npm command archive checksum is invalid: \(checksum)."
      case .invalidInstallation:
        return "The extracted npm command payload is invalid."
      }
    }
  }

  private static let npmVersion = "11.19.1"
  private static let archiveSHA256 =
    "23a3c442e6e165888dc455a0fea799579b19c1b80a8eb071afdc82438efaa18a"

  static func prepare(
    in libraryURL: URL, bundle: Bundle = .main, archiveURL: URL? = nil,
    fileManager: FileManager = .default
  ) throws -> CommandPaths {
    guard
      let archiveURL = archiveURL
        ?? bundle.url(
          forResource: "npm-\(npmVersion)", withExtension: "zip",
          subdirectory: "NodeMobile/Commands")
    else {
      throw Error.archiveMissing
    }
    let archiveData = try Data(contentsOf: archiveURL, options: .mappedIfSafe)
    let archiveChecksum = SHA256.hash(data: archiveData)
      .map { String(format: "%02x", $0) }
      .joined()
    guard archiveChecksum == archiveSHA256 else {
      throw Error.archiveChecksum(archiveChecksum)
    }

    let commandsDirectory =
      libraryURL
      .appendingPathComponent("NodeMobile", isDirectory: true)
      .appendingPathComponent("Commands", isDirectory: true)
    let installationURL =
      commandsDirectory
      .appendingPathComponent("npm-\(npmVersion)", isDirectory: true)
    if let paths = commandPaths(
      at: installationURL, expectedMarker: archiveSHA256, fileManager: fileManager)
    {
      return paths
    }

    try fileManager.createDirectory(
      at: commandsDirectory, withIntermediateDirectories: true)
    let stagingURL =
      commandsDirectory
      .appendingPathComponent("npm-\(npmVersion).staging-\(UUID().uuidString)", isDirectory: true)
    let backupURL =
      commandsDirectory
      .appendingPathComponent("npm-\(npmVersion).backup-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
    defer {
      try? fileManager.removeItem(at: stagingURL)
      try? fileManager.removeItem(at: backupURL)
    }

    try fileManager.unzipItem(at: archiveURL, to: stagingURL)
    try Data(archiveSHA256.utf8).write(
      to: stagingURL.appendingPathComponent(".localcode-resource-sha256"),
      options: .atomic)
    guard
      commandPaths(at: stagingURL, expectedMarker: archiveSHA256, fileManager: fileManager)
        != nil
    else {
      throw Error.invalidInstallation
    }

    var backedUpExistingInstallation = false
    if fileManager.fileExists(atPath: installationURL.path) {
      try fileManager.moveItem(at: installationURL, to: backupURL)
      backedUpExistingInstallation = true
    }
    do {
      try fileManager.moveItem(at: stagingURL, to: installationURL)
    } catch {
      if backedUpExistingInstallation {
        try? fileManager.moveItem(at: backupURL, to: installationURL)
      }
      throw error
    }
    guard
      let paths = commandPaths(
        at: installationURL, expectedMarker: archiveSHA256, fileManager: fileManager)
    else {
      throw Error.invalidInstallation
    }
    return paths
  }

  private static func commandPaths(
    at installationURL: URL, expectedMarker: String, fileManager: FileManager
  ) -> CommandPaths? {
    let markerURL = installationURL.appendingPathComponent(".localcode-resource-sha256")
    guard
      let marker = try? String(contentsOf: markerURL, encoding: .utf8),
      marker == expectedMarker,
      let packageData = try? Data(
        contentsOf: installationURL.appendingPathComponent("package.json")),
      let package = try? JSONSerialization.jsonObject(with: packageData) as? [String: Any],
      package["version"] as? String == npmVersion
    else {
      return nil
    }
    let npm = installationURL.appendingPathComponent("bin/npm-cli.js")
    let npx = installationURL.appendingPathComponent("bin/npx-cli.js")
    var npmIsDirectory = ObjCBool(false)
    var npxIsDirectory = ObjCBool(false)
    guard
      fileManager.fileExists(atPath: npm.path, isDirectory: &npmIsDirectory),
      fileManager.fileExists(atPath: npx.path, isDirectory: &npxIsDirectory),
      !npmIsDirectory.boolValue,
      !npxIsDirectory.boolValue
    else {
      return nil
    }
    return CommandPaths(npm: npm, npx: npx)
  }
}
