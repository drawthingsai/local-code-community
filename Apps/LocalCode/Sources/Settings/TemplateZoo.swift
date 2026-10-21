import Foundation
import ZIPFoundation

/// Starter files for new projects from the community templates, each published as a zip of its
/// folder's contents.
enum TemplateZoo {
  enum Error: LocalizedError {
    case invalidArchive
    case invalidIndex

    var errorDescription: String? {
      switch self {
      case .invalidArchive:
        return "The community template archive is invalid."
      case .invalidIndex:
        return "The community template index is invalid."
      }
    }
  }

  private static let baseURL = URL(string: "https://templates.drawthings.ai")!

  private struct Template: Decodable {
    var name: String
  }

  /// Downloads the names of the published templates, in the order of the index. The completion
  /// handler runs on a URL session queue.
  static func fetchTemplateNames(
    completionHandler: @escaping (Result<[String], Swift.Error>) -> Void
  ) {
    // Skip the cache so a newly added template shows up the next time the picker opens.
    let request = URLRequest(
      url: baseURL.appendingPathComponent("templates.json"),
      cachePolicy: .reloadIgnoringLocalCacheData)
    URLSession.shared.dataTask(with: request) { data, response, error in
      if let error {
        completionHandler(.failure(error))
        return
      }
      guard (response as? HTTPURLResponse)?.statusCode == 200, let data else {
        completionHandler(.failure(Error.invalidIndex))
        return
      }
      do {
        let templates = try JSONDecoder().decode([Template].self, from: data)
        completionHandler(.success(templates.map(\.name)))
      } catch {
        completionHandler(.failure(error))
      }
    }.resume()
  }

  /// Downloads the named template and extracts it into a folder, keeping its layout. A template
  /// that isn't published copies nothing. The completion handler runs on a URL session queue.
  static func copy(
    templateNamed name: String, to folderURL: URL,
    completionHandler: @escaping (Swift.Error?) -> Void
  ) {
    URLSession.shared.dataTask(with: baseURL.appendingPathComponent(name + ".zip")) {
      data, response, error in
      if let error {
        completionHandler(error)
        return
      }
      let statusCode = (response as? HTTPURLResponse)?.statusCode
      guard statusCode != 404 else {
        completionHandler(nil)
        return
      }
      guard statusCode == 200, let data, let archive = Archive(data: data, accessMode: .read)
      else {
        completionHandler(Error.invalidArchive)
        return
      }
      let folderPath = folderURL.standardizedFileURL.path + "/"
      do {
        for entry in archive where entry.type != .symlink {
          let url = folderURL.appendingPathComponent(entry.path)
          // Skip any path that would land outside the folder.
          guard url.standardizedFileURL.path.hasPrefix(folderPath) else { continue }
          _ = try archive.extract(entry, to: url)
        }
      } catch {
        completionHandler(error)
        return
      }
      completionHandler(nil)
    }.resume()
  }
}
