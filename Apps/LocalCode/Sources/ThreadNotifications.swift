import Localization
import UIKit
import UserNotifications

// Owned by ChatWorkflow; notification requests and permission state stay on the main queue.
final class ThreadNotifications {
  var pendingNotification: (response: UNNotificationResponse, identifier: String)? = nil
  private let center = UNUserNotificationCenter.current()
  private var isRequestingAuthorization = false
  private var pendingCompletions = [String: String]()

  func requestAuthorizationIfNeeded() {
    guard !isRequestingAuthorization, UIApplication.shared.applicationState == .active else {
      return
    }
    isRequestingAuthorization = true
    center.getNotificationSettings { settings in
      DispatchQueue.main.async {
        guard settings.authorizationStatus == .notDetermined,
          UIApplication.shared.applicationState == .active
        else {
          self.isRequestingAuthorization = false
          return
        }
        self.center.requestAuthorization(options: [.alert, .sound]) { _, error in
          if let error {
            print("Unable to request thread notifications: %@", error.localizedDescription)
          }
          DispatchQueue.main.async { self.isRequestingAuthorization = false }
        }
      }
    }
  }

  private static func identifier(projectPath: String, threadId: Int64) -> String {
    "thread-completed.\(Data(projectPath.utf8).base64EncodedString()).\(threadId)"
  }

  func notify(projectURL: URL, threadId: Int64, title: String, duration: TimeInterval) {
    dispatchPrecondition(condition: .onQueue(.main))
    let projectPath = projectURL.standardizedFileURL.resolvingSymlinksInPath().path
    let content = UNMutableNotificationContent()
    content.title = title.isEmpty ? LocalizedString.forKey("thread_completed_title") : title
    content.body = LocalizedString.format(
      key: "thread_completed_body", formatElapsedTime(duration))
    content.sound = .default
    let completionIdentifier = UUID().uuidString
    content.userInfo = [
      "project_path": projectPath, "thread_id": String(threadId),
      "completionIdentifier": completionIdentifier,
    ]
    let identifier = Self.identifier(projectPath: projectPath, threadId: threadId)
    content.threadIdentifier = identifier
    pendingCompletions[identifier] = completionIdentifier
    center.getNotificationSettings { settings in
      DispatchQueue.main.async {
        // Opening the thread or completing a newer turn invalidates this pending delivery.
        guard self.pendingCompletions[identifier] == completionIdentifier else { return }
        self.pendingCompletions.removeValue(forKey: identifier)
        guard
          settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
        else { return }
        self.center.add(
          UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        ) { error in
          if let error {
            print("Unable to deliver thread notification: %@", error.localizedDescription)
          }
        }
      }
    }
  }

  func clear(projectPath: String, threadId: Int64) {
    let identifier = Self.identifier(projectPath: projectPath, threadId: threadId)
    pendingCompletions.removeValue(forKey: identifier)
    center.removePendingNotificationRequests(withIdentifiers: [identifier])
    center.removeDeliveredNotifications(withIdentifiers: [identifier])
  }

}
