import UIKit

@main
final class TestAppDelegate: UIResponder, UIApplicationDelegate {
  func application(
    _ application: UIApplication, configurationForConnecting session: UISceneSession,
    options: UIScene.ConnectionOptions
  ) -> UISceneConfiguration {
    let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
    configuration.delegateClass = TestSceneDelegate.self
    return configuration
  }
}

final class TestSceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?
  var exporter: HTMLVideoExporter?

  func scene(
    _ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions
  ) {
    guard let scene = scene as? UIWindowScene else { return }
    let window = UIWindow(windowScene: scene)
    window.rootViewController = UIViewController()
    self.window = window
    window.makeKeyAndVisible()
    do {
      let arguments = CommandLine.arguments
      let options = try HTMLVideoExportOptions(
        input: URL(fileURLWithPath: arguments[1]), output: URL(fileURLWithPath: arguments[2]),
        timeout: 30, alpha: arguments.contains("--alpha"))
      exporter = HTMLVideoExporter(options: options)
      exporter?.start { result in
        switch result {
        case .success(let result):
          print(String(decoding: try! JSONEncoder().encode(result), as: UTF8.self))
          exit(0)
        case .failure(let error):
          fputs(error.localizedDescription + "\n", stderr)
          exit(1)
        }
      }
    } catch {
      fputs(error.localizedDescription + "\n", stderr)
      exit(1)
    }
  }
}
