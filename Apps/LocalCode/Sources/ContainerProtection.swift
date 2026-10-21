import Foundation

/// Files in the app container are protected until the first unlock after a restart, so agents
/// keep working while the device is locked. Lockdown Mode makes them Complete instead, so they
/// cannot be opened until the device is unlocked. Containers created with a Complete default
/// are converted the same way. Everything inside the container is the app's to convert; files
/// outside it keep the protection the user chose.
enum ContainerProtection {
  /// Converts the directories and files under `root` to `protection`. It skips symbolic links,
  /// which can lead outside `root`, and SQLite shared memory, which SQLite maps, so a Complete
  /// one would crash the app when the device locks. `root` is converted last, so its protection
  /// tells whether a conversion finished; one that fails, for example because the device locked,
  /// is left for the next attempt. Returns whether `root` is converted.
  static func setProtection(_ protection: URLFileProtection, in root: URL) -> Bool {
    // Only items with the other protection convert, so files that asked for no protection keep
    // it where the platform has that class (Macs store it as the default).
    let source: URLFileProtection =
      protection == .complete ? .completeUntilFirstUserAuthentication : .complete
    // Only a root with the other protection has anything to convert.
    guard (try? root.resourceValues(forKeys: [.fileProtectionKey]))?.fileProtection == source
    else { return true }
    let keys: [URLResourceKey] = [
      .fileProtectionKey, .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
    ]
    // Unreadable directories are skipped rather than retried forever.
    guard
      let enumerator = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: keys, errorHandler: { _, _ in true })
    else { return false }
    var succeeded = true
    for case let url as URL in enumerator {
      guard let values = try? url.resourceValues(forKeys: Set(keys)),
        values.isSymbolicLink != true,
        values.isDirectory == true || values.isRegularFile == true,
        values.fileProtection == source, !url.lastPathComponent.hasSuffix("-shm")
      else { continue }
      if !setProtection(protection, of: url) {
        succeeded = false
      }
    }
    return succeeded && setProtection(protection, of: root)
  }

  /// A file deleted meanwhile counts as converted.
  private static func setProtection(_ protection: URLFileProtection, of url: URL) -> Bool {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return errno == ENOENT }
    let mode = info.st_mode
    // Changing protection needs write access, which read-only items such as Git objects lack.
    let isReadOnly = mode & S_IWUSR == 0
    if isReadOnly {
      chmod(url.path, mode | S_IWUSR)
    }
    defer {
      if isReadOnly {
        chmod(url.path, mode)
      }
    }
    do {
      try (url as NSURL).setResourceValue(protection, forKey: .fileProtectionKey)
      return true
    } catch {
      return lstat(url.path, &info) != 0 && errno == ENOENT
    }
  }
}
