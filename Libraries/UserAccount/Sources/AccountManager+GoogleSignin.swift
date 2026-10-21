import Foundation

extension AccountManager {
  public enum SignInProvider: String {
    case apple
    case google
  }

  private static let googleAppLoginEndpoint: URL = endpoint.appendingPathComponent(
    "/auth/google/app/login")
  private static let localCodeGoogleAppLoginEndpoint: URL = endpoint.appendingPathComponent(
    "/auth/google/localcode/login")
  private static let googleIssuers: Set<String> = [
    "https://accounts.google.com",
    "accounts.google.com",
  ]

  public func googleSignInURL() -> URL {
    Self.googleAppLoginEndpoint
  }

  public func localCodeGoogleSignInURL() -> URL {
    Self.localCodeGoogleAppLoginEndpoint
  }

  @discardableResult
  public func signIn(
    withGoogleIdentityToken token: String,
    completion: @escaping (Result<Account, Error>) -> Void
  ) -> URLSessionDataTask? {
    let userIdentifier = Self.decode(jwtToken: token)?["sub"] as? String
    return signIn(
      with: token, userIdentifier: userIdentifier, provider: .google, completion: completion)
  }

  static func inferredSignInProvider(for token: String) -> SignInProvider {
    guard let issuer = decode(jwtToken: token)?["iss"] as? String,
      googleIssuers.contains(issuer)
    else {
      return .apple
    }
    return .google
  }
}
