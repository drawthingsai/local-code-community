import UIKit

// This class converts button pressing action (touchDownInside, touchUpInside, touchUpOutside, touchCancel) into isSelected state of the button itself.
public class ButtonPressStateController {

  private weak var button: UIButton? = nil
  private var isSelectedSentinel: Int = 0
  private var isSelectedTiming: CFTimeInterval = 0

  public init(_ button: UIButton) {
    self.button = button
    button.addAction(
      UIAction { [weak self] _ in
        guard let self = self, let button = self.button else { return }
        button.isSelected = true
        self.isSelectedSentinel += 1
        self.isSelectedTiming = CACurrentMediaTime()
      }, for: .touchDown)
    button.addAction(
      UIAction { [weak self] _ in
        guard let self = self, let button = self.button else { return }
        // Reset the state back, but with a delay if we are within 100ms of selected.
        let currentMediaTime = CACurrentMediaTime()
        if currentMediaTime - self.isSelectedTiming >= 0.1 {
          button.isSelected = false
        } else {
          let isSelectedSentinel = self.isSelectedSentinel
          DispatchQueue.main.asyncAfter(
            deadline: .now()
              + .milliseconds(
                100 - Int((1000 * (currentMediaTime - self.isSelectedTiming)).rounded(.down)))
          ) {
            guard isSelectedSentinel == self.isSelectedSentinel else {
              return
            }
            button.isSelected = false
          }
        }
      }, for: [.touchUpInside, .touchUpOutside, .touchCancel])
  }
}
