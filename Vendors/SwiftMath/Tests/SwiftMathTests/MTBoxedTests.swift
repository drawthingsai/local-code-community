import XCTest

@testable import SwiftMath

//
//  MTBoxedTests.swift
//  SwiftMathTests
//
//  Not part of upstream SwiftMath: tests for the \boxed support in MTBoxed.swift.
//

final class MTBoxedTests: XCTestCase {

  var font: MTFont!

  override func setUpWithError() throws {
    try super.setUpWithError()
    self.font = MTFontManager.fontManager.defaultFont
  }

  private func boxedDisplay(_ latex: String, style: MTLineStyle) throws -> MTBoxedDisplay {
    let list = try XCTUnwrap(MTMathListBuilder.build(fromString: latex))
    let display = try XCTUnwrap(
      MTTypesetter.createLineForMathList(list, font: self.font, style: style))
    return try XCTUnwrap(display.subDisplays.first as? MTBoxedDisplay)
  }

  func testBuildBoxed() throws {
    let str = "\\boxed{42}"
    let list = try XCTUnwrap(MTMathListBuilder.build(fromString: str))

    XCTAssertEqual(list.atoms.count, 1)
    let boxed = try XCTUnwrap(list.atoms[0] as? MTBoxed)
    XCTAssertEqual(boxed.type, .boxed)
    XCTAssertEqual(boxed.nucleus, "")

    let subList = try XCTUnwrap(boxed.innerList)
    XCTAssertEqual(subList.atoms.map { $0.type }, [.number, .number])
    XCTAssertEqual(subList.atoms.map { $0.nucleus }, ["4", "2"])

    // convert it back to latex
    XCTAssertEqual(MTMathListBuilder.mathListToString(list), "\\boxed{42}")
  }

  func testBuildBoxedInsideExpression() throws {
    let list = try XCTUnwrap(MTMathListBuilder.build(fromString: "x=\\boxed{\\frac{a}{b}}+1"))

    XCTAssertEqual(
      list.atoms.map { $0.type }, [.variable, .relation, .boxed, .binaryOperator, .number])
    let boxed = try XCTUnwrap(list.atoms[2] as? MTBoxed)
    XCTAssertEqual(boxed.innerList?.atoms.map { $0.type }, [.fraction])
    XCTAssertEqual(MTMathListBuilder.mathListToString(list), "x=\\boxed{\\frac{a}{b}}+1")
  }

  func testBuildBoxedWithScripts() throws {
    let list = try XCTUnwrap(MTMathListBuilder.build(fromString: "\\boxed{x}^2_i"))

    XCTAssertEqual(list.atoms.count, 1)
    let boxed = try XCTUnwrap(list.atoms[0] as? MTBoxed)
    XCTAssertEqual(boxed.superScript?.atoms.map { $0.nucleus }, ["2"])
    XCTAssertEqual(boxed.subScript?.atoms.map { $0.nucleus }, ["i"])
    XCTAssertEqual(MTMathListBuilder.mathListToString(list), "\\boxed{x}^{2}_{i}")
  }

  func testBoxedRequiresArgumentToParse() throws {
    var error: NSError?
    XCTAssertNil(MTMathListBuilder.build(fromString: "\\boxed{x", error: &error))
    XCTAssertNotNil(error)
  }

  func testCopyAndFinalizeKeepInnerList() throws {
    let list = try XCTUnwrap(MTMathListBuilder.build(fromString: "\\boxed{a-b}^2"))
    let boxed = try XCTUnwrap(list.atoms[0] as? MTBoxed)

    let atomCopy: MTMathAtom = boxed.copy()
    let copy = try XCTUnwrap(atomCopy as? MTBoxed)
    XCTAssertFalse(copy === boxed)
    XCTAssertFalse(copy.innerList === boxed.innerList)
    XCTAssertEqual(copy.innerList?.atoms.map { $0.nucleus }, ["a", "\u{2212}", "b"])
    XCTAssertEqual(copy.superScript?.atoms.map { $0.nucleus }, ["2"])

    // Finalizing reaches into the box: the minus between two variables is a binary operator.
    let finalized = try XCTUnwrap(list.finalized.atoms[0] as? MTBoxed)
    XCTAssertEqual(
      finalized.innerList?.atoms.map { $0.type }, [.variable, .binaryOperator, .variable])
    XCTAssertNotNil(finalized.superScript)
  }

