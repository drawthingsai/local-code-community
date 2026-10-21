import Foundation
import Testing

@Suite("Local path resolver")
struct LocalPathResolverTests {
  @Test func emptyProjectPathStillResolvesRelativePaths() {
    let localPathResolver = LocalPathResolver(projectPath: nil, workspacePath: nil)

    #expect(localPathResolver.resolve("abc.png")?.url.lastPathComponent == "abc.png")
  }

  @Test func resolvesProjectHomeTildeAndTemporaryPaths() throws {
    let fixture = try Fixture()

    #expect(
      fixture.localPathResolver.resolve("abc.png")?.url.path
        == fixture.projectURL.path + "/abc.png")
    #expect(
      fixture.localPathResolver.resolve("/home/abc.png")?.url.path
        == fixture.workspaceURL.path + "/abc.png")
    #expect(
      fixture.localPathResolver.resolve("~/abc.png")?.url.path
        == fixture.workspaceURL.path + "/abc.png")
    #expect(
      fixture.localPathResolver.resolve("/tmp/abc.png")?.url.path
        == fixture.temporaryURL.path + "/abc.png")
    #expect(
      fixture.localPathResolver.resolve("/app_bundle/Skills/review/SKILL.md")?.url.path
        == fixture.appBundleURL.path + "/Skills/review/SKILL.md")
  }

  @Test func aliasMatchingUsesPathComponentBoundaries() throws {
    let fixture = try Fixture()

    #expect(fixture.localPathResolver.resolve("/homepage/file") == nil)
    #expect(fixture.localPathResolver.resolve("/tmpfile") == nil)
    #expect(
      fixture.localPathResolver.resolve("~someone/file")?.url.path
        == fixture.projectURL.path + "/~someone/file")
    #expect(fixture.localPathResolver.resolve("/app_bundleish/file") == nil)
  }

  @Test func explicitRootsCannotBeEscaped() throws {
    let fixture = try Fixture()

    #expect(fixture.localPathResolver.resolve("../sibling") == nil)
    #expect(fixture.localPathResolver.resolve("/home/../outside") == nil)
    #expect(fixture.localPathResolver.resolve("~/../outside") == nil)
    #expect(fixture.localPathResolver.resolve("/tmp/../outside") == nil)
    #expect(fixture.localPathResolver.resolve("/app_bundle/../outside") == nil)
  }

  @Test func acceptsRealPathsInsideKnownRoots() throws {
    let fixture = try Fixture()
    let siblingURL = fixture.workspaceURL.appendingPathComponent("sibling/file.swift")
    let temporaryFileURL = fixture.temporaryURL.appendingPathComponent("result.txt")

    let sibling = fixture.localPathResolver.resolve(siblingURL.path)
    #expect(sibling?.url.path == siblingURL.path)
    #expect(sibling?.namespace == .home)
    #expect(sibling?.reference(for: "sibling/file.swift") == "/home/sibling/file.swift")

    let temporary = fixture.localPathResolver.resolve(temporaryFileURL.absoluteString)
    #expect(temporary?.url.path == temporaryFileURL.path)
    #expect(temporary?.namespace == .temporary)
    #expect(temporary?.reference(for: "result.txt") == "/tmp/result.txt")
  }

  @Test func resolvesAppBundleResourcesThroughVirtualPath() throws {
    let fixture = try Fixture()
    let skillURL = fixture.appBundleURL.appendingPathComponent("Skills/review/SKILL.md")

    let resolution = fixture.localPathResolver.resolve("/app_bundle/Skills/review/SKILL.md")

    #expect(resolution?.url.path == skillURL.path)
    #expect(resolution?.namespace == .appBundle)
    #expect(
      resolution?.reference(for: "Skills/review/SKILL.md")
        == "/app_bundle/Skills/review/SKILL.md")
    #expect(fixture.localPathResolver.resolve(skillURL.path)?.namespace == .appBundle)
  }

  @Test func writableNamespacesTakePrecedenceOverOverlappingAppBundleRoot() throws {
    let fixture = try Fixture()
    let appBundleURL = fixture.workspaceURL.appendingPathComponent("Bundled", isDirectory: true)
    let localPathResolver = LocalPathResolver(
      projectURL: fixture.projectURL, workspaceURL: fixture.workspaceURL,
      temporaryURL: fixture.temporaryURL, appBundleURL: appBundleURL)

    #expect(
      localPathResolver.resolve(appBundleURL.appendingPathComponent("file").path)?.namespace
        == .home
    )
  }

  @Test func permittedPathsRespectBoundariesSymlinksAndRevocation() throws {
    let fixture = try Fixture()
    let external = fixture.rootURL.appendingPathComponent("External", isDirectory: true)
    let outside = fixture.rootURL.appendingPathComponent("ExternalSibling", isDirectory: true)
    try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: external.appendingPathComponent("escape"), withDestinationURL: outside)
    try FileManager.default.createSymbolicLink(
      at: external.appendingPathComponent("dangling"),
      withDestinationURL: outside.appendingPathComponent("missing"))
    let resolver = LocalPathResolver(
      projectURL: fixture.projectURL, workspaceURL: fixture.workspaceURL,
      temporaryURL: fixture.temporaryURL, appBundleURL: fixture.appBundleURL,
      permittedDirectoryURLs: [external])
    let file = external.appendingPathComponent("file.txt")

    #expect(resolver.resolve(external.path)?.namespace == .permitted)
    #expect(resolver.resolve(file.path)?.url == file)
    #expect(resolver.resolve(file.path)?.reference(for: "file.txt") == file.path)
    #expect(resolver.resolve(outside.appendingPathComponent("file.txt").path) == nil)
    #expect(resolver.resolve(external.appendingPathComponent("escape/file.txt").path) == nil)
    #expect(resolver.resolve(external.appendingPathComponent("dangling/file.txt").path) == nil)
    #expect(resolver.resolve(external.appendingPathComponent("new/nested/file.txt").path) != nil)
    #expect(fixture.localPathResolver.resolve(file.path) == nil)
    #expect(resolver.fingerprint != fixture.localPathResolver.fingerprint)
  }

  @Test func fileURLsDecodePercentEscapesExactlyOnce() throws {
    let fixture = try Fixture()
    let file = fixture.projectURL.appendingPathComponent("literal%20name.txt")
    #expect(fixture.localPathResolver.resolve(file.absoluteString)?.url == file)
  }

  private final class Fixture {
    let rootURL: URL
    let workspaceURL: URL
    let projectURL: URL
    let temporaryURL: URL
    let appBundleURL: URL
    let localPathResolver: LocalPathResolver

    init() throws {
      rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
        "LocalPathResolverTests-\(UUID().uuidString)", isDirectory: true)
      workspaceURL = rootURL.appendingPathComponent("Workspace", isDirectory: true)
      projectURL = workspaceURL.appendingPathComponent("Project", isDirectory: true)
      temporaryURL = rootURL.appendingPathComponent("Caches/tmp", isDirectory: true)
      appBundleURL = rootURL.appendingPathComponent("AppBundle", isDirectory: true)
      try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: temporaryURL, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(
        at: appBundleURL, withIntermediateDirectories: true)
      localPathResolver = LocalPathResolver(
        projectURL: projectURL, workspaceURL: workspaceURL, temporaryURL: temporaryURL,
        appBundleURL: appBundleURL)
    }

    deinit { try? FileManager.default.removeItem(at: rootURL) }
  }
}
