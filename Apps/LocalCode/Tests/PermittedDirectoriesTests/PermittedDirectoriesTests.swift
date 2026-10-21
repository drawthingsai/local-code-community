import Foundation
import SQLiteDflat
import XCTest

final class PermittedDirectoriesTests: XCTestCase {
  private var workspace: SQLiteWorkspace!
  private var root: URL!
  private var folder: URL!
  private var sibling: URL!
  private var bookmarks: [String: Data]!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    folder = root.appendingPathComponent("Folder", isDirectory: true)
    sibling = root.appendingPathComponent("FolderSibling", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
    folder = folder.standardizedFileURL.resolvingSymlinksInPath()
    sibling = sibling.standardizedFileURL.resolvingSymlinksInPath()
    workspace = SQLiteWorkspace(
      filePath: root.appendingPathComponent("config.sqlite3").path,
      fileProtectionLevel: .noProtection)
    // Unresolvable bookmarks also need to remain manageable. The test process has no picker grants.
    bookmarks = [folder.path: Data([1]), sibling.path: Data([2])]
    workspace.dictionary["permitted_directories", [String: Data].self] = bookmarks
  }

  override func tearDownWithError() throws {
    workspace.shutdown(flags: .truncate)
    workspace = nil
    try FileManager.default.removeItem(at: root)
  }

  private func onMain(_ body: () throws -> Void) rethrows {
    if Thread.isMainThread {
      try body()
    } else {
      try DispatchQueue.main.sync(execute: body)
    }
  }

  func testGlobalTogglePreservesBookmarksAndFolderChoices() throws {
    try onMain {
      let directories = PermittedDirectories(workspace: workspace)
      XCTAssertTrue(directories.isEnabled)
      try directories.validateRequest(folder)
      directories.setEnabled(false, for: folder.path)
      directories.setEnabled(false)
      XCTAssertFalse(directories.isEnabled)
      XCTAssertTrue(directories.urls.isEmpty)
      XCTAssertThrowsError(try directories.validateRequest(sibling)) {
        XCTAssertEqual($0 as? DirectoryPermissionError, .featureDisabled)
      }
      XCTAssertThrowsError(try directories.add(sibling)) {
        XCTAssertEqual($0 as? DirectoryPermissionError, .featureDisabled)
      }
      directories.setEnabled(true)
      XCTAssertTrue(directories.isEnabled)
      XCTAssertEqual(workspace.dictionary["permitted_directories", [String: Data].self], bookmarks)
      XCTAssertEqual(
        workspace.dictionary["disabled_permitted_directories", Set<String>.self], [folder.path])
      XCTAssertThrowsError(try directories.validateRequest(folder)) {
        XCTAssertEqual($0 as? DirectoryPermissionError, .folderDisabled)
      }
      try directories.validateRequest(sibling)
      directories.setEnabled(true, for: folder.path)
      try directories.validateRequest(folder)
      XCTAssertEqual(workspace.dictionary["permitted_directories", [String: Data].self], bookmarks)
    }
  }

  func testDisabledFolderRejectsDescendantsAndCannotBeAddedAgain() throws {
    let child = folder.appendingPathComponent("Child", isDirectory: true)
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    try onMain {
      let directories = PermittedDirectories(workspace: workspace)
      directories.setEnabled(false, for: folder.path)
      for url in [folder!, child] {
        XCTAssertThrowsError(try directories.validateRequest(url)) {
          XCTAssertEqual($0 as? DirectoryPermissionError, .folderDisabled)
          XCTAssertTrue($0.localizedDescription.contains("explicitly disabled"))
        }
        XCTAssertThrowsError(try directories.add(url)) {
          XCTAssertEqual($0 as? DirectoryPermissionError, .folderDisabled)
        }
      }
      try directories.validateRequest(sibling)
    }
  }

  func testRemovingDisabledFolderForgetsOnlyThatGrant() throws {
    try onMain {
      let directories = PermittedDirectories(workspace: workspace)
      directories.setEnabled(false, for: folder.path)
      directories.revoke(folder.path)
      XCTAssertEqual(
        workspace.dictionary["permitted_directories", [String: Data].self],
        [sibling.path: bookmarks[sibling.path]!])
      XCTAssertEqual(workspace.dictionary["disabled_permitted_directories", Set<String>.self], [])
      try directories.validateRequest(folder)
      // A stale menu callback cannot leave a disabled entry after its bookmark was removed.
      directories.setEnabled(false, for: folder.path)
      XCTAssertEqual(workspace.dictionary["disabled_permitted_directories", Set<String>.self], [])
    }
  }

  func testSwitchAndFolderChoicesSurviveDatabaseReopen() throws {
    onMain {
      let directories = PermittedDirectories(workspace: workspace)
      directories.setEnabled(false, for: folder.path)
      directories.setEnabled(false)
    }
    workspace.shutdown(flags: .truncate)
    workspace = SQLiteWorkspace(
      filePath: root.appendingPathComponent("config.sqlite3").path,
      fileProtectionLevel: .noProtection)
    try onMain {
      let directories = PermittedDirectories(workspace: workspace)
      XCTAssertFalse(directories.isEnabled)
      XCTAssertTrue(directories.urls.isEmpty)
      XCTAssertEqual(workspace.dictionary["permitted_directories", [String: Data].self], bookmarks)
      directories.setEnabled(true)
      XCTAssertThrowsError(try directories.validateRequest(folder)) {
        XCTAssertEqual($0 as? DirectoryPermissionError, .folderDisabled)
      }
      try directories.validateRequest(sibling)
    }
  }
}
