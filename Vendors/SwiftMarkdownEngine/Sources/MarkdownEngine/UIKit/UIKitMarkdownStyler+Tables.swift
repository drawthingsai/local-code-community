#if canImport(UIKit)
  import Foundation
  import UIKit

  extension NSAttributedString.Key {
    static let renderedTableImage = NSAttributedString.Key("RenderedTableImage")
    static let renderedTableBounds = NSAttributedString.Key("RenderedTableBounds")
    static let renderedTableSourceID = NSAttributedString.Key("RenderedTableSourceID")
  }

  extension UIKitMarkdownStyler {
    private final class WeakTableImage {
      weak var image: UIImage?

      init(_ image: UIImage) {
        self.image = image
      }
    }

    private struct TableImageKey: Hashable {
      let fontDescriptor: UIFontDescriptor
      let style: String
      let source: String
    }

    /// Rendered table images, held weakly. Streaming restyles the whole text on every update; a
    /// finished table reuses the image its text view still shows instead of rasterizing again,
    /// and the same UIImage lets the attribute diff skip past it. A table still streaming in
    /// renders once per update, so holding images strongly would pile up bitmaps nothing shows.
    /// Tables with extension or LaTeX content are not cached: an extension's attributes and a
    /// renderer's state are arbitrary, so no key can identify them.
    private static let tableImageLock = NSLock()
    private static var tableImages: [TableImageKey: WeakTableImage] = [:]
    private static var tableImagePruneCount = 64

    static func styleTables(
      tokens: [MarkdownToken],
      activeTokenIndices: Set<Int>,
      text: String,
      nsText: NSString,
      result: NSMutableAttributedString,
      baseFont: UIFont,
      configuration: MarkdownEditorConfiguration
    ) {
      guard tokens.contains(where: { $0.kind == .table }) else { return }
      let codeBackgroundColor = configuration.services.syntaxHighlighter.backgroundColor()
      let style = tableImageStyle(
        codeBackgroundColor: codeBackgroundColor, configuration: configuration)
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

        let image = tableImage(
          parsed,
          source: source,
          style: style,
          baseFont: baseFont,
          codeBackgroundColor: codeBackgroundColor,
          configuration: configuration
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

    /// Everything besides the font and the table itself that renderTable draws a table without
    /// extension or LaTeX content with. Dynamic colors resolve under the current trait collection
    /// while the table draws, so the key holds the resolved values. The extension syntax decides
    /// whether a cell has extension content at all.
    private static func tableImageStyle(
      codeBackgroundColor: UIColor,
      configuration: MarkdownEditorConfiguration
    ) -> String {
      let traitCollection = UITraitCollection.current
      func colorKey(_ color: UIColor) -> String {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard
          color.resolvedColor(with: traitCollection).getRed(
            &red, green: &green, blue: &blue, alpha: &alpha)
        else { return "\(color)" }
        return String(format: "%.4f,%.4f,%.4f,%.4f", red, green, blue, alpha)
      }
      let theme = configuration.theme
      return [
        "\(UIScreen.main.scale)",
        colorKey(theme.bodyText),
        colorKey(theme.mutedText),
        colorKey(codeBackgroundColor),
        configuration.extensionRegistry.fingerprint,
      ].joined(separator: "|")
    }

    private static func tableImage(
      _ table: MarkdownTable,
      source: String,
      style: String,
      baseFont: UIFont,
      codeBackgroundColor: UIColor,
      configuration: MarkdownEditorConfiguration
    ) -> UIImage {
      // The full descriptor, not the font name and size: font features such as monospaced
      // digits change the table's metrics.
      let key = TableImageKey(fontDescriptor: baseFont.fontDescriptor, style: style, source: source)
      tableImageLock.lock()
      let cachedImage = tableImages[key]?.image
      tableImageLock.unlock()
      if let cachedImage {
        return cachedImage
      }
      let (image, usesExtensionsOrLatex) = renderTable(
        table,
        baseFont: baseFont,
        theme: configuration.theme,
        codeBackgroundColor: codeBackgroundColor,
        latex: configuration.services.latex,
        extensions: configuration.extensions
      )
      guard !usesExtensionsOrLatex else { return image }
      tableImageLock.lock()
      tableImages[key] = WeakTableImage(image)
      // Drop entries whose images are gone once they outnumber the live ones.
      if tableImages.count > tableImagePruneCount {
        tableImages = tableImages.filter { $0.value.image != nil }
        tableImagePruneCount = max(64, tableImages.count * 2)
      }
      tableImageLock.unlock()
      return image
    }

    private static func formattedCellString(
      _ raw: String,
      baseFont: UIFont,
      header: Bool,
      paragraphStyle: NSParagraphStyle,
      theme: MarkdownEditorTheme,
      codeBackgroundColor: UIColor,
      latex: any LatexRenderer,
      extensions: [any MarkdownExtension],
      usesExtensionsOrLatex: inout Bool
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
            attributes: [
              .font: font, .foregroundColor: theme.bodyText, .paragraphStyle: paragraphStyle,
            ]))
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
            usesExtensionsOrLatex = true
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
                  .paragraphStyle: paragraphStyle,
                ]))
          case .inlineLatex(let range, let content, _):
            usesExtensionsOrLatex = true
            if let entry = latex.render(
              latex: ns.substring(with: content), fontSize: pointSize, theme: theme)
            {
              let attachment = NSTextAttachment()
              attachment.image = entry.image
              attachment.bounds = CGRect(
                x: 0, y: entry.baselineOffset,
                width: entry.size.width, height: entry.size.height)
              let attachmentString = NSMutableAttributedString(attachment: attachment)
              attachmentString.addAttribute(
                .paragraphStyle, value: paragraphStyle,
                range: NSRange(location: 0, length: attachmentString.length))
              result.append(attachmentString)
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
    ) -> (image: UIImage, usesExtensionsOrLatex: Bool) {
      let columnCount = table.alignments.count
      let cellHPadding: CGFloat = 12
      let cellVPadding: CGFloat = 6
      let borderWidth: CGFloat = 1
      let borderColor = theme.mutedText.withAlphaComponent(0.5)
      let baseLineHeight = ceil(baseFont.lineHeight)
      let minColumnContentWidth: CGFloat = 16

      // Cells carry their column's paragraph style from the start. Copying each cell to add it
      // while drawing spent most of a large table's render in Foundation's attribute interning.
      let paragraphStyles = table.alignments.map { alignment in
        let paragraph = NSMutableParagraphStyle()
        switch alignment {
        case .left: paragraph.alignment = .left
        case .center: paragraph.alignment = .center
        case .right: paragraph.alignment = .right
        }
        paragraph.lineBreakMode = .byClipping
        return paragraph
      }
      var usesExtensionsOrLatex = false
      let headerCells = table.header.prefix(columnCount).enumerated().map { col, raw in
        formattedCellString(
          raw, baseFont: baseFont, header: true, paragraphStyle: paragraphStyles[col],
          theme: theme, codeBackgroundColor: codeBackgroundColor, latex: latex,
          extensions: extensions, usesExtensionsOrLatex: &usesExtensionsOrLatex
        )
      }
      let bodyCells = table.rows.map { row in
        row.prefix(columnCount).enumerated().map { col, raw in
          formattedCellString(
            raw, baseFont: baseFont, header: false, paragraphStyle: paragraphStyles[col],
            theme: theme, codeBackgroundColor: codeBackgroundColor, latex: latex,
            extensions: extensions, usesExtensionsOrLatex: &usesExtensionsOrLatex
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
      let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
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
          let cellInnerTop = rowTop[row] + max(0, (rowHeight - lineHeight) / 2)
          cell.draw(
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
      return (image, usesExtensionsOrLatex)
    }
  }
#endif
