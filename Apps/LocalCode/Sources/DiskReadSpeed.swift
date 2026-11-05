import Foundation
import QuartzCore

/// How fast a folder's drive reads, for the model folder's warning.
enum DiskReadSpeed {
  /// In bytes a second, or nil when the folder can't be written to or read from. It writes a file
  /// of `byteCount` bytes there, reads it back, and removes it, blocking until it's done.
  static func measure(in directory: URL, byteCount: Int = 256 * 1_024 * 1_024) -> Double? {
    // Page aligned, so F_NOCACHE reads and writes go straight to the drive.
    let chunkSize = 8 * 1_024 * 1_024
    let buffer = UnsafeMutableRawPointer.allocate(
      byteCount: chunkSize, alignment: Int(getpagesize()))
    defer { buffer.deallocate() }
    // Random, so a drive or file system that compresses can't make it look faster.
    arc4random_buf(buffer, chunkSize)
    let filePath = directory.appendingPathComponent(".read_speed_\(UUID().uuidString)").path
    let writeDescriptor = open(filePath, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    guard writeDescriptor >= 0 else { return nil }
    defer { unlink(filePath) }
    // Past the cache, so the read back comes from the drive rather than memory.
    _ = fcntl(writeDescriptor, F_NOCACHE, 1)
    var writtenCount = 0
    while writtenCount < byteCount {
      let count = write(writeDescriptor, buffer, min(chunkSize, byteCount - writtenCount))
      guard count > 0 else { break }
      writtenCount += count
    }
    // Out of the drive's own cache as well.
    _ = fcntl(writeDescriptor, F_FULLFSYNC)
    close(writeDescriptor)
    guard writtenCount == byteCount else { return nil }
    let readDescriptor = open(filePath, O_RDONLY)
    guard readDescriptor >= 0 else { return nil }
    defer { close(readDescriptor) }
    _ = fcntl(readDescriptor, F_NOCACHE, 1)
    let startTime = CACurrentMediaTime()
    var readCount = 0
    while readCount < byteCount {
      let count = read(readDescriptor, buffer, min(chunkSize, byteCount - readCount))
      guard count > 0 else { return nil }
      readCount += count
    }
    let elapsedTime = CACurrentMediaTime() - startTime
    return elapsedTime > 0 ? Double(byteCount) / elapsedTime : nil
  }
}
