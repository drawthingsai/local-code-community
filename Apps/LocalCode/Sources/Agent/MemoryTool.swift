import Foundation
import Localization
import ProjectHistoryManager

public struct MemoryTool {
  private let request: ToolCall.Request
  private let projectPath: String?

  public static func parse(_ request: ToolCall.Request, projectPath: String?) -> MemoryTool? {
    guard request.function == "memory" else { return nil }
    return MemoryTool(request: request, projectPath: projectPath)
  }

  public func subtitle(for moment: ToolSubtitleMoment) -> String {
    let title: String
    switch (request.parameters["action"]?.value, moment) {
    case (nil, .now):
      title = LocalizedString.forKey("tool_memory_read_now")
    case (nil, .past):
      title = LocalizedString.forKey("tool_memory_read_past")
    case ("append", .now):
      title = LocalizedString.forKey("tool_memory_append_now")
    case ("append", .past):
      title = LocalizedString.forKey("tool_memory_append_past")
    case ("replace", .now):
      title = LocalizedString.forKey("tool_memory_replace_now")
    case ("replace", .past):
      title = LocalizedString.forKey("tool_memory_replace_past")
    case ("remove", .now):
      title = LocalizedString.forKey("tool_memory_remove_now")
    case ("remove", .past):
      title = LocalizedString.forKey("tool_memory_remove_past")
    default:
      title = LocalizedString.forKey("tool_memory")
    }
    guard
      let target = request.parameters["target"].flatMap({
        ProjectMemory.Target(rawValue: $0.value)
      })
    else { return "**\(title)**" }
    return "**\(title)**: `\(target.fileName)`"
  }

  /// The response carries the target's entries it shows, so the agent can track what the
  /// conversation has seen.
  public func invoke(completion: @escaping (ToolResponse) -> Void) {
    let target = request.parameters["target"].flatMap { ProjectMemory.Target(rawValue: $0.value) }
    func snapshot(_ entries: [String], previousEntries: [String]? = nil) -> MemorySnapshot? {
      guard let target, let text = MemoryContext.text(entries: entries, target: target) else {
        return nil
      }
      return MemorySnapshot(
        target: target.rawValue, text: text,
        previousText: previousEntries.map { $0.joined(separator: "\n§\n") }.map {
          $0.isEmpty ? "(empty)" : $0
        })
    }
    do {
      let parameters = request.parameters
      guard Set(parameters.keys).isSubset(of: ["target", "action", "content", "old_text"]),
        parameters.values.allSatisfy(\.string),
        parameters.values.reduce(0, { $0 + $1.value.utf8.count }) <= ProjectMemory.maximumBytes,
        let target
      else {
        throw ProjectMemory.Error.invalidArguments(
          "Supply target=user or memory, with string arguments only (64 KiB maximum).")
      }
      let action = parameters["action"]?.value
      let content: String?
      if let value = parameters["content"]?.value {
        let entries = try ProjectMemory.parse(Data(value.utf8))
        guard entries.count == 1 else {
          throw ProjectMemory.Error.invalidArguments(
            "content must be one non-empty entry without a § separator line.")
        }
        content = entries[0]
      } else {
        content = nil
      }
      let oldText = parameters["old_text"]?.value
      if let oldText, oldText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        throw ProjectMemory.Error.invalidArguments("old_text must not be empty.")
      }
      switch action {
      case nil:
        guard content == nil, oldText == nil else {
          throw ProjectMemory.Error.invalidArguments(
            "A read accepts only target; omit action, content, and old_text.")
        }
        let file = try ProjectMemory.fileURL(projectPath: projectPath, target: target)
        let data = try ProjectMemory.read(file)
        let entries = try ProjectMemory.parse(data ?? Data())
        completion(
          ToolResponse(
            text:
              "\(data == nil ? "\(target.relativePath) does not exist; no entries." : "Read \(target.relativePath).")\n\(ProjectMemory.contents(entries, target: target))",
            memory: snapshot(entries)))
      case "append" where content != nil && oldText == nil,
        "replace" where content != nil && oldText != nil,
        "remove" where content == nil && oldText != nil:
        let (response, entries, previousEntries) = try ProjectMemory.update(
          projectPath: projectPath, target: target, action: action!, content: content,
          oldText: oldText)
        completion(
          ToolResponse(text: response, memory: snapshot(entries, previousEntries: previousEntries)))
      default:
        throw ProjectMemory.Error.invalidArguments(
          "Omit action to read; append needs content, replace needs old_text and the complete replacement entry in content, and remove needs old_text."
        )
      }
    } catch {
      var response = "Error: \(error.localizedDescription)\nNo changes were written by this call."
      var memory: MemorySnapshot? = nil
      if let target,
        let file = try? ProjectMemory.fileURL(projectPath: projectPath, target: target),
        let data = try? ProjectMemory.read(file), let entries = try? ProjectMemory.parse(data)
      {
        response += "\n\n" + ProjectMemory.contents(entries, target: target)
        memory = snapshot(entries)
      }
      completion(ToolResponse(text: response, memory: memory))
    }
  }
}