  func testBoxedDisplayFramesInnerList() throws {
    let boxed = try self.boxedDisplay("\\boxed{x}", style: .display)
    let inner = try XCTUnwrap(boxed.inner)

    // LaTeX: \fboxsep is 0.3em, \fboxrule is the font's bar thickness.
    XCTAssertEqual(boxed.padding, 0.3 * self.font.fontSize, accuracy: 0.001)
    XCTAssertEqual(
      boxed.lineThickness, self.font.mathTable!.overbarRuleThickness, accuracy: 0.001)
    XCTAssertGreaterThan(boxed.lineThickness, 0)

    let frame = boxed.padding + boxed.lineThickness
    XCTAssertGreaterThan(inner.width, 0)
    XCTAssertEqual(boxed.width, inner.width + 2 * frame, accuracy: 0.001)
    XCTAssertEqual(boxed.ascent, inner.ascent + frame, accuracy: 0.001)
    XCTAssertEqual(boxed.descent, inner.descent + frame, accuracy: 0.001)
    XCTAssertTrue(NSEqualRanges(boxed.range, NSMakeRange(0, 1)))

    // The inner list sits inside the frame, on the same baseline.
    XCTAssertEqual(inner.position.x - boxed.position.x, frame, accuracy: 0.001)
    XCTAssertEqual(inner.position.y, boxed.position.y, accuracy: 0.001)
  }

  func testBoxedDisplayFollowsItsPosition() throws {
    let list = try XCTUnwrap(MTMathListBuilder.build(fromString: "a+\\boxed{x}"))
    let display = try XCTUnwrap(
      MTTypesetter.createLineForMathList(list, font: self.font, style: .display))
    let boxed = try XCTUnwrap(display.subDisplays.compactMap { $0 as? MTBoxedDisplay }.first)
    let inner = try XCTUnwrap(boxed.inner)

    XCTAssertGreaterThan(boxed.position.x, 0)
    XCTAssertEqual(
      inner.position.x - boxed.position.x, boxed.padding + boxed.lineThickness, accuracy: 0.001)
    // The line is as wide as everything on it, the box included.
    XCTAssertEqual(display.width, boxed.position.x + boxed.width, accuracy: 0.001)
  }

  func testBoxedUsesDisplayStyleInText() throws {
    // amsmath: \boxed{x} is \fbox{$\displaystyle x$}.
    let inText = try self.boxedDisplay("\\boxed{\\sum_{i=1}^{n}i}", style: .text)
    let inDisplay = try self.boxedDisplay("\\boxed{\\sum_{i=1}^{n}i}", style: .display)

    XCTAssertEqual(inText.width, inDisplay.width, accuracy: 0.001)
    XCTAssertEqual(inText.ascent, inDisplay.ascent, accuracy: 0.001)
    XCTAssertEqual(inText.descent, inDisplay.descent, accuracy: 0.001)
  }

  func testBoxedInScriptStaysScriptSize() throws {
    let list = try XCTUnwrap(MTMathListBuilder.build(fromString: "\\boxed{x}"))
    let inScript = try XCTUnwrap(
      MTTypesetter.createLineForMathList(list, font: self.font, style: .script))
    let inDisplay = try XCTUnwrap(
      MTTypesetter.createLineForMathList(list, font: self.font, style: .display))

    XCTAssertLessThan(inScript.width, inDisplay.width)
    XCTAssertLessThan(inScript.ascent, inDisplay.ascent)
  }

  func testNestedAndEmptyBoxes() throws {
    let nested = try self.boxedDisplay("\\boxed{a+\\boxed{b}}", style: .display)
    let innerBox = try XCTUnwrap(
      nested.inner?.subDisplays.compactMap { $0 as? MTBoxedDisplay }.first)
    XCTAssertGreaterThan(nested.ascent, innerBox.ascent)
    XCTAssertGreaterThan(nested.width, innerBox.width)

    // An empty box is still a frame of its padding.
    let empty = try self.boxedDisplay("\\boxed{}", style: .display)
    let frame = empty.padding + empty.lineThickness
    XCTAssertEqual(empty.width, 2 * frame, accuracy: 0.001)
    XCTAssertEqual(empty.ascent, frame, accuracy: 0.001)
  }

  func testBoxedTextColorReachesInnerList() throws {
    let boxed = try self.boxedDisplay("\\boxed{x}", style: .display)
    boxed.textColor = MTColor.red
    XCTAssertEqual(boxed.inner?.textColor, MTColor.red)
  }

  func testBoxedRendersAsImage() throws {
    var plain = MathImage(
      latex: "x", fontSize: 20, textColor: MTColor.black, labelMode: .text, textAlignment: .left)
    var boxed = MathImage(
      latex: "\\boxed{x}", fontSize: 20, textColor: MTColor.black, labelMode: .text,
      textAlignment: .left)
    let (plainError, plainImage, plainLayout) = plain.asImage()
    let (boxedError, boxedImage, boxedLayout) = boxed.asImage()

    XCTAssertNil(plainError)
    XCTAssertNil(boxedError)
    let plainSize = try XCTUnwrap(plainImage).size
    let boxedSize = try XCTUnwrap(boxedImage).size
    // 0.3em of padding and a rule on each side.
    XCTAssertGreaterThan(boxedSize.width, plainSize.width + 12)
    XCTAssertGreaterThan(boxedSize.height, plainSize.height + 12)
    XCTAssertGreaterThan(
      try XCTUnwrap(boxedLayout).descent, try XCTUnwrap(plainLayout).descent + 6)
  }
}
