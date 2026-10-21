import Testing

@Suite("check_smt tool")
struct CheckSmtToolTests {
  @Test func findsSatisfyingModel() async {
    let response = await invoke(
      """
      (set-logic QF_LIA)
      (declare-const x Int)
      (assert (> x 4))
      """)

    #expect(response.hasPrefix("status: sat\nmodel:\n"))
    #expect(response.contains("  x = 5"))
  }

  @Test func formatsModelsAsPlainText() async {
    let response = await invoke(
      """
      (set-logic QF_LIA)
      (declare-const offset Int)
      (declare-const length Int)
      (assert (= offset 63))
      (assert (= length 66))
      """)

    #expect(response.hasPrefix("status: sat\nmodel:\n"))
    #expect(response.contains("  offset = 63"))
    #expect(response.contains("  length = 66"))
  }

  @Test func displaysTheFullProgramWhileRunningAndCollapsesItWhenDone() {
    let program =
      """
      (set-logic QF_LIA)
      (assert true)
      """
    let tool = CheckSmtTool(code: program)

    #expect(tool.subtitle(for: .now).hasSuffix(": \n```\n\(program)\n```"))
    #expect(tool.subtitle(for: .past).hasSuffix(": `(set-logic QF_LIA)...`"))

    let singleLineTool = CheckSmtTool(code: "(assert true)")
    #expect(singleLineTool.subtitle(for: .past).hasSuffix(": `(assert true)`"))
  }

  @Test func provesImplicationByUnsatisfiableNegation() async {
    let response = await invoke(
      """
      (set-logic QF_LIA)
      (declare-const x Int)
      (assert (> x 10))
      (assert (not (> x 5)))
      """)

    #expect(response == "status: unsat")
  }

  @Test func supportsBitVectors() async {
    let response = await invoke(
      """
      (set-logic QF_BV)
      (declare-const x (_ BitVec 8))
      (assert (= (bvadd x #x01) #x00))
      """)

    #expect(response.hasPrefix("status: sat\nmodel:\n"))
    #expect(response.contains("  x = #xff"))
  }

  @Test func rejectsRuntimeOwnedCommands() async {
    for command in ["(check-sat)", "(get-model)", "(set-option :timeout 1)", "(push 1)"] {
      let response = await invoke(command)
      #expect(response.hasPrefix("status: error\nreason:\n"))
      #expect(response.contains("not allowed"))
    }
  }

  @Test func reportsMalformedInputWithoutCrashing() async {
    let response = await invoke("(assert")

    #expect(response.hasPrefix("status: error\nreason:\n"))
    #expect(response.contains("unbalanced parentheses"))
  }

  @Test func reportsZ3ParserErrorsAsTheReason() async {
    let response = await invoke(
      """
      (declare-fun average (Int Int) Int)
      (define-fun average ((a Int) (b Int)) Int (div (+ a b) 2))
      """)

    #expect(response.hasPrefix("status: error\nreason:\n"))
    #expect(response.contains("declaration already defined with this name average"))
  }

  @Test func usesFreshContextForEveryCall() async {
    let integerResponse = await invoke("(declare-const value Int) (assert (= value 1))")
    let booleanResponse = await invoke(
      "(declare-const value Bool) (assert (= value true))")

    #expect(integerResponse.hasPrefix("status: sat\n"))
    #expect(booleanResponse.hasPrefix("status: sat\n"))
  }

  @Test func enforcesInputLimit() async {
    let response = await invoke(
      "(assert true)" + String(repeating: " ", count: 128 * 1024))

    #expect(response.hasPrefix("status: error\nreason:\n"))
    #expect(response.contains("128 KiB"))
  }

  @Test func parserRequiresExactlyOneStringArgument() {
    let validRequest = ToolCall.Request(
      function: "check_smt",
      parameters: ["code": .init(string: true, value: "(assert true)")])
    let extraRequest = ToolCall.Request(
      function: "check_smt",
      parameters: [
        "code": .init(string: true, value: "(assert true)"),
        "timeout": .init(string: false, value: "1"),
      ])

    #expect(CheckSmtTool.parse(validRequest) != nil)
    #expect(CheckSmtTool.parse(extraRequest) == nil)
  }

  private func invoke(_ code: String) async -> String {
    await withCheckedContinuation { continuation in
      CheckSmtTool(code: code).invoke { continuation.resume(returning: $0) }
    }
  }
}
