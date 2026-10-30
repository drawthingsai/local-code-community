import DeviceLink
import Foundation

/// A project on one of the account's Macs, as a phone's drawer lists it. Its rows carry the project
/// path `mac:<device ID>/<project ID>`, which no folder has.
struct MacProject: Hashable {
  private static let prefix = "mac:"

  let deviceID: String
  let projectID: String

  var path: String { Self.prefix + deviceID + "/" + projectID }

  init(deviceID: String, projectID: String) {
    self.deviceID = deviceID
    self.projectID = projectID
  }

  init?(path: String) {
    guard path.hasPrefix(Self.prefix), let slash = path.lastIndex(of: "/") else { return nil }
    deviceID = String(path[path.index(path.startIndex, offsetBy: Self.prefix.count)..<slash])
    projectID = String(path[path.index(after: slash)...])
  }

  func thread(_ threadID: Int64) -> ThreadRef {
    ThreadRef.with {
      $0.projectID = projectID
      $0.threadID = threadID
    }
  }
}
