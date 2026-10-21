import Foundation
import XCTest

@testable import LocalCodeCLI
@testable import RemoteAPI

final class RemoteContextBudgetTests: XCTestCase {
  func testCompatibleFallbackFitsBundledInstructionsAndTools() throws {
    let skillsURL = try XCTUnwrap(Resources.resourceURL).appendingPathComponent(
      "Skills", isDirectory: true)
    let catalog = SkillCatalog.find(roots: [
      SkillRoot(
        url: skillsURL, allowedRootURL: skillsURL, scope: .builtIn,
        modelRootPath: "/app_bundle/Skills")
    ])
    XCTAssertTrue(!catalog.entries.isEmpty)
    let limits = RemoteModelLimits.openAICompatibleFallback
    let configuration = RemoteAgentConfiguration(
      contextWindowTokens: limits.contextWindowTokens,
      reservedOutputTokens: limits.maximumOutputTokens)
    for runtime in [RemoteRuntime.mac, .iosSystem] {
      let state = RemoteAgentState(transcript: [
        .user("Inspect this project and summarize the files.")
      ])
      let prepared = RemoteContext.preparedContext(
        state: state, systemPrompt: remoteSystemPrompt(runtime: runtime, skillCatalog: catalog),
        tools: RemoteToolSchema.tools, configuration: configuration)
      let reserve = RemoteContext.compactionReserveTokens(
        contextWindowTokens: limits.contextWindowTokens)
      // Leave room for a small prompt or tool result beyond the fixed instructions.
      XCTAssertTrue(
        prepared.estimatedTokens + configuration.reservedOutputTokens + reserve + 1_024
          < limits.contextWindowTokens)
    }
  }
}
