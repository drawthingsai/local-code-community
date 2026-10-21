import CryptoKit
import Foundation
import WebKit

/// Each project's cookies and other website data, shared by the browsers of all its threads.
/// From iOS 17 they are kept across launches in WebKit's store for a UUID derived from the
/// project's path, so nothing is saved to find them again, and a renamed or moved folder starts
/// a new store. Earlier, they last while the app runs.
final class BrowserDataStores {
  private var dataStores = [UUID: WKWebsiteDataStore]()
  /// WebKit's class methods for identified stores crash until something in the process has
  /// made a store, so one is made before calling them.
  private lazy var firstDataStore = WKWebsiteDataStore.nonPersistent()

  func dataStore(forProjectAt projectURL: URL) -> WKWebsiteDataStore {
    dispatchPrecondition(condition: .onQueue(.main))
    let identifier = Self.identifier(forProjectAt: projectURL)
    if let dataStore = dataStores[identifier] {
      return dataStore
    }
    let dataStore: WKWebsiteDataStore
    if #available(iOS 17.0, macCatalyst 17.0, *) {
      dataStore = WKWebsiteDataStore(forIdentifier: identifier)
    } else {
      dataStore = .nonPersistent()
    }
    dataStores[identifier] = dataStore
    return dataStore
  }

  /// Whether the project's browsers have saved a store, in this launch or an earlier one.
  func hasData(forProjectAt projectURL: URL, completion: @escaping (Bool) -> Void) {
    dispatchPrecondition(condition: .onQueue(.main))
    let identifier = Self.identifier(forProjectAt: projectURL)
    guard dataStores[identifier] == nil else {
      completion(true)
      return
    }
    if #available(iOS 17.0, macCatalyst 17.0, *) {
      _ = firstDataStore
      WKWebsiteDataStore.fetchAllDataStoreIdentifiers { identifiers in
        completion(identifiers.contains(identifier))
      }
    } else {
      completion(false)
    }
  }

  /// Signs the project's browsers out of every site; open tabs stay open.
  func removeData(forProjectAt projectURL: URL) {
    dataStore(forProjectAt: projectURL).removeData(
      ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast
    ) {}
  }

  /// Deletes the project's store once its browsers have closed.
  func delete(forProjectAt projectURL: URL) {
    dispatchPrecondition(condition: .onQueue(.main))
    let identifier = Self.identifier(forProjectAt: projectURL)
    let dataStore = dataStores.removeValue(forKey: identifier)
    guard #available(iOS 17.0, macCatalyst 17.0, *) else { return }
    _ = firstDataStore
    let deleteStore = {
      // Fails while the network process has the store open, as it does once this launch has
      // used it, leaving an empty store; its data is already gone by then.
      WKWebsiteDataStore.remove(forIdentifier: identifier) { _ in }
    }
    guard let dataStore else {
      deleteStore()
      return
    }
    dataStore.removeData(
      ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast,
      completionHandler: deleteStore)
  }

  /// A version 8 UUID from the SHA-256 of the project's path, resolved as
  /// `ProjectThreadIdentifier` resolves it.
  private static func identifier(forProjectAt projectURL: URL) -> UUID {
    let path = projectURL.standardizedFileURL.resolvingSymlinksInPath().path
    var bytes = Array(SHA256.hash(data: Data(path.utf8)).prefix(16))
    bytes[6] = (bytes[6] & 0x0F) | 0x80
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    return UUID(
      uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
      ))
  }
}
