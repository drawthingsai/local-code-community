import CryptoKit
import Foundation

/// Media files shared by the project's history and suspended generations.
public struct EmbedsFileStore {
  private let directory: URL

  public init(projectPath: String) {
    directory = URL(fileURLWithPath: projectPath, isDirectory: true)
      .appendingPathComponent(".localc/cas", isDirectory: true)
  }

  public func filePath(for digest: Data) -> String {
    precondition(digest.count == 32)
    return directory.appendingPathComponent(digest.map { String(format: "%02x", $0) }.joined()).path
  }

  /// Store newly rendered media without a source file.
  public func insert(data: Data) throws -> Data {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let digest = Data(SHA256.hash(data: data))
    let destination = URL(fileURLWithPath: filePath(for: digest))
    if !FileManager.default.fileExists(atPath: destination.path) {
      try data.write(to: destination, options: .atomic)
    }
    return digest
  }

  /// Copy the encoded source file before hashing it; never decode or re-encode the image.
  public func insert(filePath: String) throws -> Data {
    let manager = FileManager.default
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    let source = URL(fileURLWithPath: filePath).resolvingSymlinksInPath()
    let temporary = directory.appendingPathComponent(UUID().uuidString)
    defer { try? manager.removeItem(at: temporary) }
    do {
      // A hard link shares the source's inode, so an in-place write to the source would change the
      // CAS entry without changing its digest. Copy instead (a clone on APFS). The copy inherits
      // the source's locked flag, which would keep it from moving into place.
      try manager.copyItem(at: source, to: temporary)
      try manager.setAttributes([.immutable: false], ofItemAtPath: temporary.path)
    } catch {
      // Only hard link when the bytes cannot be copied, such as on a full volume. Clear any
      // partial copy first.
      try? manager.removeItem(at: temporary)
      try manager.linkItem(at: source, to: temporary)
    }
    let file = try FileHandle(forReadingFrom: temporary)
    defer { try? file.close() }
    var hash = SHA256()
    while let bytes = try file.read(upToCount: 1 << 20), !bytes.isEmpty {
      hash.update(data: bytes)
    }
    let digest = Data(hash.finalize())
    let destination = URL(fileURLWithPath: self.filePath(for: digest))
    do {
      try manager.moveItem(at: temporary, to: destination)
    } catch CocoaError.fileWriteFileExists {
      // Another reference to this same content already owns the CAS entry.
    }
    return digest
  }
}
