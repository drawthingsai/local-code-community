#if canImport(UIKit)
  import Foundation
  import UIKit

  extension NSAttributedString.Key {
    static let renderedTableImage = NSAttributedString.Key("RenderedTableImage")
    static let renderedTableBounds = NSAttributedString.Key("RenderedTableBounds")
    static let renderedTableSourceID = NSAttributedString.Key("RenderedTableSourceID")
  }

  extension UIKitMarkdownStyler {
    static func styleTables(
      tokens: [MarkdownToken],
      activeTokenIndices: Set<Int>,
      text: String,
      nsText: NSString,
      result: NSMutableAttributedString,
      baseFont: UIFont,
      configuration: MarkdownEditorConfiguration
    ) {
      var occurrenceByContentHash: [Int: Int] = [:]
      for (idx, token) in tokens.enumerated() where token.kind == .table {
        let source = nsText.substring(with: token.range)
        guard let parsed = MarkdownTableParser.parse(source) else { continue }

        let contentHash = MarkdownTableParser.stableContentHash(for: source)
        let occurrenceIndex = occurrenceByContentHash[contentHash, default: 0]
        occurrenceByContentHash[contentHash] = occurrenceIndex + 1

        if activeTokenIndices.contains(idx) {
          add(
            [.foregroundColor: configuration.theme.bodyText, .font: baseFont],
            token.range,
            result
          )
          if let pipeRegex = try? NSRegularExpression(pattern: "\\|") {
            for match in pipeRegex.matches(in: text, options: [], range: token.range) {
              add([.foregroundColor: configuration.theme.mutedText], match.range, result)
            }
          }
          continue
        }

        let image = renderTable(
          parsed,
          baseFont: baseFont,
          theme: configuration.theme,
          codeBackgroundColor: configuration.services.syntaxHighlighter.backgroundColor(),
          latex: configuration.services.latex,
          extensions: configuration.extensions
        )
        guard let anchorLocation = firstVisibleContentLocation(in: token.contentRange, text: nsText)
        else { continue }

        let paragraphRange = nsText.paragraphRange(for: token.range)
        let imageBounds = CGRect(origin: .zero, size: image.size)
        let tableParagraph = NSMutableParagraphStyle()
        tableParagraph.minimumLineHeight = max(ceil(baseFont.lineHeight), image.size.height)
        tableParagraph.maximumLineHeight = tableParagraph.minimumLineHeight
        tableParagraph.paragraphSpacingBefore = ceil(baseFont.lineHeight * 0.5)
        tableParagraph.paragraphSpacing = ceil(baseFont.lineHeight * 0.5)
        tableParagraph.lineBreakMode = .byClipping

        let collapsedParagraph = NSMutableParagraphStyle()
        collapsedParagraph.minimumLineHeight = MarkdownLayoutMetrics.collapsedSourceLineHeight
        collapsedParagraph.maximumLineHeight = MarkdownLayoutMetrics.collapsedSourceLineHeight
        collapsedParagraph.paragraphSpacing = 0
        collapsedParagraph.paragraphSpacingBefore = 0

        var paragraphLocation = paragraphRange.location
        let paragraphEnd = NSMaxRange(paragraphRange)
        while paragraphLocation < paragraphEnd {
          let currentParagraph = nsText.paragraphRange(
            for: NSRange(location: paragraphLocation, length: 0))
          let boundedParagraph = NSIntersectionRange(currentParagraph, paragraphRange)
          if boundedParagraph.length > 0 {
            let style =
              NSLocationInRange(anchorLocation, boundedParagraph)
              ? tableParagraph : collapsedParagraph
            add([.paragraphStyle: style], boundedParagraph, result)
          }
          let nextLocation = NSMaxRange(currentParagraph)
          paragraphLocation =
            nextLocation > paragraphLocation ? nextLocation : paragraphLocation + 1
        }

        let hiddenFont = UIFont.systemFont(ofSize: configuration.markers.hiddenMarkerFontSize)
        add([.foregroundColor: UIColor.clear, .font: hiddenFont], token.range, result)

        let anchorRange = NSRange(location: anchorLocation, length: 1)
        let anchorText = nsText.substring(with: anchorRange)
        add(
          [
            .renderedTableImage: image,
            .renderedTableBounds: NSValue(cgRect: imageBounds),
            .renderedTableSourceID: MarkdownTableParser.stableSourceID(
              for: source, occurrenceIndex: occurrenceIndex),
            .foregroundColor: UIColor.clear,
            .font: hiddenFont,
            .kern: imageBounds.width - textWidth(anchorText, font: hiddenFont),
          ],
          anchorRange,
          result
        )
      }
    }

    private static func add(
      _ attrs: [NSAttributedString.Key: Any],
      _ range: NSRange,
      _ result: NSMutableAttributedString
    ) {
      guard range.location >= 0, NSMaxRange(range) <= result.length, range.length > 0 else {
        return
      }
      result.addAttributes(attrs, range: range)
    }

    private static func firstVisibleContentLocation(in range: NSRange, text: NSString) -> Int? {
      guard range.length > 0 else { return nil }
      for offset in 0..<range.length {
        let location = range.location + offset
        let scalar = UnicodeScalar(text.character(at: location))
        if let scalar, !CharacterSet.whitespacesAndNewlines.contains(scalar) {
          return location
        }
      }
      return nil
    }

    private static func formattedCellString(
      _ raw: String,
      baseFont: UIFont,
      header: Bool,
      theme: MarkdownEditorTheme,
      codeBackgroundColor: UIColor,
      latex: any LatexRenderer,
      extensions: [any MarkdownExtension]
    ) -> NSAttributedString {
      let pointSize = baseFont.pointSize
      let codeFont = UIFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)
      let headerTraits: UIFontDescriptor.SymbolicTraits = header ? .traitBold : []
      let startFont =
        baseFont.fontDescriptor.withSymbolicTraits(headerTraits).map {
          UIFont(descriptor: $0, size: pointSize)
        } ?? baseFont
      let result = NSMutableAttributedString(string: "")
      let ns = raw as NSString
      var extensionsByID: [String: any MarkdownExtension] = [:]
      for markdownExtension in extensions {
        extensionsByID[markdownExtension.id] = markdownExtension
      }

      func composeEmphasis(_ current: UIFont, _ kind: EmphasisKind) -> UIFont {
        var traits = current.fontDescriptor.symbolicTraits.intersection([.traitBold, .traitItalic])
        switch kind {
        case .bold: traits.insert(.traitBold)
        case .italic: traits.insert(.traitItalic)
        case .boldItalic: traits.formUnion([.traitBold, .traitItalic])
        }
        return current.fontDescriptor.withSymbolicTraits(traits).map {
          UIFont(descriptor: $0, size: pointSize)
        } ?? current
      }

      func appendPlain(_ range: NSRange, font: UIFont) {
        result.append(
          NSAttributedString(
            string: ns.substring(with: range),
            attributes: [.font: font, .foregroundColor: theme.bodyText]))
      }

      func append(_ nodes: [InlineNode], font: UIFont) {
        for node in nodes {
          switch node {
          case .text(let range):
            appendPlain(range, font: font)
          case .escape(_, let character, _):
            appendPlain(character, font: font)
          case .emphasis(let kind, _, _, let children):
            append(children, font: composeEmphasis(font, kind))
          case .ext(let node):
            let start = result.length
            if node.children.isEmpty {
              appendPlain(node.contentRange, font: font)
            } else {
              append(node.children, font: font)
            }
            if result.length > start, let markdownExtension = extensionsByID[node.extensionID] {
              result.addAttributes(
                markdownExtension.contentAttributes(theme: theme),
                range: NSRange(location: start, length: result.length - start))
            }
          case .code(_, let content):
            result.append(
              NSAttributedString(
                string: ns.substring(with: content),
                attributes: [
                  .font: codeFont,
                  .backgroundColor: codeBackgroundColor,
                  .foregroundColor: theme.bodyText,
                ]))
          case .inlineLatex(let range, let content, _):
            if let entry = latex.render(
              latex: ns.substring(with: content), fontSize: pointSize, theme: theme)
            {
              let attachment = NSTextAttachment()
              attachment.image = entry.image
              attachment.bounds = CGRect(
                x: 0, y: entry.baselineOffset,
                width: entry.size.width, height: entry.size.height)
              result.append(NSAttributedString(attachment: attachment))
            } else {
              appendPlain(range, font: font)
            }
          case .link(let range, _, _, _, _),
            .image(let range, _, _, _),
            .wikiLink(let range, _, _, _),
            .imageEmbed(let range, _, _):
            appendPlain(range, font: font)
          }
        }
      }

      append(
        InlineParser.parse(raw, registry: ExtensionRegistry(extensions: extensions)),
        font: startFont)
      return result
    }

    private static func renderTable(
      _ table: MarkdownTable,
      baseFont: UIFont,
      theme: MarkdownEditorTheme,
      codeBackgroundColor: UIColor,
      latex: any LatexRenderer,
      extensions: [any MarkdownExtension]
    ) -> UIImage {
      let columnCount = table.alignments.count
      let cellHPadding: CGFloat = 12
      let cellVPadding: CGFloat = 6
      let borderWidth: CGFloat = 1
      let borderColor = theme.mutedText.withAlphaComponent(0.5)
      let baseLineHeight = ceil(baseFont.lineHeight)
      let minColumnContentWidth: CGFloat = 16

      let headerCells = table.header.map {
        formattedCellString(
          $0, baseFont: baseFont, header: true, theme: theme,
          codeBackgroundColor: codeBackgroundColor, latex: latex, extensions: extensions
        )
      }
      let bodyCells = table.rows.map { row in
        row.map {
          formattedCellString(
            $0, baseFont: baseFont, header: false, theme: theme,
            codeBackgroundColor: codeBackgroundColor, latex: latex, extensions: extensions
          )
        }
      }

      var columnWidths = [CGFloat](repeating: minColumnContentWidth, count: columnCount)
      var maxCellHeight = baseLineHeight
      func considerCell(_ cell: NSAttributedString, col: Int) {
        let size = cell.size()
        columnWidths[col] = max(columnWidths[col], ceil(size.width))
        maxCellHeight = max(maxCellHeight, ceil(size.height))
      }
      for (i, cell) in headerCells.enumerated() where i < columnCount {
        considerCell(cell, col: i)
      }
      for row in bodyCells {
        for (i, cell) in row.enumerated() where i < columnCount {
          considerCell(cell, col: i)
        }
      }

      let lineHeight = max(baseLineHeight, maxCellHeight)
      let rowCount = 1 + table.rows.count
      let totalWidth =
        columnWidths.reduce(0, +)
        + CGFloat(columnCount) * 2 * cellHPadding
        + CGFloat(columnCount + 1) * borderWidth
      let rowHeight = lineHeight + 2 * cellVPadding
      let totalHeight = CGFloat(rowCount) * rowHeight + CGFloat(rowCount + 1) * borderWidth
      let size = CGSize(width: totalWidth, height: totalHeight)

      var columnLeft = [CGFloat](repeating: 0, count: columnCount + 1)
      columnLeft[0] = borderWidth
      for i in 0..<columnCount {
        columnLeft[i + 1] = columnLeft[i] + columnWidths[i] + 2 * cellHPadding + borderWidth
      }
      var rowTop = [CGFloat](repeating: 0, count: rowCount + 1)
      rowTop[0] = borderWidth
      for i in 0..<rowCount {
        rowTop[i + 1] = rowTop[i] + rowHeight + borderWidth
      }

      let format = UIGraphicsImageRendererFormat()
      format.opaque = false
      format.scale = UIScreen.main.scale
      return UIGraphicsImageRenderer(size: size, format: format).image { _ in
        theme.mutedText.withAlphaComponent(0.08).setFill()
        UIBezierPath(
          rect: CGRect(
            x: borderWidth,
            y: borderWidth,
            width: size.width - 2 * borderWidth,
            height: rowHeight
          )
        ).fill()

        borderColor.setStroke()
        let outer = UIBezierPath(
          rect: CGRect(
            x: borderWidth / 2,
            y: borderWidth / 2,
            width: size.width - borderWidth,
            height: size.height - borderWidth
          ))
        outer.lineWidth = borderWidth
        outer.stroke()

        let separators = UIBezierPath()
        separators.lineWidth = borderWidth
        for i in 1..<columnCount {
          let x = columnLeft[i] - borderWidth / 2
          separators.move(to: CGPoint(x: x, y: 0))
          separators.addLine(to: CGPoint(x: x, y: size.height))
        }
        for i in 1..<rowCount {
          let y = rowTop[i] - borderWidth / 2
          separators.move(to: CGPoint(x: 0, y: y))
          separators.addLine(to: CGPoint(x: size.width, y: y))
        }
        separators.stroke()

        func drawCell(_ cell: NSAttributedString, col: Int, row: Int) {
          guard col < columnCount else { return }
          let cellLeft = columnLeft[col] + cellHPadding
          let cellRight = columnLeft[col + 1] - borderWidth - cellHPadding
          let availableWidth = cellRight - cellLeft
          let paragraph = NSMutableParagraphStyle()
          switch table.alignments[col] {
          case .left: paragraph.alignment = .left
          case .center: paragraph.alignment = .center
          case .right: paragraph.alignment = .right
          }
          paragraph.lineBreakMode = .byClipping
          let aligned = NSMutableAttributedString(attributedString: cell)
          aligned.addAttribute(
            .paragraphStyle,
            value: paragraph,
            range: NSRange(location: 0, length: aligned.length)
          )
          let cellInnerTop = rowTop[row] + max(0, (rowHeight - lineHeight) / 2)
          aligned.draw(
            with: CGRect(
              x: cellLeft,
              y: cellInnerTop,
              width: availableWidth,
              height: lineHeight
            ),
            options: [.usesLineFragmentOrigin],
            context: nil
          )
        }

        for (col, cell) in headerCells.enumerated() {
          drawCell(cell, col: col, row: 0)
        }
        for (rowIdx, row) in bodyCells.enumerated() {
          for (col, cell) in row.enumerated() {
            drawCell(cell, col: col, row: rowIdx + 1)
          }
        }
      }
    }
  }
#endif
