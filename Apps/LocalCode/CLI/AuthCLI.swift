import AppKit
import ArgumentParser
import Darwin
import Foundation
import RemoteAPI

struct AuthCLI: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "auth", abstract: "Manage saved remote-provider credentials.",
    subcommands: [AuthLoginCLI.self, AuthStatusCLI.self, AuthLogoutCLI.self])
}

struct AuthCLIOptions: ParsableArguments {
  @Option(help: "Remote provider: anthropic, openai, openai-compatible, openrouter, or localcode.")
  var provider: RemoteProvider

  @Option(help: "API base URL. Defaults to the selected provider's public endpoint.")
  var baseURL: String?

  func endpoint() throws -> RemoteProviderAccountEndpoint {
    let url: URL?
    if let baseURL {
      guard let parsed = URL(string: baseURL) else {
        throw ValidationError("Invalid API base URL: \(baseURL)")
      }
      url = parsed
    } else {
      url = nil
    }
    return try RemoteProviderAccountEndpoint(provider: provider, baseURL: url)
  }
}

struct AuthLoginCLI: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "login", abstract: "Sign in through the provider's browser OAuth flow.")

  @OptionGroup var options: AuthCLIOptions

  @Flag(inversion: .prefixedNo, help: "Open the sign-in page in the default browser.")
  var browser = true

  mutating func validate() throws {
    let endpoint = try options.endpoint()
    guard options.provider == .anthropic || options.provider == .openAI else {
      throw ValidationError("Browser sign-in supports anthropic and openai.")
    }
    guard endpoint.baseURL == options.provider.defaultBaseURL else {
      throw ValidationError("Browser sign-in requires the provider's default official endpoint.")
    }
  }

  mutating func run() async throws {
    let endpoint = try options.endpoint()
    let command = self
    let task = Task { try await command.authorize() }
    let interrupt = AgentCLIInterrupt { task.cancel() }
    do {
      let credential = try await task.value
      if let signal = interrupt.signalNumber { throw ExitCode(128 + signal) }
      try RemoteCredentialStore.upsertOAuth(
        credential, account: endpoint.baseURL.absoluteString, provider: endpoint.provider)
      print("Signed in to \(endpoint.provider.rawValue). Credentials saved in macOS Keychain.")
    } catch {
      if let signal = interrupt.signalNumber { throw ExitCode(128 + signal) }
      throw error
    }
  }

  func authorize(
    session: URLSession = URLSession(configuration: .ephemeral),
    timeout: TimeInterval = 15 * 60,
    openBrowser: @escaping @Sendable (URL) async -> Void = { url in
      await MainActor.run { _ = NSWorkspace.shared.open(url) }
    }
  ) async throws -> RemoteOAuthCredential {
    try await withThrowingTaskGroup(of: RemoteOAuthCredential.self) { group in
      defer { group.cancelAll() }
      group.addTask {
        if options.provider == .openAI {
          let authorization = try await RemoteOAuth.requestOpenAIDeviceAuthorization(
            session: session)
          print("Open \(authorization.verificationURL.absoluteString)")
          print("Enter code: \(authorization.userCode)")
          fflush(stdout)
          if browser { await openBrowser(authorization.verificationURL) }
          return try await RemoteOAuth.completeOpenAIDeviceAuthorization(
            authorization, session: session)
        }
        let authorization = try RemoteOAuth.anthropicAuthorization()
        let server = try RemoteOAuthLoopbackServer(
          callbackURL: authorization.callbackURL, expectedState: authorization.state)
        let callbacks = AsyncThrowingStream<String, Error> { continuation in
          continuation.onTermination = { _ in server.cancel() }
          server.start(
            ready: { result in
              switch result {
              case .success:
                print("Complete sign-in in your browser. Waiting for the local callback.")
                print(authorization.url.absoluteString)
                fflush(stdout)
                if browser { Task { await openBrowser(authorization.url) } }
              case .failure(let error):
                continuation.finish(throwing: error)
              }
            },
            callback: { result in
              switch result {
              case .success(let input):
                continuation.yield(input)
                continuation.finish()
              case .failure(let error):
                continuation.finish(throwing: error)
              }
            })
        }
        defer { server.cancel() }
        for try await input in callbacks {
          try Task.checkCancellation()
          return try await RemoteOAuth.exchangeAnthropicCode(
            input, authorization: authorization, session: session)
        }
        throw CancellationError()
      }
      group.addTask {
        try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        throw RemoteOAuthError.timedOut
      }
      return try await group.next()!
    }
  }
}

struct AuthStatusCLI: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "status", abstract: "Inspect saved credentials without exposing secrets.")

  @OptionGroup var options: AuthCLIOptions

  mutating func run() throws {
    let endpoint = try options.endpoint()
    print("Provider: \(endpoint.provider.rawValue)")
    print("Endpoint: \(endpoint.baseURL.absoluteString)")
    guard
      let credential = try RemoteCredentialStore.readCredential(
        account: endpoint.baseURL.absoluteString, provider: endpoint.provider)
    else {
      print("No saved credentials. Run auth login or configure an API key environment variable.")
      throw ExitCode.failure
    }
    switch credential.value {
    case .unauthenticated:
      print("Configured without authentication. Server connectivity has not been verified.")
    case .apiKey:
      print("Saved API key. Server authentication has not been verified.")
    case .oauth(let oauth):
      print("Saved OAuth credentials. Server authentication has not been verified.")
      print("Access token expires: \(ISO8601DateFormatter().string(from: oauth.expiresAt))")
      if oauth.expiresAt.timeIntervalSinceNow <= 5 * 60 {
        print("Refresh required; remote-agent will attempt it before sending a request.")
      }
    }
    if endpoint.provider != .openAI,
      endpoint.provider != .openAICompatible
        || RemoteProvider.isOpenAIAPIHost(endpoint.baseURL),
      ProcessInfo.processInfo.environment[endpoint.provider.defaultAPIKeyEnvironment]?
        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    {
      print("\(endpoint.provider.defaultAPIKeyEnvironment) is set and takes precedence.")
    }
  }
}

struct AuthLogoutCLI: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "logout", abstract: "Remove this endpoint's saved credentials from Keychain.")

  @OptionGroup var options: AuthCLIOptions

  mutating func run() throws {
    let endpoint = try options.endpoint()
    try RemoteCredentialStore.delete(
      account: endpoint.baseURL.absoluteString, provider: endpoint.provider)
    print("Removed saved credentials for \(endpoint.provider.rawValue) at \(endpoint.baseURL).")
    print("API key environment variables are unchanged.")
  }
}
