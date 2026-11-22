import XCTest

@testable import SwiftMath

//
//  MTBackportTests.swift
//  SwiftMathTests
//
//  Not part of upstream SwiftMath at the vendored commit: tests for \operatorname and \boldsymbol,
//  which this vendored copy takes from a later upstream commit.
//

final class MTBackportTests: XCTestCase {

  var font: MTFont!

  override func setUpWithError() throws {
    try super.setUpWithError()
    self.font = MTFontManager.fontManager.defaultFont
  }

  private func width(_ latex: String, style: MTLineStyle = .text) throws -> CGFloat {
    let list = try XCTUnwrap(MTMathListBuilder.build(fromString: latex), latex)
    return try XCTUnwrap(
      MTTypesetter.createLineForMathList(list, font: self.font, style: style), latex
    ).width
  }

  // MARK: - \operatorname

  func testOperatorname() throws {
    let list = try XCTUnwrap(MTMathListBuilder.build(fromString: "\\operatorname{softmax}(z)"))

    XCTAssertEqual(list.atoms.map { $0.type }, [.largeOperator, .open, .variable, .close])
    let op = try XCTUnwrap(list.atoms[0] as? MTLargeOperator)
    XCTAssertEqual(op.nucleus, "softmax")
    XCTAssertFalse(op.limits)
    XCTAssertEqual(MTMathListBuilder.mathListToString(list), "\\operatorname{softmax}(z)")
  }

  func testOperatornameStarTakesLimits() throws {
    let list = try XCTUnwrap(MTMathListBuilder.build(fromString: "\\operatorname*{argmax}_x"))

    XCTAssertEqual(list.atoms.count, 1)
    let op = try XCTUnwrap(list.atoms[0] as? MTLargeOperator)
    XCTAssertEqual(op.nucleus, "argmax")
    XCTAssertTrue(op.limits)
    XCTAssertEqual(op.subScript?.atoms.map { $0.nucleus }, ["x"])
    XCTAssertEqual(MTMathListBuilder.mathListToString(list), "\\operatorname*{argmax}_{x}")

    // In display style the subscript sits under the name.
    let display = try XCTUnwrap(
      MTTypesetter.createLineForMathList(list, font: self.font, style: .display))
    XCTAssertTrue(display.subDisplays.first is MTLargeOpLimitsDisplay)
  }

  func testOperatornameKeepsOnlyTheCharactersOfItsName() throws {
    // As upstream: a space command inside the name has no nucleus, so it is left out.
    let list = try XCTUnwrap(MTMathListBuilder.build(fromString: "\\operatorname*{arg\\,max}"))
    XCTAssertEqual((list.atoms[0] as? MTLargeOperator)?.nucleus, "argmax")
  }

  func testOperatornameWithoutNameIsAnError() throws {
    var error: NSError?
    XCTAssertNil(MTMathListBuilder.build(fromString: "\\operatorname{}", error: &error))
    XCTAssertEqual(error?.code, MTParseErrors.invalidCommand.rawValue)
  }

  func testOperatornameIsSetLikeABuiltInOperator() throws {
    // Same name, same class of atom: upright letters and the operator's thin spaces.
    XCTAssertEqual(
      try self.width("n\\operatorname{log}n"), try self.width("n\\log n"), accuracy: 0.001)
    // The thin spaces are there: wider than the three pieces set apart.
    XCTAssertGreaterThan(
      try self.width("n\\operatorname{foo}n"),
      try self.width("n") + self.width("\\operatorname{foo}") + self.width("n") + 1)
  }

  // MARK: - \boldsymbol

  func testBoldsymbol() throws {
    let list = try XCTUnwrap(MTMathListBuilder.build(fromString: "\\boldsymbol{x}+y"))

    XCTAssertEqual(list.atoms.map { $0.nucleus }, ["x", "+", "y"])
    XCTAssertEqual(list.atoms[0].fontStyle, .boldItalic)
    XCTAssertEqual(list.atoms[2].fontStyle, .defaultStyle)
  }

  func testBoldsymbolIsSetLikeBm() throws {
    XCTAssertEqual(
      try self.width("\\boldsymbol{\\theta}x"), try self.width("\\bm{\\theta}x"), accuracy: 0.001)
    XCTAssertNotEqual(try self.width("\\boldsymbol{x}"), try self.width("x"))
  }
}
