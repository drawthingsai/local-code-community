import XCTest

final class ShellCommandParserTests: XCTestCase {
  func testParsesQuotedArguments() {
    XCTAssertEqual(
      ShellCommandParser.parse(#"python -c 'print("hello world")' "two words""#),
      .direct(
        ShellCommand(
          arguments: ["python", "-c", #"print("hello world")"#, "two words"],
          redirections: [])))
  }

  func testParsesOrderedRedirections() {
    XCTAssertEqual(
      ShellCommandParser.parse("rg needle Sources >matches.txt 2>&1"),
      .direct(
        ShellCommand(
          arguments: ["rg", "needle", "Sources"],
          redirections: [
            .output("matches.txt", append: false),
            .errorToOutput,
          ])))
  }

  func testParsesAttachedAndAppendRedirections() {
    XCTAssertEqual(
      ShellCommandParser.parse("python script.py<input.txt 2>>errors.txt >>output.txt"),
      .direct(
        ShellCommand(
          arguments: ["python", "script.py"],
          redirections: [
            .input("input.txt"),
            .error("errors.txt", append: true),
            .output("output.txt", append: true),
          ])))
  }

  func testPreservesQuotedRedirectionPaths() {
    XCTAssertEqual(
      ShellCommandParser.parse(
        #"cat < "Input Files/source file.txt" >> "Output Files/result file.txt" 2> "Logs/error file.txt""#
      ),
      .direct(
        ShellCommand(
          arguments: ["cat"],
          redirections: [
            .input("Input Files/source file.txt"),
            .output("Output Files/result file.txt", append: true),
            .error("Logs/error file.txt", append: false),
          ])))
  }

  func testKeepsEscapedShellCharactersLiteral() {
    XCTAssertEqual(
      ShellCommandParser.parse(#"echo \$HOME "\$USER""#),
      .direct(
        ShellCommand(arguments: ["echo", "$HOME", "$USER"], redirections: [])))
  }

  func testParsesDirectorySetupBeforeDirectCommand() {
    XCTAssertEqual(
      ShellCommandParser.parse(#"cd "web content" && python -m http.server 8080"#),
      .directSequence([
        ShellCommand(arguments: ["cd", "web content"], redirections: []),
        ShellCommand(
          arguments: ["python", "-m", "http.server", "8080"], redirections: []),
      ]))
  }

  func testMathlibInstallerUsesDirectDirectoryAliasPath() {
    XCTAssertEqual(
      ShellCommandParser.parse(
        "cd /app_bundle && python3 Skills/check_lean-and-lean-tools/scripts/install_mathlib.py --project-root '/home/proof project' --lean-version 4.34.0"
      ),
      .directSequence([
        ShellCommand(arguments: ["cd", "/app_bundle"], redirections: []),
        ShellCommand(
          arguments: [
            "python3", "Skills/check_lean-and-lean-tools/scripts/install_mathlib.py",
            "--project-root", "/home/proof project", "--lean-version", "4.34.0",
          ], redirections: []),
      ]))
  }

  func testParsesGenericAndSequence() {
    XCTAssertEqual(
      ShellCommandParser.parse("make all && echo done && true"),
      .directSequence([
        ShellCommand(arguments: ["make", "all"], redirections: []),
        ShellCommand(arguments: ["echo", "done"], redirections: []),
        ShellCommand(arguments: ["true"], redirections: []),
      ]))
  }

  func testPreservesQuotedPathsInSequence() {
    XCTAssertEqual(
      ShellCommandParser.parse(
        #"cd "Desktop Folder" && mv IMG_4946.png "Photos/IMG_4946.png" && mv "Screenshot 2026-08-31 at 12.12.57 PM.png" "Screenshots & Screen Recordings/Screenshot 2026-08-31 at 12.12.57 PM.png""#
      ),
      .directSequence([
        ShellCommand(arguments: ["cd", "Desktop Folder"], redirections: []),
        ShellCommand(
          arguments: ["mv", "IMG_4946.png", "Photos/IMG_4946.png"], redirections: []),
        ShellCommand(
          arguments: [
            "mv",
            "Screenshot 2026-08-31 at 12.12.57 PM.png",
            "Screenshots & Screen Recordings/Screenshot 2026-08-31 at 12.12.57 PM.png",
          ], redirections: []),
      ]))
  }

  func testParsesRedirectionsInSequence() {
    XCTAssertEqual(
      ShellCommandParser.parse("cd directory && python server.py >server.log"),
      .directSequence([
        ShellCommand(arguments: ["cd", "directory"], redirections: []),
        ShellCommand(
          arguments: ["python", "server.py"],
          redirections: [.output("server.log", append: false)]),
      ]))
  }

  func testKeepsQuotedAndEscapedAndOperatorsLiteral() {
    XCTAssertEqual(
      ShellCommandParser.parse(#"echo 'one && two' three\&\&four"#),
      .direct(
        ShellCommand(arguments: ["echo", "one && two", "three&&four"], redirections: [])))
  }

  func testFallsBackForShellEvaluation() {
    let commands = [
      "rg needle | head",
      "echo $HOME",
      "echo *.swift",
      "VALUE=1 python script.py",
      "cat <<EOF",
      "echo hello 12>output.txt",
      "echo unterminated'",
      "echo 'multiple\nlines'",
    ]
    for command in commands {
      XCTAssertEqual(
        ShellCommandParser.parse(command), .requiresShell,
        "Expected OSH fallback for: \(command)")
    }
  }

  func testLeavesCommandSafetyToIOSSystem() {
    XCTAssertEqual(
      ShellCommandParser.parse("sh -c 'echo hello'"),
      .direct(
        ShellCommand(
          arguments: ["sh", "-c", "echo hello"], redirections: [])))
    XCTAssertEqual(
      ShellCommandParser.parse("/bin/sh -c 'echo hello'"),
      .direct(
        ShellCommand(
          arguments: ["/bin/sh", "-c", "echo hello"], redirections: [])))
  }

}
