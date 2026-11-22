//
//  MTBoxed.swift
//  SwiftMath
//
//  Not part of upstream SwiftMath: \boxed support added in this vendored copy. Everything specific
//  to \boxed lives in this file. The hooks in upstream files are the `boxed` atom type and its
//  `copy()` case (MTMathList.swift), the command and its string form (MTMathListBuilder.swift),
//  and the `.boxed` case of the typesetter's main loop (MTTypesetter.swift).
//

import CoreGraphics
import Foundation

// MARK: - MTBoxed

/// An atom with a frame around the contained math list, as `\boxed` from amsmath.
public class MTBoxed: MTMathAtom {
  public var innerList: MTMathList?

  init(_ boxed: MTBoxed?) {
    super.init(boxed)
    self.type = .boxed
    self.innerList = MTMathList(boxed?.innerList)
  }

  override init() {
    super.init()
    self.type = .boxed
  }

  public override var string: String {
    var str = "\\boxed{\(self.innerList?.string ?? "")}"
    if let superScript = self.superScript {
      str.append("^{\(superScript.string)}")
    }
    if let subScript = self.subScript {
      str.append("_{\(subScript.string)}")
    }
    return str
  }

  override public var finalized: MTMathAtom {
    let newBoxed = super.finalized as! MTBoxed
    newBoxed.innerList = newBoxed.innerList?.finalized
    return newBoxed
  }
}

// MARK: - MTBoxedDisplay

/// Rendering of a list with a frame around it.
class MTBoxedDisplay: MTDisplay {

  /** A display representing the inner list that is framed. Its position is relative
     to the parent is not treated as a sub-display.
     */
  var inner: MTMathListDisplay?
  /// The distance between the frame and the inner list, on every side.
  var padding: CGFloat = 0
  var lineThickness: CGFloat = 0

  init(withInner inner: MTMathListDisplay?, position: CGPoint, range: NSRange) {
    super.init()
    self.inner = inner

    self.position = position
    self.range = range
  }

  override var textColor: MTColor? {
    set {
      super.textColor = newValue
      inner?.textColor = newValue
    }
    get { super.textColor }
  }

  override var position: CGPoint {
    set {
      super.position = newValue
      self.updateInnerPosition()
    }
    get { super.position }
  }

  override func draw(_ context: CGContext) {
    super.draw(context)
    guard let inner = self.inner else { return }
    inner.draw(context)

    context.saveGState()

    if let textColor = self.textColor {
      context.setStrokeColor(textColor.cgColor)
    }
    context.setLineWidth(self.lineThickness)
    // The frame is measured from the inner list, as MTLineDisplay measures its line.
    let outset = self.padding + self.lineThickness / 2
    context.stroke(
      CGRectMake(
        inner.position.x - outset, inner.position.y - inner.descent - outset,
        inner.width + 2 * outset, inner.ascent + inner.descent + 2 * outset))

    context.restoreGState()
  }

  func updateInnerPosition() {
    self.inner?.position = CGPointMake(
      self.position.x + self.lineThickness + self.padding, self.position.y)
  }
}

// MARK: - Typesetting

extension MTTypesetter {
  func makeBoxed(_ boxed: MTBoxed?) -> MTDisplay? {
    guard let boxed = boxed else { return nil }
    // amsmath defines \boxed{x} as \fbox{$\displaystyle x$}. Scripts keep their own style, so a
    // box in a superscript stays the size of the superscript.
    let innerStyle: MTLineStyle = style == .text ? .display : style
    let innerListDisplay =
      MTTypesetter.createLineForMathList(
        boxed.innerList, font: font, style: innerStyle, cramped: cramped)
      ?? MTMathListDisplay(withDisplays: [], range: boxed.indexRange)
    let boxedDisplay = MTBoxedDisplay(
      withInner: innerListDisplay, position: currentPosition, range: boxed.indexRange)
    // LaTeX frames with \fboxsep = 3pt and \fboxrule = 0.4pt at 10pt, that is 0.3em and 0.04em.
    // The font's bar thickness is that same 0.04em.
    boxedDisplay.padding = 0.3 * styleFont.fontSize
    boxedDisplay.lineThickness = styleFont.mathTable!.overbarRuleThickness
    let frame = boxedDisplay.padding + boxedDisplay.lineThickness
    boxedDisplay.ascent = innerListDisplay.ascent + frame
    boxedDisplay.descent = innerListDisplay.descent + frame
    boxedDisplay.width = innerListDisplay.width + 2 * frame
    boxedDisplay.updateInnerPosition()
    return boxedDisplay
  }
}
