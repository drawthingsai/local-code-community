//Created 12/11/23
import UIKit

public protocol SettingsViewObservable {
  var isEnabled: Bool { get set }
  var isHidden: Bool { get set }
  var viewModifying: any SettingsViewModifying { get }

  func isEquivalent(to other: any SettingsViewObservable) -> Bool
}
