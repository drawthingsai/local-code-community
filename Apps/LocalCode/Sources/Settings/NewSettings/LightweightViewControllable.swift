import UIKit

protocol LightweightViewControllable: AnyObject {
  var view: UIView { get }
  func loadViewIfNeeded()
}
