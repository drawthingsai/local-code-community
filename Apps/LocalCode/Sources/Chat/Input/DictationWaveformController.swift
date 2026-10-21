import SnapKit
import Style
import UIKit

/// The dictation button's face while it listens: six bars that follow the microphone's level, and
/// the stop square over the middle, which hides the fourth bar until it grows past it.
final class DictationWaveformController {
  let view: UIView

  /// Each bar's center from the middle, and how many level updates back it shows, so speech ripples
  /// out from the middle. All bars share one height range, so they rest level.
  private static let bars: [(offset: CGFloat, delay: Int)] = [
    (-10.75, 6), (-6.5, 3), (-2.25, 0), (2.25, 1), (6.5, 4), (10.75, 7),
  ]
  private static let minimumBarHeight: CGFloat = 4
  private static let maximumBarHeight: CGFloat = 24

  /// The latest levels first, each held up by the decay of the one before.
  private var levels = [CGFloat](repeating: 0, count: 8)
  private var barHeightConstraints = [Constraint]()

  private lazy var barsView: UIView = {
    let view = UIView(frame: .zero)
    // The stop square stands in an 11pt gap; the bars only show outside it.
    let path = CGMutablePath()
    path.addRect(CGRect(x: 0, y: 0, width: 40, height: 40))
    path.addRoundedRect(
      in: CGRect(x: 14.5, y: 14.5, width: 11, height: 11), cornerWidth: 3.5, cornerHeight: 3.5)
    let maskLayer = CAShapeLayer()
    maskLayer.frame = CGRect(x: 0, y: 0, width: 40, height: 40)
    maskLayer.path = path
    maskLayer.fillRule = .evenOdd
    view.layer.mask = maskLayer
    return view
  }()

  private lazy var stopView: UIView = {
    let view = UIView(frame: .zero)
    view.backgroundColor = .primaryText
    view.layer.cornerRadius = 1.5
    return view
  }()

  init() {
    view = UIView(frame: .zero)
    view.isUserInteractionEnabled = false
    view.addSubview(barsView)
    view.addSubview(stopView)
    barsView.snp.makeConstraints { make in
      make.center.equalToSuperview()
      make.width.height.equalTo(40)
    }
    for bar in Self.bars {
      let barView = UIView(frame: .zero)
      barView.backgroundColor = .colorPalette(for: .blue)
      barView.layer.cornerRadius = 1
      barsView.addSubview(barView)
      barView.snp.makeConstraints { make in
        make.centerX.equalToSuperview().offset(bar.offset)
        make.centerY.equalToSuperview()
        make.width.equalTo(2)
        barHeightConstraints.append(make.height.equalTo(Self.minimumBarHeight).constraint)
      }
    }
    stopView.snp.makeConstraints { make in
      make.center.equalToSuperview()
      make.width.height.equalTo(7)
    }
  }

  /// Takes the latest level, from 0 to 1. The bars rise with it at once and fall back gradually.
  func setLevel(_ level: Float) {
    levels.insert(max(CGFloat(level), levels[0] * 0.8), at: 0)
    levels.removeLast()
    for (bar, constraint) in zip(Self.bars, barHeightConstraints) {
      constraint.update(
        offset: Self.minimumBarHeight + (Self.maximumBarHeight - Self.minimumBarHeight)
          * levels[bar.delay])
    }
    guard view.window != nil else { return }
    let view = view
    UIView.animate(
      withDuration: 0.1, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]
    ) {
      view.layoutIfNeeded()
    }
  }

  /// Back to silence, for the next dictation.
  func reset() {
    levels = [CGFloat](repeating: 0, count: levels.count)
    for constraint in barHeightConstraints {
      constraint.update(offset: Self.minimumBarHeight)
    }
  }
}
