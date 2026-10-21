//
//  MarkdownPasteboardWriterTests.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 11.07.26.
//
//  The web archive must carry OUR html verbatim (deriving it from
//  NSAttributedString(html:) dropped <hr> and checkboxes), and the RTF path
//  substitutes visible stand-ins for what RTF cannot represent.
//

import Foundation
import Testing

@testable import MarkdownEngine

@Suite("Pasteboard writer flavors")
struct MarkdownPasteboardWriterTests {

  @Test("web archive wraps our html verbatim as its main resource")
  func webArchiveCarriesRealHTML() throws {
    let html = "<html><body><p>a</p><hr><li><input type=\"checkbox\" disabled> t</li></body></html>"
    let data = try #require(MarkdownPasteboardWriter.webArchiveData(html: html))
    let plist = try #require(
      try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    let main = try #require(plist["WebMainResource"] as? [String: Any])
    #expect(main["WebResourceMIMEType"] as? String == "text/html")
    let payload = try #require(main["WebResourceData"] as? Data)
    let roundTripped = try #require(String(data: payload, encoding: .utf8))
    #expect(roundTripped == html)  // <hr> and the checkbox survive untouched
  }

  @Test("rich flavors strip checkbox inputs to plain bullets")
  func stripCheckboxes() {
    let body =
      "<ul>\n<li><input type=\"checkbox\" disabled> open</li>\n<li><input type=\"checkbox\" checked disabled> done</li>\n</ul>"
    #expect(
      MarkdownPasteboardWriter.stripTaskCheckboxes(body)
        == "<ul>\n<li>open</li>\n<li>done</li>\n</ul>")
  }

  @Test("rtf stand-in: hr becomes a 40-char rule")
  func rtfFallbackRule() {
    let rule = String(repeating: "─", count: 40)
    #expect(
      MarkdownPasteboardWriter.rtfFallbackBody("<p>a</p>\n<hr>\n<p>b</p>")
        == "<p>a</p>\n<p>\(rule)</p>\n<p>b</p>")
  }
}
