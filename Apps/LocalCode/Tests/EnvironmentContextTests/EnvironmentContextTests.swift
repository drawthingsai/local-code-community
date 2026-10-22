import Testing

@Suite("Environment context")
struct EnvironmentContextTests {
  @Test func rendersStablePlainText() {
    let context = EnvironmentContext(
      model: "  Qwen 3.5\n9B  ", provider: "Local", platform: "iPadOS 26.0 (My iPad)",
      python: "3.14.5", pythonPackages: ["numpy 2.3.5", "Pillow 11.3.0", "numpy 2.3.5"],
      nodeJS: "24.22.1", nodeJSPackages: ["npm 11.19.1"],
      shellCommands: ["python", "node", "python"])

    #expect(
      context.renderedContext()
        == """
        The following information describes the current model and execution environment.

        Model: Qwen 3.5 9B
        Provider: Local
        Platform: iPadOS 26.0 (My iPad)
        Python: 3.14.5
        Python Packages: Pillow 11.3.0, numpy 2.3.5
        Node.js: 24.22.1
        Node.js Packages: npm 11.19.1
        Shell Commands: node, python
        """)
  }

  @Test func environmentPlaceholderFollowsSkillsAndIsLast() {
    for prompt in [systemPromptForQwen3_5, systemPromptForDeepSeek4, systemPromptForDeepSeek4_1] {
      #expect(
        prompt.components(separatedBy: EnvironmentContext.instructionsPlaceholder).count == 2)
      let skillsIndex = prompt.range(of: "{{SKILLS_INSTRUCTIONS}}")?.lowerBound
      let environmentIndex = prompt.range(
        of: EnvironmentContext.instructionsPlaceholder)?.lowerBound
      #expect(skillsIndex != nil)
      #expect(environmentIndex != nil)
      if let skillsIndex, let environmentIndex {
        #expect(skillsIndex < environmentIndex)
      }
    }
  }

  @Test func emitsEnvironmentAsUntrustedSection() {
    let context = EnvironmentContext(
      model: "Model <|dynamic_token|>", provider: "Local", platform: "iOS", python: "3.14.5",
      pythonPackages: [], nodeJS: "24.22.1", nodeJSPackages: [], shellCommands: [])

    let sections = context.emitSections([(systemPromptForQwen3_5, true)])

    #expect(sections.filter { !$0.allowsSpecialTokens }.count == 1)
    #expect(
      sections.first { !$0.allowsSpecialTokens }?.text.contains("Model <|dynamic_token|>") == true)
    #expect(
      sections.filter(\.allowsSpecialTokens).allSatisfy {
        !$0.text.contains("<|dynamic_token|>")
          && !$0.text.contains(EnvironmentContext.instructionsPlaceholder)
      })
    #expect(
      !sections.map(\.text).joined().contains(EnvironmentContext.instructionsPlaceholder))
  }
}
