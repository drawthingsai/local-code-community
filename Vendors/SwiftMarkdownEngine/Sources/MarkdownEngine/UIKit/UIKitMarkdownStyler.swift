#if canImport(UIKit)
  import Foundation
  import UIKit

  extension NSAttributedString.Key {
    static let thematicBreak = NSAttributedString.Key("ThematicBreak")
    static let markdownVideoURL = NSAttributedString.Key("MarkdownVideoURL")
    static let markdownHTMLURL = NSAttributedString.Key("MarkdownHTMLURL")
    static let markdownImageBlock = NSAttributedString.Key("MarkdownImageBlock")
  }

  enum UIKitMarkdownStyler {
    // UITextView.dataDetectorTypes does not run while the view is editable, so mirror the
    // AppKit styler's manual, cached detector pass and attach links to the attributed string.
    private static let autoLinkDetector = try? NSDataDetector(
      types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func attributedString(
      text: String,
      fontName: String,
      fontSize: CGFloat,
      baseFont suppliedBaseFont: UIFont? = nil,
      selectionRange: NSRange,
      selectionSuppressed: Bool = false,
      availableWidth: CGFloat? = nil,
      wikiLinkIDProvider: (NSRange) -> String?,
      precomputedTokens: [MarkdownToken]? = nil,
      precomputedBlocks: [Block]? = nil,
      configuration: MarkdownEditorConfiguration
    ) -> NSAttributedString {
      let nsText = text as NSString
      let fullRange = NSRange(location: 0, length: nsText.length)
      let extensionRegistry = configuration.extensionRegistry
      let tokens =
        precomputedTokens
        ?? MarkdownTokenizer.parseTokensViaAST(in: text, registry: extensionRegistry)
      let autoLinkRanges =
        configuration.link.automaticLinkDetectionEnabled
        ? MarkdownTokenizer.autoLinkRangesViaAST(
          in: text, precomputedBlocks: precomputedBlocks, registry: extensionRegistry)
        : []
      let codeTokens = tokens.filter { $0.kind == .codeBlock || $0.kind == .inlineCode }
      let tableTokens = tokens.filter { $0.kind == .table }
      let activeTokenIndices = MarkdownDetection.computeActiveTokenIndices(
        selectionRange: selectionRange,
        tokens: tokens,
        in: nsText,
        suppressed: selectionSuppressed
      )
      let baseFont = suppliedBaseFont ?? font(named: fontName, size: fontSize)
      let paragraph = baseParagraphStyle(font: baseFont, configuration: configuration)
      let result = NSMutableAttributedString(
        string: text,
        attributes: [
          .font: baseFont,
          .foregroundColor: configuration.theme.bodyText,
          .paragraphStyle: paragraph,
        ]
      )

      func add(_ attrs: [NSAttributedString.Key: Any], range: NSRange) {
        guard range.location >= 0, NSMaxRange(range) <= result.length, range.length > 0 else {
          return
        }
        result.addAttributes(attrs, range: range)
      }

      func addMarkers(_ token: MarkdownToken, color: UIColor? = nil) {
        let markerColor = color ?? configuration.theme.mutedText
        for range in token.markerRanges {
          add([.foregroundColor: markerColor], range: range)
        }
      }

      let separatorParagraph = NSMutableParagraphStyle()
      let separatorLineHeight = max(1, ceil(baseFont.lineHeight * 0.5))
      separatorParagraph.minimumLineHeight = separatorLineHeight
      separatorParagraph.maximumLineHeight = separatorLineHeight
      separatorParagraph.paragraphSpacing = 0
      separatorParagraph.paragraphSpacingBefore = 0
      let separatorRegex = try! NSRegularExpression(
        pattern: #"^[ \t]*\r?\n"#,
        options: [.anchorsMatchLines]
      )
      for match in separatorRegex.matches(in: text, options: [], range: fullRange) {
        if codeTokens.contains(where: { NSIntersectionRange($0.range, match.range).length > 0 }) {
          continue
        }
        add([.paragraphStyle: separatorParagraph], range: match.range)
      }

      let horizontalRuleRegex = try! NSRegularExpression(
        pattern: #"^[ \t]*(-{3,}|\*{3,}|_{3,})[ \t]*$"#,
        options: [.anchorsMatchLines]
      )
      for match in horizontalRuleRegex.matches(in: text, options: [], range: fullRange) {
        let caretIsOnRuleLine =
          !selectionSuppressed && selectionRange.length == 0
          && (NSLocationInRange(selectionRange.location, match.range)
            || selectionRange.location == NSMaxRange(match.range))
        if caretIsOnRuleLine { continue }
        add(
          [
            .foregroundColor: UIColor.clear,
            .thematicBreak: true,
            .paragraphStyle: NSMutableParagraphStyle(),
          ],
          range: match.range)
      }

      styleTables(
        tokens: tokens,
        activeTokenIndices: activeTokenIndices,
        text: text,
        nsText: nsText,
        result: result,
        baseFont: baseFont,
        configuration: configuration
      )

      for (index, token) in tokens.enumerated() {
        if token.kind != .codeBlock && token.kind != .inlineCode
          && isFullyInsideCode(token.range, codeTokens: codeTokens)
        {
          continue
        }
        if token.kind != .table
          && tableTokens.contains(where: {
            token.range.location >= $0.range.location
              && NSMaxRange(token.range) <= NSMaxRange($0.range)
          })
        {
          continue
        }
        let isActive = activeTokenIndices.contains(index)

        switch token.kind {
        case .heading:
          let level = token.markerRanges.first?.length ?? 1
          let headingSize = fontSize * configuration.headings.fontMultiplier(for: level)
          let headingFont = font(basedOn: baseFont, size: headingSize, traits: .traitBold)
          let headingParagraph = baseParagraphStyle(font: headingFont, configuration: configuration)
          headingParagraph.paragraphSpacingBefore =
            headingFont.pointSize * configuration.headings.topSpacingEm(for: level)
          add([.font: headingFont, .paragraphStyle: headingParagraph], range: token.range)
          add(
            [.foregroundColor: configuration.theme.headingMarker],
            range: token.markerRanges.first ?? token.range)

        case .bold:
          add(
            [.font: font(basedOn: baseFont, size: fontSize, traits: .traitBold)],
            range: token.contentRange)
          addMarkers(token)

        case .italic:
          add(
            [.font: font(basedOn: baseFont, size: fontSize, traits: .traitItalic)],
            range: token.contentRange)
          addMarkers(token)

        case .boldItalic:
          add(
            [
              .font: font(
                basedOn: baseFont, size: fontSize, traits: [.traitBold, .traitItalic])
            ],
            range: token.contentRange
          )
          addMarkers(token)

        case .extensionSpan(let identifier), .extensionBlock(let identifier):
          if let markdownExtension = configuration.extensions.first(where: {
            $0.id == identifier
          }) {
            add(
              markdownExtension.contentAttributes(theme: configuration.theme),
              range: token.contentRange
            )
          }
          addMarkers(token)

        case .link:
          styleMarkdownLink(
            token, isActive: isActive, text: nsText, result: result, configuration: configuration)

        case .wikiLink:
          let name = nsText.substring(with: token.contentRange)
          let resolution = configuration.services.wikiLinks.resolve(
            displayName: name, range: token.contentRange)
          let linkID = wikiLinkIDProvider(token.range) ?? resolution?.id
          var attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: configuration.theme.link,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
          ]
          if let linkID {
            attrs[.wikiLinkID] = linkID
          }
          if !isActive {
            if resolution?.exists == true {
              var components = URLComponents()
              components.scheme = "markdownengine-wikilink"
              components.host = "open"
              components.path = "/\(linkID ?? name)"
              attrs[.link] = components.url ?? URL(string: "markdownengine-wikilink://open")!
            } else {
              attrs[.foregroundColor] = configuration.theme.disabledText
              attrs.removeValue(forKey: .underlineStyle)
            }
          }
          add(attrs, range: token.contentRange)
          addMarkers(token)

        case .codeBlock:
          let codeFont = configuration.services.syntaxHighlighter.codeFont(
            size: round(fontSize * configuration.codeBlock.fontSizeScale)
          )
          let content = BacktickFence.contentProjection(forCodeBlock: token, in: nsText)
          let codeParagraph = codeParagraphStyle(font: codeFont, configuration: configuration)
          add(
            [
              .font: codeFont,
              .backgroundColor: configuration.services.syntaxHighlighter.backgroundColor(),
              .paragraphStyle: codeParagraph,
              .codeBlockBackground: true,
            ],
            range: token.range
          )
          if let highlighted = configuration.services.syntaxHighlighter.highlight(
            code: content.text,
            language: MarkdownTokenizer.extractLanguage(from: token, in: text)
          ) {
            highlighted.enumerateAttributes(in: NSRange(location: 0, length: highlighted.length)) {
              attrs, range, _ in
              guard let color = attrs[.foregroundColor] else { return }
              for sourceRange in content.sourceRanges(for: range) {
                add([.foregroundColor: color], range: sourceRange)
              }
            }
          }
          addMarkers(token, color: isActive ? configuration.theme.mutedText : .clear)
          if !isActive {
            let hiddenFont = font(
              basedOn: baseFont, size: configuration.markers.hiddenMarkerFontSize)
            for range in content.removedIndentRanges {
              add([.font: hiddenFont, .kern: -hiddenFont.pointSize], range: range)
            }
          }

        case .inlineCode:
          let inheritedFont =
            result.attribute(.font, at: token.contentRange.location, effectiveRange: nil) as? UIFont
            ?? baseFont
          let codeFont = inlineCodeFont(
            inheriting: inheritedFont,
            configuration: configuration
          )
          add(
            [
              .font: codeFont,
              .backgroundColor: configuration.services.syntaxHighlighter.backgroundColor(),
            ],
            range: token.contentRange
          )
          let markerFont =
            isActive
            ? codeFont
            : font(basedOn: baseFont, size: configuration.markers.hiddenMarkerFontSize)
          let markerColor =
            isActive
            ? configuration.theme.mutedText
            : configuration.theme.mutedText.withAlphaComponent(
              configuration.markers.inlineCodeMarkerAlpha)
          for range in token.markerRanges {
            add([.foregroundColor: markerColor, .font: markerFont], range: range)
          }

        case .blockquote:
          let quoteParagraph = baseParagraphStyle(font: baseFont, configuration: configuration)
          quoteParagraph.firstLineHeadIndent = 18
          quoteParagraph.headIndent = 18
          add([.paragraphStyle: quoteParagraph], range: nsText.paragraphRange(for: token.range))
          add([.foregroundColor: configuration.theme.mutedText], range: token.contentRange)
          addMarkers(token)

        case .blockLatex:
          styleBlockLatex(
            token,
            isActive: isActive,
            tokens: tokens,
            text: nsText,
            result: result,
            baseFont: baseFont,
            configuration: configuration
          )

        case .inlineLatex:
          styleInlineLatex(
            token,
            isActive: isActive,
            tokens: tokens,
            text: nsText,
            result: result,
            baseFont: baseFont,
            configuration: configuration
          )

        case .imageEmbed:
          styleImageEmbed(
            token,
            isActive: isActive,
            text: nsText,
            result: result,
            baseFont: baseFont,
            availableWidth: availableWidth,
            configuration: configuration
          )

        case .imageLink:
          styleImageLink(
            token,
            isActive: isActive,
            text: nsText,
            result: result,
            baseFont: baseFont,
            availableWidth: availableWidth,
            configuration: configuration
          )

        case .table:
          addMarkers(token)

        case .backslashEscape:
          add(
            [.foregroundColor: UIColor.clear, .font: UIFont.systemFont(ofSize: 0.1)],
            range: token.markerRanges.first ?? token.range)
        }
      }

      styleAutoLinks(
        text: text,
        ranges: autoLinkRanges,
        result: result,
        links: configuration.services.links
      )

      styleTaskCheckboxes(
        text: text,
        nsText: nsText,
        selectionRange: selectionRange,
        selectionSuppressed: selectionSuppressed,
        codeTokens: codeTokens,
        result: result,
        baseFont: baseFont,
        configuration: configuration
      )

      shrinkInactiveMarkers(
        tokens: tokens,
        activeTokenIndices: activeTokenIndices,
        codeTokens: codeTokens,
        result: result,
        baseFont: baseFont,
        configuration: configuration
      )
      return result
    }

    private static func styleAutoLinks(
      text: String,
      ranges: [NSRange],
      result: NSMutableAttributedString,
      links: any MarkdownLinkResolver
    ) {
      guard let detector = autoLinkDetector else { return }
      for range in ranges {
        detector.enumerateMatches(in: text, range: range) { match, _, _ in
          guard let match, let detected = match.url, let url = links.url(forDetected: detected)
          else { return }
          result.addAttribute(.link, value: url, range: match.range)
        }
      }
    }

    private static func font(
      named fontName: String,
      size: CGFloat,
      traits: UIFontDescriptor.SymbolicTraits = []
    ) -> UIFont {
      let base = UIFont(name: fontName, size: size) ?? UIFont.systemFont(ofSize: size)
      guard !traits.isEmpty,
        let descriptor = base.fontDescriptor.withSymbolicTraits(traits)
      else {
        return base
      }
      return UIFont(descriptor: descriptor, size: size)
    }

    private static func font(
      basedOn baseFont: UIFont,
      size: CGFloat,
      traits: UIFontDescriptor.SymbolicTraits = []
    ) -> UIFont {
      let sizedFont = baseFont.withSize(size)
      guard !traits.isEmpty,
        let descriptor = sizedFont.fontDescriptor.withSymbolicTraits(traits)
      else {
        return sizedFont
      }
      return UIFont(descriptor: descriptor, size: size)
    }

    private static func inlineCodeFont(
      inheriting font: UIFont,
      configuration: MarkdownEditorConfiguration
    ) -> UIFont {
      let size = round(font.pointSize * configuration.inlineCode.fontSizeScale)
      let codeFont = configuration.services.syntaxHighlighter.codeFont(size: size)
      let traits = font.fontDescriptor.symbolicTraits.intersection([.traitBold, .traitItalic])
      guard !traits.isEmpty,
        let descriptor = codeFont.fontDescriptor.withSymbolicTraits(
          codeFont.fontDescriptor.symbolicTraits.union(traits))
      else {
        return codeFont
      }
      return UIFont(descriptor: descriptor, size: size)
    }

    private static func baseParagraphStyle(
      font: UIFont,
      configuration: MarkdownEditorConfiguration
    ) -> NSMutableParagraphStyle {
      let paragraph = NSMutableParagraphStyle()
      paragraph.minimumLineHeight =
        ceil(font.lineHeight) + configuration.paragraph.lineHeightExtraSpacing
      paragraph.paragraphSpacing = ceil(font.lineHeight * configuration.paragraph.spacingFactor)
      paragraph.lineBreakMode = .byWordWrapping
      paragraph.tabStops = (1...24).map {
        NSTextTab(textAlignment: .left, location: CGFloat($0) * configuration.lists.indentPerLevel)
      }
      paragraph.defaultTabInterval = 0
      return paragraph
    }

    private static func codeParagraphStyle(
      font: UIFont,
      configuration: MarkdownEditorConfiguration
    ) -> NSMutableParagraphStyle {
      let paragraph = NSMutableParagraphStyle()
      paragraph.lineBreakMode = .byCharWrapping
      paragraph.paragraphSpacingBefore = configuration.codeBlock.paragraphSpacing
      paragraph.paragraphSpacing = configuration.codeBlock.paragraphSpacing
      paragraph.headIndent = configuration.codeBlock.horizontalIndent
      paragraph.firstLineHeadIndent = configuration.codeBlock.horizontalIndent
      paragraph.tailIndent = -configuration.codeBlock.horizontalIndent
      paragraph.minimumLineHeight = ceil(font.lineHeight)
      paragraph.maximumLineHeight = ceil(font.lineHeight)
      return paragraph
    }

    private static func isFullyInsideCode(_ range: NSRange, codeTokens: [MarkdownToken]) -> Bool {
      codeTokens.contains {
        range.location >= $0.range.location && NSMaxRange(range) <= NSMaxRange($0.range)
      }
    }

    private static func styleMarkdownLink(
      _ token: MarkdownToken,
      isActive: Bool,
      text: NSString,
      result: NSMutableAttributedString,
      configuration: MarkdownEditorConfiguration
    ) {
      let full = text.substring(with: token.range)
      guard let urlStart = full.firstIndex(of: "("), let urlEnd = full.lastIndex(of: ")") else {
        return
      }
      let rawURL = String(full[full.index(after: urlStart)..<urlEnd])
      let destination = normalizedMarkdownLinkDestination(rawURL)
      let color =
        isActive
        ? configuration.theme.link.withAlphaComponent(configuration.link.activeLinkAlpha)
        : configuration.theme.link
      var attrs: [NSAttributedString.Key: Any] = [
        .foregroundColor: color,
        .underlineStyle: NSUnderlineStyle.single.rawValue,
      ]
      if !isActive, let url = configuration.services.links.url(for: destination) {
        attrs[.link] = url
      }
      result.addAttributes(attrs, range: token.contentRange)
      for range in token.markerRanges {
        result.addAttributes([.foregroundColor: configuration.theme.mutedText], range: range)
      }
    }

    private static func styleImageEmbed(
      _ token: MarkdownToken,
      isActive: Bool,
      text: NSString,
      result: NSMutableAttributedString,
      baseFont: UIFont,
      availableWidth: CGFloat?,
      configuration: MarkdownEditorConfiguration
    ) {
      guard !isActive else {
        addMarkers(for: token, to: result, color: configuration.theme.mutedText)
        return
      }
      let rawContent = text.substring(with: token.contentRange)
      let parts =
        rawContent
        .split(separator: "|", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      guard let name = parts.first, !name.isEmpty else {
        addMarkers(for: token, to: result, color: configuration.theme.mutedText)
        return
      }
      var identifier: String?
      var requestedWidth: CGFloat?
      for part in parts.dropFirst() where !part.isEmpty {
        if requestedWidth == nil, let value = Double(part), value > 0 {
          requestedWidth = CGFloat(value)
        } else if identifier == nil {
          identifier = part
        }
      }
      let requestedHeight = parts.dropFirst().compactMap { part -> CGFloat? in
        guard part.hasPrefix("height="), let value = Double(part.dropFirst("height=".count)),
          value.isFinite, value > 0
        else { return nil }
        return CGFloat(value)
      }.first
      if styleHTML(
        token, name: name, isExplicitHTML: parts.dropFirst().contains("html"),
        requestedHeight: requestedHeight,
        text: text, result: result, baseFont: baseFont,
        availableWidth: availableWidth, configuration: configuration
      ) {
        return
      }
      let request = EmbeddedImageRequest(name: name, id: identifier, requestedWidth: requestedWidth)
      if styleLocalVideo(
        token, name: request.name, requestedWidth: request.requestedWidth,
        text: text, result: result, baseFont: baseFont,
        availableWidth: availableWidth, configuration: configuration
      ) {
        return
      }
      guard let image = configuration.services.images.image(for: request) else {
        addMarkers(for: token, to: result, color: configuration.theme.mutedText)
        return
      }
      let imageBounds = markdownMediaBounds(
        size: image.size,
        requestedWidth: requestedWidth,
        useMinimumWidthForNaturalSize: false,
        availableWidth: availableWidth,
        configuration: configuration
      )
      guard
        renderStandaloneMediaBlock(
          token,
          image: image,
          imageBounds: imageBounds,
          text: text,
          result: result,
          baseFont: baseFont,
          configuration: configuration
        )
      else {
        addMarkers(for: token, to: result, color: configuration.theme.mutedText)
        return
      }
    }

    private static func styleImageLink(
      _ token: MarkdownToken,
      isActive: Bool,
      text: NSString,
      result: NSMutableAttributedString,
      baseFont: UIFont,
      availableWidth: CGFloat?,
      configuration: MarkdownEditorConfiguration
    ) {
      guard !isActive, token.markerRanges.count >= 4 else {
        addMarkers(for: token, to: result, color: configuration.theme.mutedText)
        return
      }
      let openParen = token.markerRanges[2]
      let closeParen = token.markerRanges[3]
      let urlStart = NSMaxRange(openParen)
      let urlLength = closeParen.location - urlStart
      guard urlLength > 0 else {
        addMarkers(for: token, to: result, color: configuration.theme.mutedText)
        return
      }
      let url = text.substring(with: NSRange(location: urlStart, length: urlLength))
      if styleHTML(
        token, name: url, isExplicitHTML: false, requestedHeight: nil,
        text: text, result: result, baseFont: baseFont,
        availableWidth: availableWidth, configuration: configuration
      ) {
        return
      }
      let request = EmbeddedImageRequest(name: url)
      if styleLocalVideo(
        token, name: request.name, requestedWidth: request.requestedWidth,
        text: text, result: result, baseFont: baseFont,
        availableWidth: availableWidth, configuration: configuration
      ) {
        return
      }
      guard let image = configuration.services.images.image(for: request) else {
        addMarkers(for: token, to: result, color: configuration.theme.mutedText)
        return
      }
      let imageBounds = markdownMediaBounds(
        size: image.size,
        requestedWidth: nil,
        useMinimumWidthForNaturalSize: true,
        availableWidth: availableWidth,
        configuration: configuration
      )
      guard
        renderStandaloneMediaBlock(
          token,
          image: image,
          imageBounds: imageBounds,
          text: text,
          result: result,
          baseFont: baseFont,
          configuration: configuration
        )
      else {
        addMarkers(for: token, to: result, color: configuration.theme.mutedText)
        return
      }
    }

    private static func styleHTML(
      _ token: MarkdownToken,
      name: String,
      isExplicitHTML: Bool,
      requestedHeight: CGFloat?,
      text: NSString,
      result: NSMutableAttributedString,
      baseFont: UIFont,
      availableWidth: CGFloat?,
      configuration: MarkdownEditorConfiguration
    ) -> Bool {
      guard token.standaloneParagraphRange(in: text) != nil,
        let url = configuration.services.html.htmlURL(for: name, isExplicitHTML: isExplicitHTML),
        url.isFileURL || ["http", "https"].contains(url.scheme?.lowercased() ?? "")
      else { return false }
      let width: CGFloat
      if let availableWidth, availableWidth.isFinite, availableWidth > 0,
        availableWidth < configuration.imageEmbed.unreasonableMaxWidth
      {
        width = availableWidth
      } else {
        width = configuration.imageEmbed.fallbackMaxWidth
      }
      let bounds = CGRect(x: 0, y: 0, width: width, height: requestedHeight ?? width * 3 / 4)
      return renderStandaloneMediaBlock(
        token, image: nil, htmlURL: url, imageBounds: bounds, text: text,
        result: result, baseFont: baseFont, configuration: configuration)
    }

    private static func styleLocalVideo(
      _ token: MarkdownToken,
      name: String,
      requestedWidth: CGFloat?,
      text: NSString,
      result: NSMutableAttributedString,
      baseFont: UIFont,
      availableWidth: CGFloat?,
      configuration: MarkdownEditorConfiguration
    ) -> Bool {
      guard token.standaloneParagraphRange(in: text) != nil,
        let url = configuration.services.videos.localVideoURL(for: name), url.isFileURL
      else { return false }
      // Keep layout synchronous: the prototype fits videos into a 16:9 viewport,
      // while AVKit preserves the actual video's aspect ratio inside it.
      let bounds = markdownMediaBounds(
        size: CGSize(width: 640, height: 360), requestedWidth: requestedWidth,
        useMinimumWidthForNaturalSize: true, availableWidth: availableWidth,
        configuration: configuration)
      return renderStandaloneMediaBlock(
        token, image: nil, videoURL: url, imageBounds: bounds, text: text,
        result: result, baseFont: baseFont, configuration: configuration)
    }

    private static func markdownMediaBounds(
      size: CGSize,
      requestedWidth: CGFloat?,
      useMinimumWidthForNaturalSize: Bool,
      availableWidth: CGFloat?,
      configuration: MarkdownEditorConfiguration
    ) -> CGRect {
      let imageEmbed = configuration.imageEmbed
      let maxWidth: CGFloat
      if let availableWidth, availableWidth.isFinite, availableWidth > 0,
        availableWidth < imageEmbed.unreasonableMaxWidth
      {
        maxWidth = availableWidth
      } else {
        maxWidth = imageEmbed.fallbackMaxWidth
      }
      let naturalWidth = max(size.width, 1)
      let naturalHeight = max(size.height, 1)
      let targetWidth: CGFloat
      if let requestedWidth, requestedWidth > 0 {
        targetWidth = min(max(requestedWidth, imageEmbed.minimumWidth), maxWidth)
      } else if useMinimumWidthForNaturalSize {
        targetWidth = min(max(naturalWidth, imageEmbed.minimumWidth), maxWidth)
      } else {
        targetWidth = min(naturalWidth, maxWidth)
      }
      let scale = targetWidth / naturalWidth
      return CGRect(x: 0, y: 0, width: naturalWidth * scale, height: naturalHeight * scale)
    }

    private static func renderStandaloneMediaBlock(
      _ token: MarkdownToken,
      image: UIImage?,
      videoURL: URL? = nil,
      htmlURL: URL? = nil,
      imageBounds: CGRect,
      text: NSString,
      result: NSMutableAttributedString,
      baseFont: UIFont,
      configuration: MarkdownEditorConfiguration
    ) -> Bool {
      guard let paragraphRange = token.standaloneParagraphRange(in: text) else { return false }
      let hiddenFont = font(basedOn: baseFont, size: configuration.markers.hiddenMarkerFontSize)
      let paragraph = baseParagraphStyle(font: baseFont, configuration: configuration)
      let minimumLineHeight = max(ceil(baseFont.lineHeight), imageBounds.height)
      paragraph.minimumLineHeight = minimumLineHeight
      paragraph.maximumLineHeight = minimumLineHeight
      paragraph.paragraphSpacingBefore = configuration.imageEmbed.paragraphSpacing
      paragraph.paragraphSpacing = configuration.imageEmbed.paragraphSpacing
      paragraph.lineBreakMode = .byClipping
      add([.paragraphStyle: paragraph], range: paragraphRange, to: result)

      let anchorRange = NSRange(location: token.range.location, length: 1)
      guard NSMaxRange(anchorRange) <= result.length else { return false }
      if anchorRange.location > paragraphRange.location {
        hideText(
          in: NSRange(
            location: paragraphRange.location,
            length: anchorRange.location - paragraphRange.location),
          text: text,
          result: result,
          font: hiddenFont
        )
      }
      let trailingStart = NSMaxRange(anchorRange)
      if trailingStart < NSMaxRange(paragraphRange) {
        hideText(
          in: NSRange(location: trailingStart, length: NSMaxRange(paragraphRange) - trailingStart),
          text: text,
          result: result,
          font: hiddenFont
        )
      }
      let anchorText = text.substring(with: anchorRange)
      if let image {
        add(
          [
            .latexImage: image,
            .latexBounds: NSValue(cgRect: imageBounds),
            .latexIsBlock: true,
            .markdownImageBlock: true,
            .foregroundColor: UIColor.clear,
            .font: hiddenFont,
            .kern: imageBounds.width - textWidth(anchorText, font: hiddenFont),
          ],
          range: anchorRange,
          to: result
        )
      } else if let mediaURL = htmlURL ?? videoURL {
        add(
          [
            (htmlURL != nil ? .markdownHTMLURL : .markdownVideoURL): mediaURL,
            .latexBounds: NSValue(cgRect: imageBounds),
            .latexIsBlock: true,
            .markdownImageBlock: true,
            .foregroundColor: UIColor.clear,
            .font: hiddenFont,
            .kern: imageBounds.width - textWidth(anchorText, font: hiddenFont),
          ],
          range: anchorRange,
          to: result
        )
      }
      return true
    }

    private static func styleBlockLatex(
      _ token: MarkdownToken,
      isActive: Bool,
      tokens: [MarkdownToken],
      text: NSString,
      result: NSMutableAttributedString,
      baseFont: UIFont,
      configuration: MarkdownEditorConfiguration
    ) {
      guard token.standaloneParagraphRange(in: text) != nil else {
        addMarkers(for: token, to: result, color: configuration.theme.mutedText)
        return
      }

      let latexContent = text.substring(with: token.contentRange)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let latexFontSize = latexFontSize(
        for: token, tokens: tokens, baseFont: baseFont, configuration: configuration)
      guard !isActive, !latexContent.isEmpty,
        let entry = configuration.services.latex.render(
          latex: latexContent, fontSize: latexFontSize, theme: configuration.theme)
      else {
        addMarkers(for: token, to: result, color: configuration.theme.mutedText)
        return
      }

      let paragraphRange = text.paragraphRange(for: token.range)
      let paragraph = baseParagraphStyle(font: baseFont, configuration: configuration)
      paragraph.alignment = .center
      paragraph.paragraphSpacingBefore = configuration.blockLatex.paragraphSpacingBefore
      paragraph.paragraphSpacing = configuration.blockLatex.paragraphSpacing
      paragraph.minimumLineHeight = max(paragraph.minimumLineHeight, entry.size.height)

      let anchorLocation = firstVisibleContentLocation(in: token.contentRange, text: text)
      guard anchorLocation != NSNotFound else {
        addMarkers(for: token, to: result, color: configuration.theme.mutedText)
        return
      }
      let collapsedParagraph = NSMutableParagraphStyle()
      collapsedParagraph.minimumLineHeight = 1
      collapsedParagraph.maximumLineHeight = 1
      collapsedParagraph.paragraphSpacing = 0
      collapsedParagraph.paragraphSpacingBefore = 0
      var paragraphLocation = paragraphRange.location
      let paragraphEnd = NSMaxRange(paragraphRange)
      while paragraphLocation < paragraphEnd {
        let currentParagraph = text.paragraphRange(
          for: NSRange(location: paragraphLocation, length: 0))
        let boundedParagraph = NSIntersectionRange(currentParagraph, paragraphRange)
        if boundedParagraph.length > 0 {
          let style =
            NSLocationInRange(anchorLocation, boundedParagraph) ? paragraph : collapsedParagraph
          add([.paragraphStyle: style], range: boundedParagraph, to: result)
        }
        let nextLocation = NSMaxRange(currentParagraph)
        paragraphLocation = nextLocation > paragraphLocation ? nextLocation : paragraphLocation + 1
      }
      let imageBounds = CGRect(
        x: 0, y: entry.baselineOffset, width: entry.size.width, height: entry.size.height)

      let hiddenFont = font(basedOn: baseFont, size: configuration.markers.hiddenMarkerFontSize)
      let anchorRange = NSRange(location: anchorLocation, length: 1)
      let anchorText = text.substring(with: anchorRange)
      add(
        [
          .latexImage: entry.image,
          .latexBounds: NSValue(cgRect: imageBounds),
          .latexIsBlock: true,
          .foregroundColor: UIColor.clear,
          .font: hiddenFont,
          .kern: entry.size.width - textWidth(anchorText, font: hiddenFont),
        ],
        range: anchorRange,
        to: result
      )
      hideText(
        in: NSRange(
          location: paragraphRange.location, length: token.range.location - paragraphRange.location),
        text: text,
        result: result,
        font: hiddenFont
      )
      hideText(
        in: NSRange(
          location: token.contentRange.location,
          length: anchorLocation - token.contentRange.location),
        text: text,
        result: result,
        font: hiddenFont
      )
      let trailingStart = anchorLocation + 1
      hideText(
        in: NSRange(
          location: trailingStart, length: NSMaxRange(token.contentRange) - trailingStart),
        text: text,
        result: result,
        font: hiddenFont
      )
      hideMarkers(for: token, text: text, result: result, font: hiddenFont)
      hideText(
        in: NSRange(
          location: NSMaxRange(token.range),
          length: NSMaxRange(paragraphRange) - NSMaxRange(token.range)),
        text: text,
        result: result,
        font: hiddenFont
      )
    }

    private static func styleInlineLatex(
      _ token: MarkdownToken,
      isActive: Bool,
      tokens: [MarkdownToken],
      text: NSString,
      result: NSMutableAttributedString,
      baseFont: UIFont,
      configuration: MarkdownEditorConfiguration
    ) {
      let latexContent = text.substring(with: token.contentRange)
      let latexFontSize = latexFontSize(
        for: token, tokens: tokens, baseFont: baseFont, configuration: configuration)
      guard !isActive,
        let entry = configuration.services.latex.render(
          latex: latexContent, fontSize: latexFontSize, theme: configuration.theme)
      else {
        addMarkers(for: token, to: result, color: configuration.theme.mutedText)
        return
      }

      guard token.contentRange.length > 0 else {
        addMarkers(for: token, to: result, color: configuration.theme.mutedText)
        return
      }

      let imageBounds = CGRect(
        x: 0, y: entry.baselineOffset, width: entry.size.width, height: entry.size.height)

      let hiddenFont = font(basedOn: baseFont, size: configuration.markers.hiddenMarkerFontSize)
      let anchorRange = NSRange(location: token.contentRange.location, length: 1)
      let anchorText = text.substring(with: anchorRange)
      add(
        [
          .latexImage: entry.image,
          .latexBounds: NSValue(cgRect: imageBounds),
          .foregroundColor: UIColor.clear,
          .font: hiddenFont,
          .kern: entry.size.width - textWidth(anchorText, font: hiddenFont),
        ],
        range: anchorRange,
        to: result
      )
      if token.contentRange.length > 1 {
        hideText(
          in: NSRange(
            location: token.contentRange.location + 1, length: token.contentRange.length - 1),
          text: text,
          result: result,
          font: hiddenFont
        )
      }
      hideMarkers(for: token, text: text, result: result, font: hiddenFont)
    }

    private static func latexFontSize(
      for token: MarkdownToken,
      tokens: [MarkdownToken],
      baseFont: UIFont,
      configuration: MarkdownEditorConfiguration
    ) -> CGFloat {
      if let headingToken = tokens.first(where: {
        $0.kind == .heading && NSLocationInRange(token.contentRange.location, $0.contentRange)
      }) {
        let level = headingToken.markerRanges.first?.length ?? 1
        return baseFont.pointSize * configuration.headings.fontMultiplier(for: level)
      }
      return baseFont.pointSize
    }

    private static func firstVisibleContentLocation(in range: NSRange, text: NSString) -> Int {
      guard range.length > 0 else { return NSNotFound }
      for offset in 0..<range.length {
        let location = range.location + offset
        let scalar = UnicodeScalar(text.character(at: location))
        if let scalar, !CharacterSet.whitespacesAndNewlines.contains(scalar) {
          return location
        }
      }
      return range.location
    }

    private static func addMarkers(
      for token: MarkdownToken,
      to result: NSMutableAttributedString,
      color: UIColor
    ) {
      for range in token.markerRanges {
        add([.foregroundColor: color], range: range, to: result)
      }
    }

    private static func hideMarkers(
      for token: MarkdownToken,
      text: NSString,
      result: NSMutableAttributedString,
      font: UIFont
    ) {
      for range in token.markerRanges {
        hideText(in: range, text: text, result: result, font: font)
      }
    }

    private static func hideText(
      in range: NSRange,
      text: NSString,
      result: NSMutableAttributedString,
      font: UIFont
    ) {
      guard range.length > 0 else { return }
      add(
        [
          .foregroundColor: UIColor.clear,
          .font: font,
          .kern: -textWidth(text.substring(with: range), font: font),
        ],
        range: range,
        to: result
      )
    }

    private static func add(
      _ attrs: [NSAttributedString.Key: Any],
      range: NSRange,
      to result: NSMutableAttributedString
    ) {
      guard range.location >= 0, NSMaxRange(range) <= result.length, range.length > 0 else {
        return
      }
      result.addAttributes(attrs, range: range)
    }

    static func textWidth(_ text: String, font: UIFont) -> CGFloat {
      (text as NSString).size(withAttributes: [.font: font]).width
    }

    private static func shrinkInactiveMarkers(
      tokens: [MarkdownToken],
      activeTokenIndices: Set<Int>,
      codeTokens: [MarkdownToken],
      result: NSMutableAttributedString,
      baseFont: UIFont,
      configuration: MarkdownEditorConfiguration
    ) {
      let tinyFont = font(basedOn: baseFont, size: configuration.markers.hiddenMarkerFontSize)
      for (index, token) in tokens.enumerated() where !activeTokenIndices.contains(index) {
        switch token.kind {
        case .codeBlock, .inlineCode, .inlineLatex, .blockLatex, .imageEmbed, .imageLink, .table:
          continue
        default:
          break
        }
        if isFullyInsideCode(token.range, codeTokens: codeTokens) {
          continue
        }
        if token.kind == .link, token.markerRanges.count >= 4 {
          let openParen = token.markerRanges[2]
          let closeParen = token.markerRanges[3]
          let hideRange = NSRange(
            location: openParen.location,
            length: NSMaxRange(closeParen) - openParen.location
          )
          if NSMaxRange(hideRange) <= result.length {
            result.addAttributes(
              [
                .font: tinyFont,
                .foregroundColor: UIColor.clear,
                .kern: -tinyFont.pointSize,
              ],
              range: hideRange)
          }
        }
        for range in token.markerRanges where NSMaxRange(range) <= result.length {
          result.addAttributes([.font: tinyFont, .kern: -tinyFont.pointSize], range: range)
        }
      }
    }
  }
#endif
