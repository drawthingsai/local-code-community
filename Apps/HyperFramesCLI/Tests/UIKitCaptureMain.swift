import Foundation
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
  func application(
    _ application: UIApplication, configurationForConnecting session: UISceneSession,
    options: UIScene.ConnectionOptions
  ) -> UISceneConfiguration {
    let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
    configuration.delegateClass = SceneDelegate.self
    return configuration
  }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?
  let inspector = HTMLCompositionInspector()

  func scene(
    _ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions
  ) {
    guard let scene = scene as? UIWindowScene else { return }
    let window = UIWindow(windowScene: scene)
    window.rootViewController = UIViewController()
    self.window = window
    window.makeKeyAndVisible()
    do {
      let input = URL(fileURLWithPath: CommandLine.arguments[1])
      let output = URL(fileURLWithPath: CommandLine.arguments[2])
      let zoom = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : nil
      let html = try String(contentsOf: input, encoding: .utf8)
      inspector.load(directory: input.deletingLastPathComponent(), html: html, timeout: 30) {
        result in
        do { _ = try result.get() } catch { self.fail(error) }
        self.inspector.seek(0) { result in
          do { _ = try result.get() } catch { self.fail(error) }
          self.inspector.snapshot(zoom: zoom, scale: zoom == nil ? 1 : 3) { result in
            do {
              guard let encoded = try result.get() as? String,
                let data = Data(base64Encoded: encoded)
              else { exit(2) }
              try data.write(to: output)
              self.inspector.close()
              exit(0)
            } catch { self.fail(error) }
          }
        }
      }
    } catch { fail(error) }
  }

  private func fail(_ error: Error) -> Never {
    fputs("\(error)\n", stderr)
    exit(1)
  }
}
