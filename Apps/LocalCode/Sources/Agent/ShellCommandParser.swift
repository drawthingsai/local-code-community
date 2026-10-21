import Foundation

enum ShellCommandRedirection: Equatable {
  case input(String)
  case output(String, append: Bool)
  case error(String, append: Bool)
  case errorToOutput
}

struct ShellCommand: Equatable {
  let arguments: [String]
  let redirections: [ShellCommandRedirection]
}

enum ShellCommandParsingResult: Equatable {
  case direct(ShellCommand)
  case directSequence([ShellCommand])
  case requiresShell
}

enum ShellCommandParser {
  private enum Quote {
    case single
    case double
  }

  private enum PendingRedirection {
    case input
    case output(append: Bool)
    case error(append: Bool)
  }

  static func parse(_ command: String) -> ShellCommandParsingResult {
    guard !command.contains("\n"), !command.contains("\r") else {
      return .requiresShell
    }
    if let segments = splitAndChain(command) {
      var commands = [ShellCommand]()
      for segment in segments {
        guard case .direct(let parsedCommand) = parseDirectCommand(segment) else {
          return .requiresShell
        }
        commands.append(parsedCommand)
      }
      guard commands.count >= 2 else {
        return .requiresShell
      }
      return .directSequence(commands)
    }
    return parseDirectCommand(command)
  }

  private static func parseDirectCommand(_ command: String) -> ShellCommandParsingResult {
    let characters = Array(command)
    var arguments = [String]()
    var redirections = [ShellCommandRedirection]()
    var pendingRedirection: PendingRedirection?
    var quote: Quote?
    var word = ""
    var hasWord = false
    var wordIsPlain = true
    var index = 0

    func finishWord() {
      guard hasWord else { return }
      if let pendingRedirection {
        switch pendingRedirection {
        case .input:
          redirections.append(.input(word))
        case .output(let append):
          redirections.append(.output(word, append: append))
        case .error(let append):
          redirections.append(.error(word, append: append))
        }
      } else {
        arguments.append(word)
      }
      word = ""
      hasWord = false
      wordIsPlain = true
      pendingRedirection = nil
    }

    while index < characters.count {
      let character = characters[index]

      if quote == .single {
        if character == "'" {
          quote = nil
        } else {
          word.append(character)
        }
        index += 1
        continue
      }

      if quote == .double {
        switch character {
        case "\"":
          quote = nil
          index += 1
        case "$", "`":
          return .requiresShell
        case "\\":
          guard index + 1 < characters.count else { return .requiresShell }
          let next = characters[index + 1]
          if next == "$" || next == "`" || next == "\"" || next == "\\" {
            word.append(next)
            index += 2
          } else if next == "\n" {
            index += 2
          } else {
            word.append("\\")
            index += 1
          }
        default:
          word.append(character)
          index += 1
        }
        continue
      }

      if character == "\n" || character == "\r" {
        return .requiresShell
      }
      if character.isWhitespace {
        finishWord()
        index += 1
        continue
      }

      switch character {
      case "'":
        quote = .single
        hasWord = true
        wordIsPlain = false
        index += 1
      case "\"":
        quote = .double
        hasWord = true
        wordIsPlain = false
        index += 1
      case "\\":
        guard index + 1 < characters.count else { return .requiresShell }
        let next = characters[index + 1]
        if next != "\n" {
          word.append(next)
          hasWord = true
          wordIsPlain = false
        }
        index += 2
      case "<", ">":
        if pendingRedirection != nil {
          guard hasWord else { return .requiresShell }
          finishWord()
        }

        let redirectionCharacter = character
        var descriptor = redirectionCharacter == "<" ? 0 : 1
        if hasWord && wordIsPlain && word.allSatisfy(\.isNumber) {
          guard let parsedDescriptor = Int(word), parsedDescriptor <= 2 else {
            return .requiresShell
          }
          descriptor = parsedDescriptor
          word = ""
          hasWord = false
          wordIsPlain = true
        } else {
          finishWord()
        }

        if redirectionCharacter == "<" && descriptor != 0 {
          return .requiresShell
        }
        if redirectionCharacter == ">" && descriptor == 0 {
          return .requiresShell
        }

        var append = false
        if index + 1 < characters.count, characters[index + 1] == ">" {
          guard redirectionCharacter == ">" else { return .requiresShell }
          append = true
          index += 1
        }

        if redirectionCharacter == ">", index + 1 < characters.count,
          characters[index + 1] == "&"
        {
          guard !append, descriptor == 2, index + 2 < characters.count,
            characters[index + 2] == "1"
          else { return .requiresShell }
          let afterDescriptor = index + 3
          if afterDescriptor < characters.count,
            !characters[afterDescriptor].isWhitespace,
            characters[afterDescriptor] != "<", characters[afterDescriptor] != ">"
          {
            return .requiresShell
          }
          redirections.append(.errorToOutput)
          index += 3
        } else {
          switch (redirectionCharacter, descriptor) {
          case ("<", 0):
            pendingRedirection = .input
          case (">", 1):
            pendingRedirection = .output(append: append)
          case (">", 2):
            pendingRedirection = .error(append: append)
          default:
            return .requiresShell
          }
          index += 1
        }
      case "$", "`", "|", "&", ";", "(", ")", "{", "}", "*", "?", "[", "#", "!":
        return .requiresShell
      case "~" where !hasWord:
        return .requiresShell
      default:
        word.append(character)
        hasWord = true
        index += 1
      }
    }

    guard quote == nil else { return .requiresShell }
    finishWord()
    guard pendingRedirection == nil, let commandName = arguments.first else {
      return .requiresShell
    }
    if isEnvironmentAssignment(commandName) {
      return .requiresShell
    }
    return .direct(ShellCommand(arguments: arguments, redirections: redirections))
  }

  private static func splitAndChain(_ command: String) -> [String]? {
    let characters = Array(command)
    var segments = [String]()
    var quote: Quote?
    var segmentStart = 0
    var index = 0

    while index < characters.count {
      let character = characters[index]
      if quote == .single {
        if character == "'" {
          quote = nil
        }
        index += 1
        continue
      }
      if quote == .double {
        if character == "\\" && index + 1 < characters.count {
          index += 2
        } else {
          if character == "\"" {
            quote = nil
          }
          index += 1
        }
        continue
      }

      switch character {
      case "'":
        quote = .single
        index += 1
      case "\"":
        quote = .double
        index += 1
      case "\\":
        index += min(2, characters.count - index)
      case "&" where index + 1 < characters.count && characters[index + 1] == "&":
        segments.append(String(characters[segmentStart..<index]))
        index += 2
        segmentStart = index
      default:
        index += 1
      }
    }

    guard !segments.isEmpty else { return nil }
    segments.append(String(characters[segmentStart...]))
    return segments
  }

  private static func isEnvironmentAssignment(_ word: String) -> Bool {
    guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
    let name = word[..<equals]
    guard let first = name.first, first == "_" || first.isLetter else { return false }
    return name.dropFirst().allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
  }
}
