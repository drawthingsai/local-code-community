import Foundation
import ios_system

#if canImport(Darwin)
  import Darwin
#endif

#if canImport(UIKit)
  import UIKit
#endif

extension EnvironmentContext {
  init(model: String, provider: String, pythonLibraryURL: URL?) {
    let python = Self.pythonDetails(libraryURL: pythonLibraryURL)
    self.init(
      model: model, provider: provider, platform: Self.platformDescription(),
      python: python.version, pythonPackages: python.packages,
      // Keep these synchronized with Vendors/NodeJS/NODEJS_BUILD_INFO and the bundled npm archive.
      nodeJS: "24.20.0", nodeJSPackages: ["npm 11.19.0"],
      shellCommands: (commandsAsArray() as? [String]) ?? [])
  }

  private static func pythonDetails(libraryURL: URL?) -> (version: String, packages: [String]) {
    guard let libraryURL else { return ("(unavailable)", []) }
    let fileManager = FileManager.default
    guard
      let pythonDirectoryURL = try? fileManager.contentsOfDirectory(
        at: libraryURL.appendingPathComponent("lib", isDirectory: true),
        includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
      ).first(where: { $0.lastPathComponent.hasPrefix("python") })
    else { return ("(unavailable)", []) }

    let version: String
    let buildDetailsURL = pythonDirectoryURL.appendingPathComponent("build-details.json")
    if let data = try? Data(contentsOf: buildDetailsURL),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let language = object["language"] as? [String: Any],
      let versionInfo = language["version_info"] as? [String: Any],
      let major = versionInfo["major"] as? Int,
      let minor = versionInfo["minor"] as? Int,
      let micro = versionInfo["micro"] as? Int
    {
      version = "\(major).\(minor).\(micro)"
    } else {
      version = String(pythonDirectoryURL.lastPathComponent.dropFirst("python".count))
    }

    let sitePackagesURL = pythonDirectoryURL.appendingPathComponent(
      "site-packages", isDirectory: true)
    let metadataURLs =
      (try? fileManager.contentsOfDirectory(
        at: sitePackagesURL, includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      ))?.filter { $0.lastPathComponent.hasSuffix(".dist-info") }.map {
        $0.appendingPathComponent("METADATA")
      } ?? []
    let packages = metadataURLs.compactMap { url -> String? in
      guard let metadata = try? String(contentsOf: url, encoding: .utf8) else { return nil }
      var name: String?
      var version: String?
      for line in metadata.split(separator: "\n", omittingEmptySubsequences: false) {
        if line.hasPrefix("Name: ") {
          name = String(line.dropFirst("Name: ".count))
        } else if line.hasPrefix("Version: ") {
          version = String(line.dropFirst("Version: ".count))
        }
        if name != nil && version != nil { break }
      }
      guard let name, let version else { return nil }
      return "\(name) \(version)"
    }
    return (version, packages)
  }

  private static func platformDescription() -> String {
    let platform: String
    #if os(macOS) || (os(iOS) && targetEnvironment(macCatalyst))
      let version = ProcessInfo.processInfo.operatingSystemVersion
      var components = [version.majorVersion, version.minorVersion]
      if version.patchVersion != 0 {
        components.append(version.patchVersion)
      }
      platform = "macOS \(components.map(String.init).joined(separator: "."))"
    #elseif canImport(UIKit)
      let device = UIDevice.current
      let systemName = device.userInterfaceIdiom == .pad ? "iPadOS" : device.systemName
      platform = "\(systemName) \(device.systemVersion)"
    #else
      platform = ProcessInfo.processInfo.operatingSystemVersionString
    #endif
    let name = machineDisplayName()
    return name.isEmpty ? platform : "\(platform) (\(name))"
  }

  private static func machineDisplayName() -> String {
    #if os(macOS) || (os(iOS) && targetEnvironment(macCatalyst))
      if let handle = dlopen(
        "/System/Library/Frameworks/SystemConfiguration.framework/SystemConfiguration", RTLD_LAZY)
      {
        defer { dlclose(handle) }
        if let symbol = dlsym(handle, "SCDynamicStoreCopyComputerName") {
          let copyComputerName = unsafeBitCast(
            symbol,
            to: (@convention(c) (OpaquePointer?, UnsafeMutablePointer<Unmanaged<CFString>?>?) ->
              Unmanaged<CFString>?).self)
          return copyComputerName(nil, nil)?.takeRetainedValue() as String? ?? ""
        }
      }
      return "Unknown Mac"
    #elseif canImport(UIKit)
      return UIDevice.current.name
    #else
      return ""
    #endif
  }
}
