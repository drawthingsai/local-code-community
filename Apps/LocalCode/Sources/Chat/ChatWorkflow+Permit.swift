import BashToolContext
import Components
import Foundation
import Localization

extension ChatWorkflow {
  final class PermitDirectoryPickerResponder: UnifiedDocumentPickerControllerDelegate {
    let picked: (URL?) -> Void
    var cancellationTimer: Timer?

    init(picked: @escaping (URL?) -> Void) { self.picked = picked }

    deinit { cancellationTimer?.invalidate() }

    func documentPicker(
      _ controller: UnifiedDocumentPickerController, didPickDocumentsAt urls: [URL]
    ) {
      cancellationTimer?.invalidate()
      picked(urls.first)
    }

    func documentPickerWasCancelled(_ controller: UnifiedDocumentPickerController) {
      cancellationTimer?.invalidate()
      picked(nil)
    }
  }

  var permitDirectory: BashToolContext.PermitDirectory {
    { [weak self] requested, interaction, isCancelled, completion in
      DispatchQueue.main.async {
        guard let self else {
          completion(.failure(DirectoryPermissionError.unavailable))
          return
        }
        self._permitDirectory(
          requested, interaction: interaction, isCancelled: isCancelled, completion: completion)
      }
    }
  }

  private func _permitDirectory(
    _ requested: URL, interaction: BashUserInteraction, isCancelled: @escaping () -> Bool,
    completion: @escaping (Result<URL, Error>) -> Void
  ) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard !isCancelled() else {
      completion(.failure(DirectoryPermissionError.cancelled))
      return
    }
    do {
      try permittedDirectories.validateRequest(requested)
    } catch {
      completion(.failure(error))
      return
    }
    if permittedDirectories.contains(requested) {
      guard (try? requested.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
        completion(.failure(DirectoryPermissionError.notDirectory))
        return
      }
      completion(.success(requested))
      return
    }
    let isPresented = presentDirectoryPicker(
      at: requested, title: LocalizedString.forKey("permit_folder_access"),
      interaction: interaction,
      shouldDismiss: { [weak self] in
        isCancelled() || self?.permittedDirectories.isEnabled == false
      }
    ) { [weak self] url in
      guard let self else {
        completion(.failure(DirectoryPermissionError.unavailable))
        return
      }
      do {
        try self.permittedDirectories.validateRequest(requested)
      } catch {
        completion(.failure(error))
        return
      }
      guard let url, !isCancelled() else {
        completion(.failure(DirectoryPermissionError.cancelled))
        return
      }
      let accessed = url.startAccessingSecurityScopedResource()
      defer { if accessed { url.stopAccessingSecurityScopedResource() } }
      guard
        requested.standardizedFileURL.resolvingSymlinksInPath().path
          == url.standardizedFileURL.resolvingSymlinksInPath().path
      else {
        completion(.failure(DirectoryPermissionError.differentDirectory))
        return
      }
      do {
        try self.permittedDirectories.add(url)
        completion(.success(url))
      } catch {
        completion(.failure(error))
      }
    }
    if !isPresented {
      completion(.failure(DirectoryPermissionError.unavailable))
    }
  }

  /// Returns the app data folder for one imessage, mail or notes command, from the saved
  /// read-only grant or by asking the user when `prompt` is true. The command stops the returned
  /// security scope.
  func accessAppDataDirectory(_ directory: AppDataDirectory)
    -> BashToolContext.AccessAppDataDirectory
  {
    { [weak self] prompt, interaction, isCancelled, completion in
      DispatchQueue.main.async {
        guard let self else {
          completion(.failure(DirectoryPermissionError.unavailable))
          return
        }
        guard !isCancelled() else {
          completion(.failure(DirectoryPermissionError.cancelled))
          return
        }
        guard self.workspace.dictionary[directory.deniedKey, Bool.self] != true else {
          completion(.failure(DirectoryPermissionError.appDataDirectoryDenied(directory)))
          return
        }
        if let url = self.permittedDirectories.access(directory) {
          completion(.success(url))
          return
        }
        guard prompt else {
          completion(.failure(DirectoryPermissionError.appDataDirectoryNotGranted(directory)))
          return
        }
        let requested = directory.url
        let isPresented = self.presentDirectoryPicker(
          at: requested, title: LocalizedString.forKey("permit_folder_access"),
          interaction: interaction, shouldDismiss: isCancelled
        ) { [weak self] url in
          guard let self else {
            completion(.failure(DirectoryPermissionError.unavailable))
            return
          }
          guard let url, !isCancelled() else {
            completion(.failure(DirectoryPermissionError.cancelled))
            return
          }
          guard
            requested.standardizedFileURL.resolvingSymlinksInPath().path
              == url.standardizedFileURL.resolvingSymlinksInPath().path
          else {
            completion(.failure(DirectoryPermissionError.notAppDataDirectory(directory)))
            return
          }
          guard url.startAccessingSecurityScopedResource() else {
            completion(.failure(DirectoryPermissionError.permissionDenied))
            return
          }
          do {
            try self.permittedDirectories.set(directory, url: url)
            completion(.success(url))
          } catch {
            url.stopAccessingSecurityScopedResource()
            completion(.failure(error))
          }
        }
        if !isPresented {
          completion(.failure(DirectoryPermissionError.unavailable))
        }
      }
    }
  }

  /// Presents one folder picker at a time. `picked` receives nil when the user cancels, or when
  /// `shouldDismiss` becomes true while the picker is shown.
  private func presentDirectoryPicker(
    at directory: URL, title: String, interaction: BashUserInteraction,
    shouldDismiss: @escaping () -> Bool, picked: @escaping (URL?) -> Void
  ) -> Bool {
    guard permitDirectoryPickerResponder == nil, modelsDirectoryPickerResponder == nil,
      viewController.viewIfLoaded?.window != nil,
      presentedViewController.presentedViewController == nil
    else { return false }
    let request = interaction.begin(isUserInteraction: true)
    let picker = UnifiedDocumentPickerController(forOpeningContentTypes: [.folder])
    picker.title = title
    picker.directoryURL = directory
    picker.allowsMultipleSelection = false
    let responder = PermitDirectoryPickerResponder { [weak self] url in
      guard interaction.cancel(request) else { return }
      self?.permitDirectoryPickerResponder = nil
      picked(url)
    }
    permitDirectoryPickerResponder = responder
    picker.delegate = responder
    // A stopped Bash command must dismiss its UI before its synchronous command handler returns.
    let timer = Timer(timeInterval: 0.1, repeats: true) { [weak picker] timer in
      guard shouldDismiss() else { return }
      timer.invalidate()
      picker?.dismiss(animated: true)
    }
    responder.cancellationTimer = timer
    RunLoop.main.add(timer, forMode: .common)
    guard presentedViewController.present(picker, animated: true) else {
      responder.cancellationTimer?.invalidate()
      permitDirectoryPickerResponder = nil
      interaction.cancel(request)
      return false
    }
    return true
  }
}
