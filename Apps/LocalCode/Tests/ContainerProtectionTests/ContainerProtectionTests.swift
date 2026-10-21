import Foundation
import XCTest

final class ContainerProtectionTests: XCTestCase {
  private var base: URL!
  private var root: URL!
  private var outside: URL!

  override func setUpWithError() throws {
    base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    root = base.appendingPathComponent("Container", isDirectory: true)
    outside = base.appendingPathComponent("Outside", isDirectory: true)
    for url in [root!, outside!] {
      try FileManager.default.createDirectory(
        at: url, withIntermediateDirectories: true,
        attributes: [.protectionKey: FileProtectionType.complete])
    }
    try XCTSkipUnless(protectionClass(root) == 1, "Data protection is unavailable here.")
  }

  override func tearDownWithError() throws {
    guard let base, let enumerator = FileManager.default.enumerator(atPath: base.path) else {
      return
    }
    // Read-only directories cannot be emptied.
    while let path = enumerator.nextObject() as? String {
      chmod(base.appendingPathComponent(path).path, 0o755)
    }
    try FileManager.default.removeItem(at: base)
  }

  private func protectionClass(_ url: URL) -> Int32 {
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
    guard descriptor >= 0 else { return -1 }
    defer { close(descriptor) }
    return fcntl(descriptor, F_GETPROTECTIONCLASS)
  }

  private func mode(_ url: URL) -> mode_t {
    var info = stat()
    lstat(url.path, &info)
    return info.st_mode & 0o777
  }

  private func write(_ name: String, in directory: URL) throws -> URL {
    let url = directory.appendingPathComponent(name)
    try Data([1]).write(to: url)
    return url
  }

  func testLoweringConvertsCompleteItemsOnce() throws {
    let project = root.appendingPathComponent("Documents/Workspace/Project", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let file = try write("poster.png", in: project)
    XCTAssertTrue(
      ContainerProtection.setProtection(.completeUntilFirstUserAuthentication, in: root))
    for url in [root!, project, file] {
      XCTAssertEqual(protectionClass(url), 3, url.path)
    }
    // New files inherit the converted directory's protection.
    XCTAssertEqual(protectionClass(try write("new.txt", in: project)), 3)
    // A converted root has nothing left to convert.
    let late = try write("late", in: outside)
    try FileManager.default.moveItem(at: late, to: project.appendingPathComponent("late"))
    XCTAssertTrue(
      ContainerProtection.setProtection(.completeUntilFirstUserAuthentication, in: root))
    XCTAssertEqual(protectionClass(project.appendingPathComponent("late")), 1)
  }

  func testReadOnlyItemsConvertAndKeepTheirMode() throws {
    let object = try write("object", in: root)
    chmod(object.path, 0o444)
    let directory = root.appendingPathComponent("ReadOnly", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let inner = try write("inner", in: directory)
    chmod(directory.path, 0o555)
    XCTAssertTrue(
      ContainerProtection.setProtection(.completeUntilFirstUserAuthentication, in: root))
    XCTAssertEqual(protectionClass(object), 3)
    XCTAssertEqual(mode(object), 0o444)
    XCTAssertEqual(protectionClass(directory), 3)
    XCTAssertEqual(mode(directory), 0o555)
    XCTAssertEqual(protectionClass(inner), 3)
  }

  func testSymbolicLinksKeepOutsideProtection() throws {
    let target = try write("target", in: outside)
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("Desktop"), withDestinationURL: outside)
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("linked"), withDestinationURL: target)
    // A workspace the user chose inside the container is still the app's to convert.
    let workspace = root.appendingPathComponent("Documents/Chosen", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    let mine = try write("mine", in: workspace)
    XCTAssertTrue(
      ContainerProtection.setProtection(.completeUntilFirstUserAuthentication, in: root))
    XCTAssertEqual(protectionClass(outside), 1)
    XCTAssertEqual(protectionClass(target), 1)
    XCTAssertEqual(protectionClass(workspace), 3)
    XCTAssertEqual(protectionClass(mine), 3)
    XCTAssertEqual(protectionClass(root), 3)
  }

  func testRaisingLeavesSQLiteSharedMemory() throws {
    XCTAssertTrue(
      ContainerProtection.setProtection(.completeUntilFirstUserAuthentication, in: root))
    let database = try write("metadata.sqlite3", in: root)
    let sharedMemory = try write("metadata.sqlite3-shm", in: root)
    XCTAssertTrue(ContainerProtection.setProtection(.complete, in: root))
    XCTAssertEqual(protectionClass(root), 1)
    XCTAssertEqual(protectionClass(database), 1)
    XCTAssertEqual(protectionClass(sharedMemory), 3)
  }
}
