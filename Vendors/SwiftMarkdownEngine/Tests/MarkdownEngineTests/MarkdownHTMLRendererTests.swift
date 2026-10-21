//
//  MarkdownHTMLRendererTests.swift
//  MarkdownEngineTests
//
//  Test-first specification for the clean Markdown→HTML renderer used by the
//  editor's rich-copy path. Asserts the exact HTML fragment produced for each
//  representative construct.
//

import Foundation
import Testing

@testable import MarkdownEngine

@Suite("Markdown → HTML renderer")
struct MarkdownHTMLRendererTests {

  private func html(_ md: String) -> String { MarkdownHTMLRenderer.html(from: md) }

  @Test("core element mapping — headings, emphasis, code, link, blockquote, escaping")
  func coreElementMapping() {
    #expect(html("# Title") == "<h1>Title</h1>")
    #expect(html("*i*") == "<p><em>i</em></p>")
    #expect(html("**b**") == "<p><strong>b</strong></p>")
    #expect(html("`code`") == "<p><code>code</code></p>")
    #expect(html("[text](http://x.com)") == "<p><a href=\"http://x.com\">text</a></p>")
    #expect(html("> hello") == "<blockquote>hello</blockquote>")
    #expect(html("a < b & c > d") == "<p>a &lt; b &amp; c &gt; d</p>")
  }

  @Test("fenced code block — language class, no language, html escaping")
  func fencedCode() {
    #expect(
      html("```swift\nlet x = 1\n```")
        == "<pre><code class=\"language-swift\">let x = 1</code></pre>")
    #expect(html("```\nplain\n```") == "<pre><code>plain</code></pre>")
    #expect(html("```\n<a> & <b>\n```") == "<pre><code>&lt;a&gt; &amp; &lt;b&gt;</code></pre>")
    #expect(
      html("   ```bash\ncurl /data\n   ```")
        == "<pre><code class=\"language-bash\">curl /data</code></pre>")
    #expect(
      html("   ```\n   aaa\n    aaa\n  aaa\n   ```")
        == "<pre><code>aaa\n aaa\naaa</code></pre>")
  }

  @Test("unordered and ordered lists")
  func unorderedList() {
    #expect(html("- a\n- b") == "<ul>\n<li>a</li>\n<li>b</li>\n</ul>")
    #expect(html("1. a\n2. b") == "<ol>\n<li>a</li>\n<li>b</li>\n</ol>")
  }

  @Test("task list keeps GFM checkbox markup (rich flavors strip it)")
  func taskList() {
    #expect(
      html("- [ ] todo\n- [x] done")
        == "<ul>\n<li><input type=\"checkbox\" disabled> todo</li>\n<li><input type=\"checkbox\" checked disabled> done</li>\n</ul>"
    )
  }

  @Test("thematic break becomes hr")
  func thematicBreak() {
    #expect(html("---").contains("<hr"))
  }

  @Test("GFM table")
  func table() {
    let md = "| A | B |\n| --- | --- |\n| 1 | 2 |"
    let out = html(md)
    #expect(out.contains("<table"))
    #expect(out.contains("<th>A</th>"))
    #expect(out.contains("<th>B</th>"))
    #expect(out.contains("<td>1</td>"))
    #expect(out.contains("<td>2</td>"))
  }
}
