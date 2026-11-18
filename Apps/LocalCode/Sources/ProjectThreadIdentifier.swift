import Foundation

/// A chat in a project, keying what belongs to one thread: its remote conversation, browser,
/// draw-things-cli generation and image model download, and transient messages.
struct ProjectThreadIdentifier: Hashable, Codable {
  let projectPath: String
  let threadId: Int64

  // Local and remote agents spell the same project with and without resolved symlinks.
  init(projectURL: URL, threadId: Int64) {
    projectPath = projectURL.standardizedFileURL.resolvingSymlinksInPath().path
    self.threadId = threadId
  }
}
