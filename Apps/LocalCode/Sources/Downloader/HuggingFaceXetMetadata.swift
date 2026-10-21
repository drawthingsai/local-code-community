import Foundation

struct HuggingFaceXetMetadata: Equatable {
  let fileHash: String
  let fileSize: UInt64
  let refreshURL: URL
}

enum HuggingFaceXetMetadataError: LocalizedError {
  case invalidRepository(String)
  case invalidResponse
  case server(Int)
  case missingXetMetadata

  var errorDescription: String? {
    switch self {
    case .invalidRepository(let repository):
      return "Invalid Hugging Face repository: \(repository)"
    case .invalidResponse:
      return "Hugging Face returned an invalid response"
    case .server(let statusCode):
      return "Hugging Face server error \(statusCode)"
    case .missingXetMetadata:
      return "The Hugging Face file is not available through Xet"
    }
  }
}

final class HuggingFaceXetMetadataResolver: NSObject, URLSessionTaskDelegate {
  private var session: URLSession?

  static func mirrorRepository(for officialRepository: String) throws -> String {
    let repositoryName: String?
    if let url = URL(string: officialRepository), url.scheme != nil {
      repositoryName = url.pathComponents.last { $0 != "/" }
    } else {
      repositoryName = officialRepository.split(separator: "/").last.map(String.init)
    }
    guard let repositoryName, !repositoryName.isEmpty,
      repositoryName.rangeOfCharacter(from: CharacterSet(charactersIn: "/?#")) == nil
    else {
      throw HuggingFaceXetMetadataError.invalidRepository(officialRepository)
    }
    return "drawthingsai/\(repositoryName)"
  }

  static func metadata(from response: HTTPURLResponse) throws -> HuggingFaceXetMetadata {
    guard (200..<400).contains(response.statusCode) else {
      throw HuggingFaceXetMetadataError.server(response.statusCode)
    }
    guard let fileHash = response.value(forHTTPHeaderField: "X-Xet-Hash"),
      fileHash.count == 64,
      fileHash.allSatisfy({ $0.isHexDigit }),
      let fileSizeString = response.value(forHTTPHeaderField: "X-Linked-Size"),
      let fileSize = UInt64(fileSizeString), fileSize > 0,
      let link = response.value(forHTTPHeaderField: "Link"),
      let refreshURL = xetAuthenticationURL(from: link)
    else {
      throw HuggingFaceXetMetadataError.missingXetMetadata
    }
    return HuggingFaceXetMetadata(
      fileHash: fileHash.lowercased(), fileSize: fileSize, refreshURL: refreshURL)
  }

  @discardableResult
  func resolve(
    officialRepository: String, file: String,
    completionHandler: @escaping (Result<HuggingFaceXetMetadata, Error>) -> Void
  ) -> URLSessionDataTask? {
    let mirrorRepository: String
    do {
      mirrorRepository = try Self.mirrorRepository(for: officialRepository)
    } catch {
      completionHandler(.failure(error))
      return nil
    }
    let repositoryComponents = mirrorRepository.split(separator: "/").map(String.init)
    guard repositoryComponents.count == 2, !file.isEmpty else {
      completionHandler(
        .failure(HuggingFaceXetMetadataError.invalidRepository(officialRepository)))
      return nil
    }
    var url = URL(string: "https://huggingface.co")!
    for component in repositoryComponents + ["resolve", "main", file] {
      url.appendPathComponent(component)
    }
    var request = URLRequest(url: url)
    request.httpMethod = "HEAD"
    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

    let session = URLSession(
      configuration: .ephemeral, delegate: self, delegateQueue: .main)
    self.session = session
    let task = session.dataTask(with: request) { [weak self] _, response, error in
      self?.session?.finishTasksAndInvalidate()
      self?.session = nil
      if let error {
        completionHandler(.failure(error))
        return
      }
      guard let response = response as? HTTPURLResponse else {
        completionHandler(.failure(HuggingFaceXetMetadataError.invalidResponse))
        return
      }
      do {
        completionHandler(.success(try Self.metadata(from: response)))
      } catch {
        completionHandler(.failure(error))
      }
    }
    task.resume()
    return task
  }

  func cancel() {
    session?.invalidateAndCancel()
    session = nil
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }

  private static func xetAuthenticationURL(from link: String) -> URL? {
    for value in link.split(separator: ",") where value.contains("rel=\"xet-auth\"") {
      guard let start = value.firstIndex(of: "<"), let end = value[start...].firstIndex(of: ">")
      else { continue }
      let urlString = String(value[value.index(after: start)..<end])
      if let url = URL(string: urlString) {
        return url
      }
    }
    return nil
  }
}
