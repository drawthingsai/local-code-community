import BashToolContext
import Foundation
import Localization
import UIKit

extension ChatWorkflow {
  var bashToolContext: BashToolContext {
    BashToolContext(
      accountProvider: settingsWorkflow.toolAccountProvider(from: viewController),
      resloveDrawThingsModelsDirectory: {
        [weak self] requested, bashUserInteraction, completion in
        DispatchQueue.main.async {
          guard let self else {
            completion(.failure(ModelDirectoryError.unavailable))
            return
          }
          self.resloveDrawThingsModelsDirectory(
            requested, bashUserInteraction: bashUserInteraction, completion: completion)
        }
      },
      modelDownloadEvent: { [weak self] event, projectURL, threadId in
        self?.handleModelDownloadEvent(event, projectURL: projectURL, threadId: threadId)
      },
      imageGenerationEvent: { [weak self] event, projectURL, threadId in
        self?.handleImageGenerationEvent(event, projectURL: projectURL, threadId: threadId)
      },
      permitDirectory: permitDirectory,
      accessMessagesDirectory: accessAppDataDirectory(.messages),
      accessMailDirectory: accessAppDataDirectory(.mail),
      accessNotesDirectory: accessAppDataDirectory(.notes),
      accessCalendar: settingsWorkflow.access(.calendar),
      accessPhotos: settingsWorkflow.access(.photos),
      requestPDFPassword: { [weak self] url, incorrectPassword, interaction, completion in
        DispatchQueue.main.async {
          guard let self,
            self.modelsDirectoryPickerResponder == nil,
            self.permitDirectoryPickerResponder == nil,
            self.viewController.viewIfLoaded?.window != nil,
            self.presentedViewController.presentedViewController == nil
          else {
            completion(nil)
            return
          }
          let request = interaction.begin(isUserInteraction: true)
          let message = LocalizedString.format(key: "pdf_password_detail", url.path)
          let alertController = UIAlertController(
            title: LocalizedString.forKey("unlock_pdf"),
            message: incorrectPassword
              ? LocalizedString.forKey("pdf_password_incorrect") + "\n\n" + message : message,
            preferredStyle: .alert)
          alertController.addTextField { textField in
            textField.isSecureTextEntry = true
            textField.placeholder = LocalizedString.forKey("password")
            textField.autocapitalizationType = .none
            textField.autocorrectionType = .no
          }
          let finish: (String?) -> Void = { [weak alertController] password in
            guard interaction.cancel(request) else { return }
            alertController?.textFields?.first?.text = nil
            // Finish dismissal before a possible retry; resume PDF work off the UI thread.
            alertController?.dismiss(animated: true) {
              DispatchQueue.global(qos: .userInitiated).async { completion(password) }
            }
          }
          alertController.addAction(
            UIAlertAction(title: LocalizedString.forKey("cancel"), style: .cancel) { _ in
              finish(nil)
            })
          alertController.addAction(
            UIAlertAction(title: LocalizedString.forKey("unlock"), style: .default) {
              [weak alertController] _ in
              finish(alertController?.textFields?.first?.text)
            })
          self.presentedViewController.present(alertController, animated: true)
        }
      },
      browseWeb: {
        [weak self] arguments, directory, projectURL, threadId, isCancelled, completion in
        DispatchQueue.main.async {
          guard let self else {
            completion(.failure(BrowserError.unavailable("The browser host is unavailable.")))
            return
          }
          self.browseWeb(
            arguments: arguments, directory: directory, projectURL: projectURL,
            threadId: threadId, isCancelled: isCancelled, completion: completion)
        }
      },
      permittedDirectoryURLs: { [permittedDirectories] in permittedDirectories.urls })
  }
}
