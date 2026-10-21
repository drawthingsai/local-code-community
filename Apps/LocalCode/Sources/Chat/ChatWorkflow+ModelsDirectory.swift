import BashToolContext
import Components
import Foundation
import Localization
import UIKit
import UniformTypeIdentifiers

enum ModelDirectoryError: Error, LocalizedError {
  case unavailable
  case cancelled
  case permissionDenied
  case differentDirectory

  var errorDescription: String? {
    switch self {
    case .unavailable:
      return "Unable to present the model folder picker. Try again from Local Code."
    case .cancelled: return "Model folder permission was cancelled."
    case .permissionDenied: return "Unable to access the selected model folder."
    case .differentDirectory: return "Select the requested model folder, or change --models-dir."
    }
  }
}

extension ChatWorkflow {
  final class ModelsDirectoryPickerResponder: UnifiedDocumentPickerControllerDelegate {
    let picked: (URL?) -> Void

    init(picked: @escaping (URL?) -> Void) { self.picked = picked }

    func documentPicker(
      _ controller: UnifiedDocumentPickerController, didPickDocumentsAt urls: [URL]
    ) {
      picked(urls.first)
    }

    func documentPickerWasCancelled(_ controller: UnifiedDocumentPickerController) {
      picked(nil)
    }
  }

  func resloveDrawThingsModelsDirectory(
    _ requested: URL?, bashUserInteraction: BashUserInteraction,
    completion: @escaping (Result<URL, Error>) -> Void
  ) {
    dispatchPrecondition(condition: .onQueue(.main))
    let bookmarkData = workspace.dictionary["draw_things_external_models_folder", Data.self]
    let localModelsDirectory = FileManager.default.urls(
      for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Models", isDirectory: true)
    if (requested == nil && bookmarkData == nil
      && workspace.dictionary["draw_things_models_in_app", Bool.self] == true)
      || requested?.standardizedFileURL.resolvingSymlinksInPath()
        == localModelsDirectory.standardizedFileURL.resolvingSymlinksInPath()
    {
      completion(.success(localModelsDirectory))
      return
    }
    if let data = bookmarkData {
      var isStale = false
      if let url = try? URL(
        resolvingBookmarkData: data,
        bookmarkDataIsStale: &isStale),
        !isStale,
        requested == nil
          || requested?.standardizedFileURL.resolvingSymlinksInPath()
            == url.standardizedFileURL.resolvingSymlinksInPath(),
        url.startAccessingSecurityScopedResource()
      {
        defer { url.stopAccessingSecurityScopedResource() }
        completion(.success(url))
        return
      }
    }

    guard modelsDirectoryPickerResponder == nil, permitDirectoryPickerResponder == nil,
      viewController.viewIfLoaded?.window != nil,
      presentedViewController.presentedViewController == nil
    else {
      completion(.failure(ModelDirectoryError.unavailable))
      return
    }
    // One interaction spans both the storage-choice alert and the folder picker.
    let request = bashUserInteraction.begin(isUserInteraction: true)
    let finish: (Result<URL, Error>) -> Void = { result in
      guard bashUserInteraction.cancel(request) else { return }
      completion(result)
    }
    let alertController = UIAlertController(
      title: LocalizedString.forKey("choose_a_models_folder"),
      message: LocalizedString.forKey("choose_a_models_folder_detail"),
      preferredStyle: .alert)
    alertController.addAction(
      UIAlertAction(
        title: LocalizedString.forKey("use_local_code_storage"), style: .default
      ) { [weak self] _ in
        guard let self else {
          finish(.failure(ModelDirectoryError.unavailable))
          return
        }
        self.workspace.dictionary["draw_things_models_in_app", Bool.self] = true
        self.workspace.dictionary["draw_things_external_models_folder", Data.self] = nil
        finish(.success(localModelsDirectory))
      })
    alertController.addAction(
      UIAlertAction(
        title: LocalizedString.forKey("choose_a_folder_on_disk_dot"), style: .default
      ) { [weak self, weak alertController] _ in
        guard let self, let alertController else {
          finish(.failure(ModelDirectoryError.unavailable))
          return
        }
        alertController.dismiss(animated: true) {
          self.selectDrawThingsModelsDirectory(requested, completion: finish)
        }
      })
    alertController.addAction(
      UIAlertAction(title: LocalizedString.forKey("cancel"), style: .cancel) { _ in
        finish(.failure(ModelDirectoryError.cancelled))
      })
    presentedViewController.present(alertController, animated: true)
  }

  private func selectDrawThingsModelsDirectory(
    _ requested: URL?, completion: @escaping (Result<URL, Error>) -> Void
  ) {
    guard modelsDirectoryPickerResponder == nil, permitDirectoryPickerResponder == nil,
      viewController.viewIfLoaded?.window != nil,
      presentedViewController.presentedViewController == nil
    else {
      completion(.failure(ModelDirectoryError.unavailable))
      return
    }
    let picker = UnifiedDocumentPickerController(forOpeningContentTypes: [.folder])
    picker.title = LocalizedString.forKey("choose_a_models_folder")
    picker.directoryURL = requested
    picker.allowsMultipleSelection = false
    let responder = ModelsDirectoryPickerResponder { [weak self] url in
      guard let self else {
        completion(.failure(ModelDirectoryError.unavailable))
        return
      }
      self.modelsDirectoryPickerResponder = nil
      guard let url else {
        completion(.failure(ModelDirectoryError.cancelled))
        return
      }
      guard url.startAccessingSecurityScopedResource() else {
        completion(.failure(ModelDirectoryError.permissionDenied))
        return
      }
      defer { url.stopAccessingSecurityScopedResource() }
      if let requested,
        requested.standardizedFileURL.resolvingSymlinksInPath()
          != url.standardizedFileURL.resolvingSymlinksInPath()
      {
        completion(.failure(ModelDirectoryError.differentDirectory))
        return
      }
      completion(.success(url))
      try? self.saveModelsDirectoryBookmark(url)
    }
    modelsDirectoryPickerResponder = responder
    picker.delegate = responder
    if !presentedViewController.present(picker, animated: true) {
      modelsDirectoryPickerResponder = nil
      completion(.failure(ModelDirectoryError.unavailable))
    }
  }

  private func saveModelsDirectoryBookmark(_ url: URL) throws {
    #if targetEnvironment(macCatalyst)
      let options: URL.BookmarkCreationOptions = .withSecurityScope
    #else
      let options: URL.BookmarkCreationOptions = .minimalBookmark
    #endif
    workspace.dictionary["draw_things_external_models_folder", Data.self] = try url.bookmarkData(
      options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
    workspace.dictionary["draw_things_models_in_app", Bool.self] = nil
  }
}
