#if canImport(UIKit)
  import AVKit
  import Foundation
  import SwiftUI
  import UIKit
  import WebKit

  /// SwiftUI bridge for MarkdownEngine's UIKit-backed editor.
  ///
  /// This variant intentionally uses UIKit's standard `UITextView` editing
  /// stack. It shares MarkdownEngine's tokenizer, styling configuration, and
  /// wiki-link storage/display transform, but does not attempt to port the
  /// AppKit TextKit 2 custom layout-fragment renderer.
  public struct NativeTextViewWrapper: UIViewRepresentable {
    public typealias UIViewType = UITextView

    /// Two-way binding to the document text in storage form
    /// (`[[Name|<id>]]` for wiki-links).
    @Binding public var text: String
    /// Becomes `true` while the caret is inside a `[[Name]]` link's content
    /// range, so embedders can show contextual UI.
    @Binding public var isWikiLinkActive: Bool
    /// Push a replacement into the editor by setting this to a non-nil value;
    /// the engine applies it on the next update and then clears the binding.
    @Binding public var pendingInlineReplacement: InlineReplacementRequest?
    /// The full editor configuration (theme + services + style toggles).
    public var configuration: MarkdownEditorConfiguration
    /// PostScript name of the base font used for body text.
    public var fontName: String
    /// Base font size in points.
    public var fontSize: CGFloat
    /// Opaque document identifier used to scope pending replacements.
    public var documentId: String
    /// When `false` the editor renders read-only with no caret.
    public var isEditable: Bool
    /// Optional paste hook. Return a Markdown image-embed string to insert at
    /// the caret, or `nil` to fall through to UIKit's paste handling.
    public var onPasteImage: ((NSPasteboard) -> String?)?

    /// Fires when the user taps a `[[Name]]` link.
    public var onLinkClick: ((String) -> Void)?
    /// Fires whenever the caret rect inside an active wiki-link changes.
    public var onCaretRectChange: ((CGRect) -> Void)?
    /// Fires when the caret enters or leaves a `[[Name]]` or `![[...]]` token.
    public var onInlineSelectionChange: ((InlineSelectionState?) -> Void)?
    /// Fires with rendered fenced-code-block rects so embedders can overlay
    /// copy-code controls.
    public var onCodeBlockSelectionChange: (([CodeBlockSelection]) -> Void)?
    /// AppKit-only spell-check preference hook. UIKit manages these via
    /// `UITextInputTraits`, so this callback is currently not emitted.
    public var onSpellCheckingPolicyChanged: ((SpellCheckingPolicy) -> Void)?

    public init(
      text: Binding<String>,
      isWikiLinkActive: Binding<Bool> = .constant(false),
      pendingInlineReplacement: Binding<InlineReplacementRequest?> = .constant(nil),
      configuration: MarkdownEditorConfiguration = .default,
      fontName: String = "SF Pro",
      fontSize: CGFloat = 16,
      documentId: String = "default",
      isEditable: Bool = true,
      onPasteImage: ((NSPasteboard) -> String?)? = nil,
      onLinkClick: ((String) -> Void)? = nil,
      onCaretRectChange: ((CGRect) -> Void)? = nil,
      onInlineSelectionChange: ((InlineSelectionState?) -> Void)? = nil,
      onCodeBlockSelectionChange: (([CodeBlockSelection]) -> Void)? = nil,
      onSpellCheckingPolicyChanged: ((SpellCheckingPolicy) -> Void)? = nil
    ) {
      self._text = text
      self._isWikiLinkActive = isWikiLinkActive
      self._pendingInlineReplacement = pendingInlineReplacement
      self.configuration = configuration
      self.fontName = fontName
      self.fontSize = fontSize
      self.documentId = documentId
      self.isEditable = isEditable
      self.onPasteImage = onPasteImage
      self.onLinkClick = onLinkClick
      self.onCaretRectChange = onCaretRectChange
      self.onInlineSelectionChange = onInlineSelectionChange
      self.onCodeBlockSelectionChange = onCodeBlockSelectionChange
      self.onSpellCheckingPolicyChanged = onSpellCheckingPolicyChanged
    }

    public func makeUIView(context: Context) -> UITextView {
      let textView = MarkdownTextView(frame: .zero, textContainer: nil)
      textView.backgroundColor = .clear
      textView.isScrollEnabled = true
      textView.alwaysBounceVertical = true
      textView.textContainer.lineFragmentPadding = 0
      textView.textContainerInset = UIEdgeInsets(
        top: configuration.textInsets.vertical + configuration.safeAreaInsets.top,
        left: configuration.textInsets.horizontal + configuration.safeAreaInsets.leading,
        bottom: configuration.textInsets.vertical + configuration.safeAreaInsets.bottom,
        right: configuration.textInsets.horizontal + configuration.safeAreaInsets.trailing
      )
      textView.adjustsFontForContentSizeCategory = false
      textView.autocorrectionType =
        configuration.spellChecking.automaticSpellingCorrection ? .default : .no
      textView.spellCheckingType =
        configuration.spellChecking.continuousSpellChecking ? .default : .no
      textView.smartQuotesType = .yes
      textView.smartDashesType = .no
      textView.isEditable = isEditable
      textView.isSelectable = true
      textView.delegate = context.coordinator
      textView.onPasteImage = onPasteImage
      textView.linkTextAttributes = [
        .foregroundColor: configuration.theme.link,
        .underlineStyle: NSUnderlineStyle.single.rawValue,
      ]

      context.coordinator.rebuildTextStorageAndStyle(textView, from: text)
      return textView
    }

    public func updateUIView(_ textView: UITextView, context: Context) {
      let coordinator = context.coordinator
      let documentChanged = coordinator.documentId != documentId
      let fontChanged = coordinator.fontName != fontName || coordinator.fontSize != fontSize
      let configurationChanged = coordinator.configurationChangeCount != configuration.changeCount

      coordinator.documentId = documentId
      coordinator.fontName = fontName
      coordinator.fontSize = fontSize
      coordinator.baseFont =
        UIFont(name: fontName, size: fontSize) ?? UIFont.systemFont(ofSize: fontSize)
      coordinator.configuration = configuration
      coordinator.configurationChangeCount = configuration.changeCount
      coordinator.onLinkClick = onLinkClick
      coordinator.onCaretRectChange = onCaretRectChange
      coordinator.onInlineSelectionChange = onInlineSelectionChange
      coordinator.onCodeBlockSelectionChange = onCodeBlockSelectionChange

      (textView as? MarkdownTextView)?.onPasteImage = onPasteImage
      textView.isEditable = isEditable
      textView.isSelectable = true
      textView.autocorrectionType =
        configuration.spellChecking.automaticSpellingCorrection ? .default : .no
      textView.spellCheckingType =
        configuration.spellChecking.continuousSpellChecking ? .default : .no
      textView.textContainerInset = UIEdgeInsets(
        top: configuration.textInsets.vertical + configuration.safeAreaInsets.top,
        left: configuration.textInsets.horizontal + configuration.safeAreaInsets.leading,
        bottom: configuration.textInsets.vertical + configuration.safeAreaInsets.bottom,
        right: configuration.textInsets.horizontal + configuration.safeAreaInsets.trailing
      )
      textView.linkTextAttributes = [
        .foregroundColor: configuration.theme.link,
        .underlineStyle: NSUnderlineStyle.single.rawValue,
      ]

      if let pendingInlineReplacement {
        if pendingInlineReplacement.documentId == documentId,
          coordinator.lastAppliedInlineReplacementID != pendingInlineReplacement.id
        {
          coordinator.applyInlineReplacement(pendingInlineReplacement, to: textView)
        }
        DispatchQueue.main.async {
          if self.pendingInlineReplacement?.id == pendingInlineReplacement.id {
            self.pendingInlineReplacement = nil
          }
        }
        return
      }

      if documentChanged {
        textView.undoManager?.removeAllActions()
      }
      if documentChanged || fontChanged || configurationChanged {
        coordinator.rebuildTextStorageAndStyle(textView, from: text)
      } else if coordinator.lastSyncedText != text {
        coordinator.updateTextStorageAndStyle(textView, from: text)
      } else {
        coordinator.refreshInlineSelection(textView, deferBinding: true)
        coordinator.updateCodeBlockSelection(textView)
      }
    }

    public func makeCoordinator() -> Coordinator {
      let coordinator = Coordinator(
        text: $text,
        isWikiLinkActive: $isWikiLinkActive,
        fontName: fontName,
        fontSize: fontSize,
        documentId: documentId,
        configuration: configuration,
        onLinkClick: onLinkClick,
        onCaretRectChange: onCaretRectChange,
        onInlineSelectionChange: onInlineSelectionChange,
        onCodeBlockSelectionChange: onCodeBlockSelectionChange
      )
      return coordinator
    }

    public final class Coordinator: NSObject, UITextViewDelegate {
      @Binding var text: String
      @Binding var isWikiLinkActive: Bool
      var fontName: String
      var fontSize: CGFloat
      var baseFont: UIFont
      var documentId: String
      var configuration: MarkdownEditorConfiguration
      var configurationChangeCount: Int
      var lastSyncedText: String
      var lastDisplayText: String
      var lastStyledAvailableWidth: CGFloat?
      var hasWidthDependentMarkdownImage = false
      var lastAppliedInlineReplacementID: UUID?
      var wikiLinkMetadata: [WikiLinkService.RangeKey: WikiLinkService.LinkMetadata] = [:]
      var isProgrammaticEdit = false
      var onLinkClick: ((String) -> Void)?
      var onCaretRectChange: ((CGRect) -> Void)?
      var onInlineSelectionChange: ((InlineSelectionState?) -> Void)?
      var onCodeBlockSelectionChange: (([CodeBlockSelection]) -> Void)?
      weak var forwardingDelegate: UITextViewDelegate?
      private let parseState = DocumentParseState()

      init(
        text: Binding<String>,
        isWikiLinkActive: Binding<Bool>,
        fontName: String,
        fontSize: CGFloat,
        documentId: String,
        configuration: MarkdownEditorConfiguration,
        onLinkClick: ((String) -> Void)?,
        onCaretRectChange: ((CGRect) -> Void)?,
        onInlineSelectionChange: ((InlineSelectionState?) -> Void)?,
        onCodeBlockSelectionChange: (([CodeBlockSelection]) -> Void)?
      ) {
        self._text = text
        self._isWikiLinkActive = isWikiLinkActive
        self.fontName = fontName
        self.fontSize = fontSize
        self.baseFont =
          UIFont(name: fontName, size: fontSize) ?? UIFont.systemFont(ofSize: fontSize)
        self.documentId = documentId
        self.configuration = configuration
        self.configurationChangeCount = configuration.changeCount
        self.lastSyncedText = text.wrappedValue
        self.lastDisplayText = WikiLinkService.makeDisplayState(from: text.wrappedValue).display
        self.onLinkClick = onLinkClick
        self.onCaretRectChange = onCaretRectChange
        self.onInlineSelectionChange = onInlineSelectionChange
        self.onCodeBlockSelectionChange = onCodeBlockSelectionChange
        super.init()
      }

      public func textViewDidChange(_ textView: UITextView) {
        guard !isProgrammaticEdit else { return }
        guard textView.markedTextRange == nil else { return }
        let storageState = WikiLinkService.makeStorageState(
          from: textView.text ?? "",
          existingMetadata: wikiLinkMetadata,
          textStorage: textView.textStorage
        )
        wikiLinkMetadata = storageState.metadata
        if storageState.storage != lastSyncedText {
          lastSyncedText = storageState.storage
          DispatchQueue.main.async {
            self.text = storageState.storage
          }
        }
        applyStylePreservingSelection(textView)
        refreshInlineSelection(textView)
        forwardingDelegate?.textViewDidChange?(textView)
      }

      public func textViewDidChangeSelection(_ textView: UITextView) {
        guard !isProgrammaticEdit else { return }
        guard textView.markedTextRange == nil else { return }
        refreshInlineSelection(textView)
        applyStylePreservingSelection(textView)
        forwardingDelegate?.textViewDidChangeSelection?(textView)
      }

      public func textViewDidBeginEditing(_ textView: UITextView) {
        guard !isProgrammaticEdit else { return }
        applyStylePreservingSelection(textView)
        refreshInlineSelection(textView)
        forwardingDelegate?.textViewDidBeginEditing?(textView)
      }

      public func textViewDidEndEditing(_ textView: UITextView) {
        guard !isProgrammaticEdit else { return }
        applyStylePreservingSelection(textView)
        if isWikiLinkActive {
          isWikiLinkActive = false
        }
        onInlineSelectionChange?(nil)
        DispatchQueue.main.async {
          self.onCaretRectChange?(.zero)
        }
        forwardingDelegate?.textViewDidEndEditing?(textView)
      }

      public func textView(
        _ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String
      ) -> Bool {
        forwardingDelegate?.textView?(textView, shouldChangeTextIn: range, replacementText: text)
          ?? true
      }

      public func textView(
        _ textView: UITextView,
        shouldInteractWith URL: URL,
        in characterRange: NSRange,
        interaction: UITextItemInteraction
      ) -> Bool {
        guard URL.scheme == "markdownengine-wikilink" else {
          return forwardingDelegate?.textView?(
            textView, shouldInteractWith: URL, in: characterRange, interaction: interaction) ?? true
        }
        let linkID =
          textView.textStorage.attribute(
            .wikiLinkID, at: characterRange.location, effectiveRange: nil) as? String
        let target = linkID ?? URL.path.dropFirst().removingPercentEncoding ?? URL.absoluteString
        isWikiLinkActive = false
        DispatchQueue.main.async {
          self.onLinkClick?(String(target))
        }
        return false
      }

      public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if let textView = scrollView as? UITextView {
          updateCodeBlockSelection(textView)
        }
        forwardingDelegate?.scrollViewDidScroll?(scrollView)
      }

      func rebuildTextStorageAndStyle(_ textView: UITextView, from storageText: String) {
        let displayState = WikiLinkService.makeDisplayState(from: storageText)
        wikiLinkMetadata = displayState.metadata
        lastSyncedText = storageText
        parseState.invalidate()

        let previousSelection = textView.selectedRange
        let availableWidth =
          (textView as? MarkdownTextView)?.usesNaturalWidthForIntrinsicContentSize == true
          ? nil : availableTextWidth(for: textView)
        isProgrammaticEdit = true
        textView.attributedText = styledDisplayText(
          displayState.display,
          selectionRange: clamp(
            previousSelection, length: (displayState.display as NSString).length),
          selectionSuppressed: !textView.isFirstResponder || !textView.isEditable,
          availableWidth: availableWidth
        )
        lastDisplayText = displayState.display
        textView.setNeedsLayout()
        textView.selectedRange = clamp(previousSelection, length: textView.textStorage.length)
        textView.typingAttributes = baseTypingAttributes()
        (textView as? MarkdownTextView)?.updateSelectionHighlightViews()
        isProgrammaticEdit = false
        refreshInlineSelection(textView)
        updateCodeBlockSelection(textView)
      }

      func updateTextStorageAndStyle(_ textView: UITextView, from storageText: String) {
        let displayState = WikiLinkService.makeDisplayState(from: storageText)
        guard let diff = TextReplacementDiff(old: lastDisplayText, new: displayState.display) else {
          // Storage-only wiki-link changes can leave the display text identical
          // while changing the .wikiLinkID attributes. They need a restyle;
          // assigning the same storage value again is a true no-op.
          if lastSyncedText != storageText {
            rebuildTextStorageAndStyle(textView, from: storageText)
            return
          }
          wikiLinkMetadata = displayState.metadata
          return
        }
        guard textView.textStorage.string == lastDisplayText else {
          rebuildTextStorageAndStyle(textView, from: storageText)
          return
        }

        wikiLinkMetadata = displayState.metadata
        lastSyncedText = storageText
        let previousSelection = textView.selectedRange
        let availableWidth =
          (textView as? MarkdownTextView)?.usesNaturalWidthForIntrinsicContentSize == true
          ? nil : availableTextWidth(for: textView)
        let newStyledText = styledDisplayText(
          displayState.display,
          selectionRange: clamp(
            previousSelection, length: (displayState.display as NSString).length),
          selectionSuppressed: !textView.isFirstResponder || !textView.isEditable,
          availableWidth: availableWidth,
          edit: ParseEditDescriptor(editedRange: diff.newRange, delta: diff.delta)
        )
        let attributedDiff = AttributedTextReplacementDiff(
          old: textView.textStorage, new: newStyledText, textDiff: diff)

        isProgrammaticEdit = true
        textView.textStorage.beginEditing()
        textView.textStorage.replaceCharacters(
          in: attributedDiff.oldRange,
          with: newStyledText.attributedSubstring(from: attributedDiff.newRange)
        )
        textView.textStorage.endEditing()
        lastDisplayText = displayState.display
        textView.setNeedsLayout()
        (textView as? MarkdownTextView)?.invalidateIntrinsicContentSize()
        textView.selectedRange = clamp(previousSelection, length: textView.textStorage.length)
        textView.typingAttributes = baseTypingAttributes()
        (textView as? MarkdownTextView)?.updateSelectionHighlightViews()
        isProgrammaticEdit = false
        refreshInlineSelection(textView)
        updateCodeBlockSelection(textView)
      }

      func applyStylePreservingSelection(_ textView: UITextView) {
        let displayText = textView.text ?? ""
        let selection = clamp(textView.selectedRange, length: (displayText as NSString).length)
        let availableWidth = availableTextWidth(for: textView)
        isProgrammaticEdit = true
        textView.attributedText = styledDisplayText(
          displayText,
          selectionRange: selection,
          selectionSuppressed: !textView.isFirstResponder || !textView.isEditable,
          availableWidth: availableWidth
        )
        lastDisplayText = displayText
        textView.setNeedsLayout()
        textView.selectedRange = clamp(selection, length: textView.textStorage.length)
        textView.typingAttributes = baseTypingAttributes()
        (textView as? MarkdownTextView)?.updateSelectionHighlightViews()
        isProgrammaticEdit = false
        updateCodeBlockSelection(textView)
      }

      func restyleWidthDependentMarkdownImageIfNeeded(_ textView: MarkdownTextView) -> Bool {
        // Fixed-width views also render before Auto Layout supplies their initial width.
        // Resize their media and reserved line height when the text container width changes.
        guard hasWidthDependentMarkdownImage,
          let availableWidth = availableTextWidth(for: textView),
          lastStyledAvailableWidth.map({ abs($0 - availableWidth) > 0.5 }) ?? true
        else { return false }

        // Record the width before rebuilding so the next layout pass cannot restyle the same
        // content recursively. A later pass is still allowed when Auto Layout changes the width.
        lastStyledAvailableWidth = availableWidth
        applyStylePreservingSelection(textView)
        textView.invalidateIntrinsicContentSize()
        return true
      }

      func updateCodeBlockSelection(_ textView: UITextView) {
        guard let onCodeBlockSelectionChange else { return }
        let displayText = textView.text ?? ""
        let nsText = displayText as NSString
        guard nsText.length > 0 else {
          onCodeBlockSelectionChange([])
          return
        }
        let tokens = MarkdownTokenizer.parseTokensViaAST(
          in: displayText,
          registry: ExtensionRegistry(extensions: configuration.extensions)
        )
        let activeTokenIndices = MarkdownDetection.computeActiveTokenIndices(
          selectionRange: textView.selectedRange,
          tokens: tokens,
          in: nsText,
          suppressed: !textView.isFirstResponder || !textView.isEditable
        )
        let layoutManager = textView.layoutManager
        let textContainer = textView.textContainer
        layoutManager.ensureLayout(for: textContainer)
        let insets = textView.textContainerInset
        let containerWidth =
          textContainer.size.width.isFinite && textContainer.size.width > 0
          ? textContainer.size.width
          : max(0, textView.bounds.width - insets.left - insets.right)
        let selections: [CodeBlockSelection] = tokens.enumerated().compactMap { index, token in
          guard token.kind == .codeBlock, !activeTokenIndices.contains(index) else { return nil }
          let glyphRange = layoutManager.glyphRange(
            forCharacterRange: token.range, actualCharacterRange: nil)
          guard glyphRange.location != NSNotFound, glyphRange.length > 0 else { return nil }
          var boundingRect = CGRect.null
          layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) {
            lineRect, _, _, lineGlyphRange, _ in
            guard NSIntersectionRange(lineGlyphRange, glyphRange).length > 0 else { return }
            boundingRect = boundingRect.union(lineRect)
          }
          guard !boundingRect.isNull else { return nil }
          let rect = CGRect(
            x: insets.left - textView.contentOffset.x,
            y: insets.top + boundingRect.minY - textView.contentOffset.y,
            width: containerWidth,
            height: boundingRect.height
          ).integral
          return CodeBlockSelection(
            id: index,
            rect: rect,
            language: MarkdownTokenizer.extractLanguage(from: token, in: displayText),
            code: BacktickFence.contentProjection(forCodeBlock: token, in: nsText).text
          )
        }
        onCodeBlockSelectionChange(selections)
      }

      func styledDisplayText(
        _ displayText: String,
        selectionRange: NSRange,
        selectionSuppressed: Bool = false,
        availableWidth: CGFloat? = nil,
        edit: ParseEditDescriptor? = nil
      ) -> NSAttributedString {
        let nsText = displayText as NSString
        let safeSelection = clamp(selectionRange, length: nsText.length)
        lastStyledAvailableWidth = availableWidth
        let tokens = parseState.tokens(
          for: displayText, edit: edit, registry: configuration.extensionRegistry)
        let styledText = UIKitMarkdownStyler.attributedString(
          text: displayText,
          fontName: fontName,
          fontSize: fontSize,
          baseFont: baseFont,
          selectionRange: safeSelection,
          selectionSuppressed: selectionSuppressed,
          availableWidth: availableWidth,
          wikiLinkIDProvider: { [weak self] range in
            self?.wikiLinkMetadata[WikiLinkService.RangeKey(range)]?.id
          },
          precomputedTokens: tokens,
          precomputedBlocks: parseState.currentBlocks,
          configuration: configuration
        )
        hasWidthDependentMarkdownImage = false
        styledText.enumerateAttribute(
          .markdownImageBlock,
          in: NSRange(location: 0, length: styledText.length)
        ) { value, _, stop in
          guard value as? Bool == true else { return }
          hasWidthDependentMarkdownImage = true
          stop.pointee = true
        }
        return styledText
      }

      private func availableTextWidth(for textView: UITextView) -> CGFloat? {
        let containerWidth = textView.textContainer.size.width
        if containerWidth.isFinite && containerWidth > 0 {
          return containerWidth
        }
        let width =
          textView.bounds.width - textView.textContainerInset.left
          - textView.textContainerInset.right
        return width.isFinite && width > 0 ? width : nil
      }

      func refreshInlineSelection(_ textView: UITextView, deferBinding: Bool = false) {
        let displayText = textView.text ?? ""
        let nsText = displayText as NSString
        let selectionLocation = min(textView.selectedRange.location, nsText.length)
        let tokens = MarkdownTokenizer.parseTokensViaAST(
          in: displayText,
          registry: ExtensionRegistry(extensions: configuration.extensions)
        )
        let codeTokens = tokens.filter { $0.kind == .codeBlock || $0.kind == .inlineCode }

        let inlineContext = inlineTokenContext(
          at: selectionLocation,
          tokens: tokens,
          codeTokens: codeTokens,
          text: nsText
        )
        let wasWikiLinkActive = isWikiLinkActive
        let nextWikiLinkActive = inlineContext?.kind == .wikiLink
        if nextWikiLinkActive != isWikiLinkActive {
          if deferBinding {
            DispatchQueue.main.async {
              self.isWikiLinkActive = nextWikiLinkActive
            }
          } else {
            isWikiLinkActive = nextWikiLinkActive
          }
        }

        guard let inlineContext else {
          if wasWikiLinkActive {
            DispatchQueue.main.async { self.onCaretRectChange?(.zero) }
          }
          onInlineSelectionChange?(nil)
          return
        }

        let token = inlineContext.token
        let displayRange = selectionDisplayRange(
          for: token,
          openingMarkerLength: inlineContext.kind == .imageEmbed ? 3 : 2
        )
        let selection = WikiLinkSelection(
          displayRange: displayRange,
          storageRange: wikiLinkMetadata[WikiLinkService.RangeKey(displayRange)]?.storageRange,
          placeholder: nsText.substring(with: token.contentRange)
        )
        onInlineSelectionChange?(
          InlineSelectionState(kind: inlineContext.kind, selection: selection))
        if let rect = caretRect(in: textView, for: displayRange) {
          DispatchQueue.main.async { self.onCaretRectChange?(rect) }
        }
      }

      func applyInlineReplacement(_ request: InlineReplacementRequest, to textView: UITextView) {
        lastAppliedInlineReplacementID = request.id
        let currentText = (textView.text ?? "") as NSString
        let range = request.selection.displayRange
        guard range.location != NSNotFound, NSMaxRange(range) <= currentText.length else {
          return
        }

        let replacementDisplay: String
        let linkID: String?
        if request.isImageEmbedMode {
          replacementDisplay = request.storageFragment
          linkID = nil
        } else {
          let replacementInfo = WikiLinkService.displayFragmentAndID(from: request.storageFragment)
          replacementDisplay = replacementInfo.display
          linkID = replacementInfo.id
        }

        isProgrammaticEdit = true
        textView.textStorage.replaceCharacters(in: range, with: replacementDisplay)
        if let linkID, !linkID.isEmpty {
          let contentLength = max(0, (replacementDisplay as NSString).length - 4)
          if contentLength > 0 {
            let contentRange = NSRange(location: range.location + 2, length: contentLength)
            textView.textStorage.addAttribute(.wikiLinkID, value: linkID, range: contentRange)
          }
        }
        isProgrammaticEdit = false

        textViewDidChange(textView)
        let caretRange = WikiLinkService.caretRangeAfterReplacing(
          displayRange: range,
          with: request.storageFragment
        )
        textView.selectedRange = clamp(caretRange, length: textView.textStorage.length)
      }

      private func baseTypingAttributes() -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight =
          ceil(baseFont.lineHeight) + configuration.paragraph.lineHeightExtraSpacing
        paragraph.paragraphSpacing = ceil(
          baseFont.lineHeight * configuration.paragraph.spacingFactor)
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.tabStops = (1...24).map {
          NSTextTab(
            textAlignment: .left, location: CGFloat($0) * configuration.lists.indentPerLevel)
        }
        paragraph.defaultTabInterval = 0
        return [
          .font: baseFont,
          .foregroundColor: configuration.theme.bodyText,
          .paragraphStyle: paragraph,
        ]
      }

      private enum InlineContext {
        case wikiLink(MarkdownToken)
        case imageEmbed(MarkdownToken)

        var token: MarkdownToken {
          switch self {
          case .wikiLink(let token), .imageEmbed(let token):
            return token
          }
        }

        var kind: InlineSelectionKind {
          switch self {
          case .wikiLink:
            return .wikiLink
          case .imageEmbed:
            return .imageEmbed
          }
        }
      }

      private func inlineTokenContext(
        at selectionLocation: Int,
        tokens: [MarkdownToken],
        codeTokens: [MarkdownToken],
        text: NSString
      ) -> InlineContext? {
        for token in tokens where token.kind == .imageEmbed {
          guard token.containsSelectionOrStandaloneParagraph(selectionLocation, in: text) else {
            continue
          }
          guard !MarkdownDetection.isInsideCodeBlock(range: token.range, codeTokens: codeTokens)
          else { continue }
          return .imageEmbed(token)
        }

        for token in tokens where token.kind == .wikiLink {
          let start = token.range.location + 2
          let end = NSMaxRange(token.range) - 2
          guard selectionLocation >= start && selectionLocation <= end else { continue }
          guard !MarkdownDetection.isInsideCodeBlock(range: token.range, codeTokens: codeTokens)
          else { continue }
          return .wikiLink(token)
        }

        return nil
      }

      private func selectionDisplayRange(for token: MarkdownToken, openingMarkerLength: Int)
        -> NSRange
      {
        let leftRange =
          token.markerRanges.first
          ?? NSRange(
            location: token.range.location,
            length: min(openingMarkerLength, token.range.length)
          )
        let rightRange =
          token.markerRanges.last
          ?? NSRange(
            location: max(
              token.range.location, NSMaxRange(token.range) - min(2, token.range.length)),
            length: min(2, token.range.length)
          )
        return NSRange(
          location: leftRange.location,
          length: rightRange.location + rightRange.length - leftRange.location
        )
      }

      private func caretRect(in textView: UITextView, for range: NSRange) -> CGRect? {
        let length = textView.textStorage.length
        let location = min(max(range.location, 0), length)
        guard let start = textView.position(from: textView.beginningOfDocument, offset: location)
        else { return nil }
        let endOffset = min(NSMaxRange(range), length)
        guard let end = textView.position(from: textView.beginningOfDocument, offset: endOffset),
          let textRange = textView.textRange(from: start, to: end)
        else {
          return nil
        }
        return textView.firstRect(for: textRange)
      }

      private func clamp(_ range: NSRange, length: Int) -> NSRange {
        let location = min(max(range.location, 0), length)
        let maxLength = max(0, length - location)
        return NSRange(location: location, length: min(max(range.length, 0), maxLength))
      }
    }
  }

  public final class MarkdownTextView: UITextView {
    private final class RenderedTableScrollView: UIScrollView {
      let imageView = UIImageView(frame: .zero)

      override init(frame: CGRect) {
        super.init(frame: frame)
        #if targetEnvironment(macCatalyst)
          // A HorizontalScrollIndicatorController stands in: on the Mac, UIKit's scroller stays
          // drawn over the table's last row while scroll bars are always shown. Turn it off before
          // UIKit creates it; turned off later, the Mac keeps drawing it.
          showsHorizontalScrollIndicator = false
        #endif
        showsVerticalScrollIndicator = false
        alwaysBounceHorizontal = true
        alwaysBounceVertical = false
        backgroundColor = .clear
        // The content insets come from tableOverflowInsets alone.
        contentInsetAdjustmentBehavior = .never
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = false
        addSubview(imageView)
      }

      @available(*, unavailable)
      required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
      }
    }

    private final class TaskCheckboxButton: UIButton {
      let checkboxRange: NSRange
      let isCheckedTask: Bool

      init(checkboxRange: NSRange, isChecked: Bool) {
        self.checkboxRange = checkboxRange
        self.isCheckedTask = isChecked
        super.init(frame: .zero)
      }

      @available(*, unavailable)
      required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
      }
    }

    private var storageString = ""
    private var directIsWikiLinkActive = false
    private var directConfiguration = MarkdownEditorConfiguration.default
    private var directBaseFont = UIFont.systemFont(ofSize: 16)
    private var directFontName = UIFont.systemFont(ofSize: 16).fontName
    private var directFontSize: CGFloat = 16
    private var directDocumentId = "default"
    public private(set) var isShiftPressed = false
    private var codeBlockBackgroundViews: [UIView] = []
    private var thematicBreakViews: [UIView] = []
    private var taskCheckboxButtons: [TaskCheckboxButton] = []
    private var tableImageViews: [UIImageView] = []
    private var tableScrollViews: [Int: RenderedTableScrollView] = [:]
    private var tableScrollIndicatorControllers: [Int: HorizontalScrollIndicatorController] = [:]
    /// How far each removed wide table was scrolled from its resting position, by source ID.
    private var tableHorizontalScrollOffsets: [Int: CGFloat] = [:]
    private let selectionHighlightView = UIView(frame: .zero)
    private let selectionHighlightLayer = CAShapeLayer()
    private var latexImageViews: [UIImageView] = []
    private struct VideoEmbedID: Hashable {
      let url: URL
      let occurrence: Int
    }
    private var videoControllers: [VideoEmbedID: AVPlayerViewController] = [:]
    private struct HTMLEmbedID: Hashable {
      let url: URL
      let occurrence: Int
    }
    private var htmlViews: [HTMLEmbedID: WKWebView] = [:]
    private lazy var directCoordinator = NativeTextViewWrapper.Coordinator(
      text: Binding(
        get: { [weak self] in self?.storageString ?? "" },
        set: { [weak self] text in
          self?.storageString = text
        }),
      isWikiLinkActive: Binding(
        get: { [weak self] in self?.directIsWikiLinkActive ?? false },
        set: { [weak self] isActive in
          self?.directIsWikiLinkActive = isActive
        }),
      fontName: directFontName,
      fontSize: directFontSize,
      documentId: directDocumentId,
      configuration: directConfiguration,
      onLinkClick: nil,
      onCaretRectChange: nil,
      onInlineSelectionChange: nil,
      onCodeBlockSelectionChange: nil
    )

    public var string: String {
      get { storageString }
      set {
        storageString = newValue
        directCoordinator.updateTextStorageAndStyle(self, from: newValue)
      }
    }

    public var configuration: MarkdownEditorConfiguration {
      get { directConfiguration }
      set {
        directConfiguration = newValue
        directCoordinator.configuration = newValue
        directCoordinator.configurationChangeCount = newValue.changeCount
        applyMarkdownConfiguration()
        directCoordinator.rebuildTextStorageAndStyle(self, from: storageString)
      }
    }

    public var baseFont: UIFont {
      get { directBaseFont }
      set {
        directBaseFont = newValue
        directFontName = newValue.fontName
        directFontSize = newValue.pointSize
        font = newValue
        directCoordinator.fontName = newValue.fontName
        directCoordinator.fontSize = newValue.pointSize
        directCoordinator.baseFont = newValue
        directCoordinator.rebuildTextStorageAndStyle(self, from: storageString)
      }
    }

    public var forwardingDelegate: UITextViewDelegate? {
      get { directCoordinator.forwardingDelegate }
      set { directCoordinator.forwardingDelegate = newValue }
    }

    public var isIntrinsicContentSizeEnabled = true {
      didSet {
        guard isIntrinsicContentSizeEnabled != oldValue else { return }
        invalidateIntrinsicContentSize()
      }
    }

    /// Uses the text view's unconstrained fitting width for horizontal intrinsic sizing while
    /// preserving UIKit's width-constrained intrinsic height.
    public var usesNaturalWidthForIntrinsicContentSize = false {
      didSet {
        guard usesNaturalWidthForIntrinsicContentSize != oldValue else { return }
        invalidateIntrinsicContentSize()
      }
    }

    /// How far a table wider than the text column may scroll out past this view's left and right
    /// edges; top and bottom are ignored. At rest the table still starts on the text column, so a
    /// host can let wide tables run to its own edges. While set, this view stops clipping its
    /// subviews and takes touches on the tables there; the host must not clip that area and must
    /// route its touches here.
    public var tableOverflowInsets: UIEdgeInsets = .zero {
      didSet {
        guard tableOverflowInsets != oldValue else { return }
        clipsToBounds = tableOverflowInsets.left <= 0 && tableOverflowInsets.right <= 0
        setNeedsLayout()
      }
    }

    public var onPasteImage: ((NSPasteboard) -> String?)?

    public override init(frame: CGRect, textContainer: NSTextContainer?) {
      if let textContainer {
        super.init(frame: frame, textContainer: textContainer)
      } else {
        // Overlay geometry uses NSLayoutManager, so start in TextKit 1 instead of switching
        // layout engines during the first layout pass.
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(size: .zero)
        layoutManager.addTextContainer(textContainer)
        super.init(frame: frame, textContainer: textContainer)
      }
      configureMarkdownTextView()
    }

    public required init?(coder: NSCoder) {
      super.init(coder: coder)
      configureMarkdownTextView()
    }

    public override func paste(_ sender: Any?) {
      guard isEditable else {
        super.paste(sender)
        return
      }
      let pasteboard = NSPasteboard.general
      if let imageEmbed = onPasteImage?(pasteboard), !imageEmbed.isEmpty {
        insertBlockEmbed(imageEmbed)
        return
      }
      super.paste(sender)
    }

    public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
      if presses.contains(where: { $0.key?.modifierFlags == .shift }) {
        isShiftPressed = true
      }
      super.pressesBegan(presses, with: event)
    }

    public override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
      if presses.contains(where: { $0.key?.modifierFlags == .shift }) {
        isShiftPressed = false
      }
      super.pressesEnded(presses, with: event)
    }

    public override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
      if presses.contains(where: { $0.key?.modifierFlags == .shift }) {
        isShiftPressed = false
      }
      super.pressesCancelled(presses, with: event)
    }

    public override func layoutSubviews() {
      super.layoutSubviews()
      if (delegate as? NativeTextViewWrapper.Coordinator)?
        .restyleWidthDependentMarkdownImageIfNeeded(self) == true
      {
        return
      }
      updateCodeBlockBackgroundViews()
      updateThematicBreakViews()
      updateTaskCheckboxViews()
      updateTableViews()
      updateSelectionHighlightViews()
      updateLatexImageViews()
      updateVideoViews()
      updateHTMLViews()
      (delegate as? NativeTextViewWrapper.Coordinator)?.updateCodeBlockSelection(self)
    }

    public override func didMoveToWindow() {
      super.didMoveToWindow()
      if window == nil {
        removeEmbeddedMedia()
      } else {
        setNeedsLayout()
      }
    }

    /// Release video playback and HTML page state when a host reuses this view for another message.
    public func removeEmbeddedMedia() {
      for controller in videoControllers.values {
        controller.player?.pause()
        controller.player = nil
        controller.willMove(toParent: nil)
        controller.view.removeFromSuperview()
        controller.removeFromParent()
      }
      videoControllers.removeAll()
      for webView in htmlViews.values {
        webView.stopLoading()
        webView.removeFromSuperview()
      }
      htmlViews.removeAll()
    }

    private func updateVideoViews() {
      guard window != nil else { return }
      var responder: UIResponder? = next
      while let current = responder, !(current is UIViewController) {
        responder = current.next
      }
      guard let parent = responder as? UIViewController else { return }
      var retained = Set<VideoEmbedID>()
      var occurrences: [URL: Int] = [:]
      if let renderedText = attributedText, renderedText.length > 0 {
        layoutManager.ensureLayout(for: textContainer)
        renderedText.enumerateAttribute(
          .markdownVideoURL, in: NSRange(location: 0, length: renderedText.length)
        ) { value, range, _ in
          guard let url = value as? URL, url.isFileURL,
            let bounds =
              (renderedText.attribute(
                .latexBounds, at: range.location, effectiveRange: nil) as? NSValue)?.cgRectValue
          else { return }
          let occurrence = occurrences[url, default: 0]
          occurrences[url] = occurrence + 1
          let id = VideoEmbedID(url: url, occurrence: occurrence)
          let glyphRange = layoutManager.glyphRange(
            forCharacterRange: range, actualCharacterRange: nil)
          guard glyphRange.location != NSNotFound, glyphRange.length > 0 else { return }
          retained.insert(id)
          let lineRect = layoutManager.lineFragmentUsedRect(
            forGlyphAt: glyphRange.location, effectiveRange: nil)
          let controller: AVPlayerViewController
          if let existing = videoControllers[id] {
            controller = existing
          } else {
            controller = AVPlayerViewController()
            controller.player = AVPlayer(url: url)
            controller.videoGravity = .resizeAspect
            controller.allowsPictureInPicturePlayback = false
            parent.addChild(controller)
            addSubview(controller.view)
            controller.didMove(toParent: parent)
            videoControllers[id] = controller
          }
          controller.view.frame = CGRect(
            x: textContainerInset.left,
            y: textContainerInset.top + lineRect.minY + (lineRect.height - bounds.height) / 2,
            width: bounds.width, height: bounds.height)
        }
      }
      // Keep surviving players intact when streaming text or width changes trigger layout.
      for id in Array(videoControllers.keys) where !retained.contains(id) {
        guard let controller = videoControllers.removeValue(forKey: id) else { continue }
        controller.player?.pause()
        controller.player = nil
        controller.willMove(toParent: nil)
        controller.view.removeFromSuperview()
        controller.removeFromParent()
      }
    }

    private func updateHTMLViews() {
      guard window != nil else { return }
      var retained = Set<HTMLEmbedID>()
      var occurrences: [URL: Int] = [:]
      if let renderedText = attributedText, renderedText.length > 0 {
        layoutManager.ensureLayout(for: textContainer)
        renderedText.enumerateAttribute(
          .markdownHTMLURL, in: NSRange(location: 0, length: renderedText.length)
        ) { value, range, _ in
          guard let url = value as? URL,
            let bounds =
              (renderedText.attribute(
                .latexBounds, at: range.location, effectiveRange: nil) as? NSValue)?.cgRectValue
          else { return }
          let occurrence = occurrences[url, default: 0]
          occurrences[url] = occurrence + 1
          let id = HTMLEmbedID(url: url, occurrence: occurrence)
          let glyphRange = layoutManager.glyphRange(
            forCharacterRange: range, actualCharacterRange: nil)
          guard glyphRange.location != NSNotFound, glyphRange.length > 0 else { return }
          retained.insert(id)
          let lineRect = layoutManager.lineFragmentUsedRect(
            forGlyphAt: glyphRange.location, effectiveRange: nil)
          let frame = CGRect(
            x: textContainerInset.left,
            y: textContainerInset.top + lineRect.minY + (lineRect.height - bounds.height) / 2,
            width: bounds.width, height: bounds.height)
          if let webView = htmlViews[id] {
            webView.frame = frame
          } else {
            let webView = WKWebView(frame: frame)
            addSubview(webView)
            htmlViews[id] = webView
            if url.isFileURL {
              webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            } else {
              webView.load(URLRequest(url: url))
            }
          }
        }
      }
      // Preserve page state across streaming text updates and width changes, just like videos.
      for id in Array(htmlViews.keys) where !retained.contains(id) {
        guard let webView = htmlViews.removeValue(forKey: id) else { continue }
        webView.stopLoading()
        webView.removeFromSuperview()
      }
    }

    public override func tintColorDidChange() {
      super.tintColorDidChange()
      updateSelectionHighlightViews()
    }

    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
      super.traitCollectionDidChange(previousTraitCollection)
      guard let previousTraitCollection,
        traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection)
      else { return }
      // Dynamic UIColors in text attributes redraw automatically, but rendered tables and LaTeX
      // are raster images. Rebuild their attributes under this view's effective appearance.
      traitCollection.performAsCurrent {
        (delegate as? NativeTextViewWrapper.Coordinator)?.applyStylePreservingSelection(self)
      }
    }

    public override var canBecomeFirstResponder: Bool {
      super.canBecomeFirstResponder || (isSelectable && isUserInteractionEnabled)
    }

    public override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
      // Wide tables reach past the bounds by tableOverflowInsets; they still scroll from there.
      super.point(inside: point, with: event)
        || tableScrollViews.values.contains { $0.frame.contains(point) }
    }

    public override var intrinsicContentSize: CGSize {
      guard isIntrinsicContentSizeEnabled else {
        return CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
      }
      let intrinsicContentSize = super.intrinsicContentSize
      guard usesNaturalWidthForIntrinsicContentSize else {
        return CGSize(
          width: intrinsicContentSize.width.rounded(), height: intrinsicContentSize.height.rounded()
        )
      }
      let naturalContentSize = sizeThatFits(
        CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
      return CGSize(
        width: min(intrinsicContentSize.width, naturalContentSize.width).rounded(),
        height: intrinsicContentSize.height.rounded())
    }

    public override func caretRect(for position: UITextPosition) -> CGRect {
      var rect = super.caretRect(for: position)
      guard rect.height > 0, textStorage.length > 0 else { return rect }

      let offset = self.offset(from: beginningOfDocument, to: position)
      let location = min(max(offset, 0), textStorage.length - 1)
      let baseFont = self.baseFont
      let font = textStorage.attribute(.font, at: location, effectiveRange: nil) as? UIFont
      let usesHiddenFont =
        (font?.pointSize ?? baseFont.pointSize)
        <= directConfiguration.markers.hiddenMarkerFontSize + 0.5
      let isRenderedBlock =
        (textStorage.attribute(.latexIsBlock, at: location, effectiveRange: nil) as? Bool) == true
      let caretFont = usesHiddenFont ? baseFont : (font ?? baseFont)
      var desiredHeight = ceil(caretFont.lineHeight)
      if !usesHiddenFont && !isRenderedBlock,
        let paragraph = textStorage.attribute(.paragraphStyle, at: location, effectiveRange: nil)
          as? NSParagraphStyle
      {
        if paragraph.minimumLineHeight > 0 {
          desiredHeight = max(desiredHeight, paragraph.minimumLineHeight)
        }
        if paragraph.maximumLineHeight > 0 {
          desiredHeight = min(desiredHeight, paragraph.maximumLineHeight)
        }
      }

      let minimumHeight =
        ceil(baseFont.lineHeight) + directConfiguration.paragraph.lineHeightExtraSpacing
      if desiredHeight < minimumHeight * 0.5 || isRenderedBlock {
        desiredHeight = minimumHeight
      }
      guard abs(rect.height - desiredHeight) > 0.5 else { return rect }
      rect.origin.y += (rect.height - desiredHeight) / 2
      rect.size.height = desiredHeight
      return rect
    }

    private func insertBlockEmbed(_ embed: String) {
      let selection = selectedRange
      let nsText = (text ?? "") as NSString
      var prefix = ""
      var suffix = ""
      if selection.location > 0, nsText.character(at: selection.location - 1) != 0x0A {
        prefix = "\n"
      }
      let afterLocation = selection.location + selection.length
      if afterLocation < nsText.length, nsText.character(at: afterLocation) != 0x0A {
        suffix = "\n"
      }
      textStorage.replaceCharacters(in: selection, with: prefix + embed + suffix)
      delegate?.textViewDidChange?(self)
    }

    private func configureMarkdownTextView() {
      backgroundColor = .clear
      isScrollEnabled = true
      alwaysBounceVertical = true
      textContainer.lineFragmentPadding = 0
      adjustsFontForContentSizeCategory = false
      smartQuotesType = .yes
      smartDashesType = .no
      isSelectable = true
      delegate = directCoordinator
      selectionHighlightView.isUserInteractionEnabled = false
      selectionHighlightView.backgroundColor = .clear
      selectionHighlightView.layer.zPosition = 1
      selectionHighlightView.layer.addSublayer(selectionHighlightLayer)
      insertSubview(selectionHighlightView, at: 0)
      applyMarkdownConfiguration()
    }

    private func applyMarkdownConfiguration() {
      textContainerInset = UIEdgeInsets(
        top: directConfiguration.textInsets.vertical + directConfiguration.safeAreaInsets.top,
        left: directConfiguration.textInsets.horizontal
          + directConfiguration.safeAreaInsets.leading,
        bottom: directConfiguration.textInsets.vertical + directConfiguration.safeAreaInsets.bottom,
        right: directConfiguration.textInsets.horizontal
          + directConfiguration.safeAreaInsets.trailing
      )
      autocorrectionType =
        directConfiguration.spellChecking.automaticSpellingCorrection ? .default : .no
      spellCheckingType =
        directConfiguration.spellChecking.continuousSpellChecking ? .default : .no
      linkTextAttributes = [
        .foregroundColor: directConfiguration.theme.link,
        .underlineStyle: NSUnderlineStyle.single.rawValue,
      ]
    }

    private func updateCodeBlockBackgroundViews() {
      codeBlockBackgroundViews.forEach { $0.removeFromSuperview() }
      codeBlockBackgroundViews.removeAll()

      guard let renderedText = attributedText, renderedText.length > 0 else { return }
      layoutManager.ensureLayout(for: textContainer)
      let fullRange = NSRange(location: 0, length: renderedText.length)
      renderedText.enumerateAttribute(.codeBlockBackground, in: fullRange) {
        [weak self] value, range, _ in
        guard let self, value as? Bool == true else { return }
        guard
          let color = renderedText.attribute(
            .backgroundColor, at: range.location, effectiveRange: nil)
            as? UIColor
        else { return }
        let glyphRange = layoutManager.glyphRange(
          forCharacterRange: range, actualCharacterRange: nil)
        guard glyphRange.location != NSNotFound, glyphRange.length > 0 else { return }
        var backgroundRect = CGRect.null
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) {
          lineRect, _, _, lineGlyphRange, _ in
          guard NSIntersectionRange(lineGlyphRange, glyphRange).length > 0 else { return }
          backgroundRect = backgroundRect.union(lineRect)
        }
        guard !backgroundRect.isNull else { return }
        let backgroundView = UIView(
          frame: CGRect(
            x: textContainerInset.left,
            y: textContainerInset.top + backgroundRect.minY,
            width: textContainer.size.width,
            height: backgroundRect.height
          )
        )
        backgroundView.backgroundColor = color
        backgroundView.isUserInteractionEnabled = false
        insertSubview(backgroundView, at: 0)
        codeBlockBackgroundViews.append(backgroundView)
      }
    }

    private func updateThematicBreakViews() {
      thematicBreakViews.forEach { $0.removeFromSuperview() }
      thematicBreakViews.removeAll()

      guard let renderedText = attributedText, renderedText.length > 0 else { return }
      layoutManager.ensureLayout(for: textContainer)
      let fullRange = NSRange(location: 0, length: renderedText.length)
      renderedText.enumerateAttribute(.thematicBreak, in: fullRange) {
        [weak self] value, range, _ in
        guard let self, value as? Bool == true else { return }
        let glyphRange = layoutManager.glyphRange(
          forCharacterRange: range, actualCharacterRange: nil)
        guard glyphRange.location != NSNotFound, glyphRange.length > 0 else { return }
        let lineRect = layoutManager.lineFragmentRect(
          forGlyphAt: glyphRange.location, effectiveRange: nil)
        let scale = window?.screen.scale ?? UIScreen.main.scale
        let height = 1 / max(scale, 1)
        let ruleView = UIView(
          frame: CGRect(
            x: textContainerInset.left,
            y: textContainerInset.top + lineRect.midY - height / 2,
            width: textContainer.size.width,
            height: height
          )
        )
        ruleView.backgroundColor = directConfiguration.theme.strikethroughColor.withAlphaComponent(
          0.35)
        ruleView.isUserInteractionEnabled = false
        addSubview(ruleView)
        thematicBreakViews.append(ruleView)
      }
    }

    private func updateTaskCheckboxViews() {
      taskCheckboxButtons.forEach { $0.removeFromSuperview() }
      taskCheckboxButtons.removeAll()

      guard let renderedText = attributedText, renderedText.length > 0 else { return }
      layoutManager.ensureLayout(for: textContainer)
      let fullRange = NSRange(location: 0, length: renderedText.length)
      renderedText.enumerateAttribute(.taskCheckbox, in: fullRange) {
        [weak self] value, range, _ in
        guard let self, let isChecked = value as? Bool else { return }
        let glyphRange = layoutManager.glyphRange(
          forCharacterRange: range, actualCharacterRange: nil)
        guard glyphRange.location != NSNotFound, glyphRange.length > 0 else { return }
        let font =
          (renderedText.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont)
          ?? baseFont
        let ascent = max(0, font.ascender)
        let descent = max(0, -font.descender)
        let fontHeight = max(1, ceil(ascent + descent))
        let markerWidth = ("[ ]" as NSString).size(withAttributes: [.font: font]).width
        let configuredSize = min(
          floor(fontHeight * directConfiguration.taskCheckbox.sizeFromFontHeightFactor),
          floor(markerWidth * directConfiguration.taskCheckbox.sizeFromMarkerWidthFactor)
        )
        let symbolSize = max(1, configuredSize)
        let lineFragmentRect = layoutManager.lineFragmentRect(
          forGlyphAt: glyphRange.location, effectiveRange: nil)
        let glyphLocation = layoutManager.location(forGlyphAt: glyphRange.location)
        let glyphX = lineFragmentRect.minX + glyphLocation.x
        let baselineY = lineFragmentRect.minY + glyphLocation.y
        let hitWidth = max(markerWidth, symbolSize)
        let hitHeight = max(fontHeight, symbolSize)
        let frame = CGRect(
          x: textContainerInset.left + glyphX + (markerWidth - hitWidth) / 2,
          y: textContainerInset.top + baselineY - ascent + (fontHeight - hitHeight) / 2,
          width: hitWidth,
          height: hitHeight
        ).integral
        guard !frame.isEmpty, !frame.isNull else { return }

        let button = TaskCheckboxButton(checkboxRange: range, isChecked: isChecked)
        button.frame = frame
        button.backgroundColor = .clear
        button.tintColor =
          isChecked
          ? directConfiguration.theme.bodyText
          : directConfiguration.theme.mutedText
        button.isUserInteractionEnabled = isEditable
        button.layer.zPosition = 2
        button.accessibilityLabel = "Task"
        button.accessibilityValue = isChecked ? "Checked" : "Unchecked"
        let symbolName = isChecked ? "checkmark.square.fill" : "square"
        let symbolConfiguration = UIImage.SymbolConfiguration(
          pointSize: symbolSize,
          weight: .regular
        )
        button.setImage(
          UIImage(systemName: symbolName, withConfiguration: symbolConfiguration),
          for: .normal
        )
        button.addTarget(self, action: #selector(didTapTaskCheckbox(_:)), for: .touchUpInside)
        addSubview(button)
        taskCheckboxButtons.append(button)
      }
    }

    @objc private func didTapTaskCheckbox(_ sender: UIButton) {
      guard let button = sender as? TaskCheckboxButton, isEditable else { return }
      let range = button.checkboxRange
      let nsText = (text ?? "") as NSString
      guard range.location >= 0, NSMaxRange(range) <= nsText.length else { return }
      let checkboxText = nsText.substring(with: range)
      guard checkboxText.range(of: #"\[[ xX]\]"#, options: .regularExpression) != nil else {
        return
      }
      let replacement = button.isCheckedTask ? "[ ]" : "[x]"
      guard
        delegate?.textView?(
          self,
          shouldChangeTextIn: range,
          replacementText: replacement
        ) ?? true
      else { return }
      let previousSelection = selectedRange
      textStorage.replaceCharacters(in: range, with: replacement)
      selectedRange = previousSelection
      delegate?.textViewDidChange?(self)
    }

    private func updateTableViews() {
      tableImageViews.forEach { $0.removeFromSuperview() }
      tableImageViews.removeAll()

      var retainedSourceIDs = Set<Int>()
      defer {
        for sourceID in Array(tableScrollViews.keys) where !retainedSourceIDs.contains(sourceID) {
          guard let scrollView = tableScrollViews.removeValue(forKey: sourceID) else { continue }
          tableHorizontalScrollOffsets[sourceID] =
            scrollView.contentOffset.x + scrollView.contentInset.left
          tableScrollIndicatorControllers.removeValue(forKey: sourceID)?.view.removeFromSuperview()
          scrollView.removeFromSuperview()
        }
      }
      guard let renderedText = attributedText, renderedText.length > 0 else { return }
      layoutManager.ensureLayout(for: textContainer)
      let fullRange = NSRange(location: 0, length: renderedText.length)
      renderedText.enumerateAttribute(.renderedTableImage, in: fullRange) {
        [weak self] value, range, _ in
        guard let self, let image = value as? UIImage else { return }
        let glyphRange = layoutManager.glyphRange(
          forCharacterRange: range, actualCharacterRange: nil)
        guard glyphRange.location != NSNotFound, glyphRange.length > 0 else { return }
        let imageBounds =
          (renderedText.attribute(.renderedTableBounds, at: range.location, effectiveRange: nil)
          as? NSValue)?.cgRectValue ?? CGRect(origin: .zero, size: image.size)
        let sourceID =
          (renderedText.attribute(.renderedTableSourceID, at: range.location, effectiveRange: nil)
            as? Int) ?? range.location
        let usedLineRect = layoutManager.lineFragmentUsedRect(
          forGlyphAt: glyphRange.location, effectiveRange: nil)
        let availableWidth = max(0, textContainer.size.width)
        if availableWidth <= 0 { return }
        let displayWidth = min(imageBounds.width, availableWidth)
        let x = textContainerInset.left
        let y =
          textContainerInset.top + usedLineRect.minY
          + max(0, (usedLineRect.height - imageBounds.height) / 2)

        if imageBounds.width > availableWidth + 0.5 {
          retainedSourceIDs.insert(sourceID)
          // The scroll area reaches into the overflow on both sides; its content insets rest the
          // table on the text column and let it scroll out to the overflow edges.
          let overflowLeft = max(0, tableOverflowInsets.left)
          let overflowRight = max(0, tableOverflowInsets.right)
          let frame = CGRect(
            x: x - overflowLeft,
            y: y,
            width: overflowLeft + displayWidth + overflowRight,
            height: imageBounds.height
          )
          let contentInset = UIEdgeInsets(
            top: 0, left: overflowLeft, bottom: 0, right: overflowRight)
          let scrollView: RenderedTableScrollView
          let restingOffset: CGFloat
          // Streaming text and window resizes lay this view out repeatedly; keep the table's
          // scroll view so a scroll in progress survives, and only re-place it when it moved.
          if let existing = tableScrollViews[sourceID] {
            existing.imageView.image = image
            guard
              existing.frame != frame || existing.contentInset != contentInset
                || existing.contentSize != imageBounds.size
            else { return }
            scrollView = existing
            restingOffset = existing.contentOffset.x + existing.contentInset.left
          } else {
            scrollView = RenderedTableScrollView(frame: .zero)
            scrollView.imageView.image = image
            addSubview(scrollView)
            tableScrollViews[sourceID] = scrollView
            #if targetEnvironment(macCatalyst)
              let scrollIndicatorController = HorizontalScrollIndicatorController(
                scrollView: scrollView)
              addSubview(scrollIndicatorController.view)
              tableScrollIndicatorControllers[sourceID] = scrollIndicatorController
            #endif
            restingOffset = tableHorizontalScrollOffsets[sourceID] ?? 0
          }
          let scrollIndicatorController = tableScrollIndicatorControllers[sourceID]
          // Placing the table is not a scroll; keep its indicator from flashing.
          scrollView.delegate = nil
          scrollView.frame = frame
          scrollView.contentInset = contentInset
          scrollView.horizontalScrollIndicatorInsets = contentInset
          scrollView.imageView.frame = CGRect(origin: .zero, size: imageBounds.size)
          scrollView.contentSize = imageBounds.size
          let maxOffset = max(0, imageBounds.width - displayWidth)
          scrollView.contentOffset = CGPoint(
            x: min(max(restingOffset, 0), maxOffset) - overflowLeft, y: 0)
          scrollView.delegate = scrollIndicatorController?.objCResponder
          scrollIndicatorController?.view.frame = CGRect(
            x: frame.minX, y: frame.maxY - 12, width: frame.width, height: 12)
        } else {
          let imageView = UIImageView(
            frame: CGRect(
              x: x,
              y: y,
              width: imageBounds.width,
              height: imageBounds.height
            )
          )
          imageView.image = image
          imageView.contentMode = .scaleAspectFit
          imageView.isUserInteractionEnabled = false
          addSubview(imageView)
          tableImageViews.append(imageView)
        }
      }
    }

    fileprivate func updateSelectionHighlightViews() {
      let overlaySize = CGSize(
        width: max(contentSize.width, bounds.width),
        height: max(contentSize.height, bounds.height))
      selectionHighlightView.frame = CGRect(origin: .zero, size: overlaySize)
      selectionHighlightLayer.frame = selectionHighlightView.bounds

      guard isSelectable, selectedRange.length > 0, textStorage.length > 0 else {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        selectionHighlightLayer.path = nil
        CATransaction.commit()
        return
      }
      let clampedSelectionRange = NSIntersectionRange(
        self.selectedRange, NSRange(location: 0, length: textStorage.length))
      guard clampedSelectionRange.length > 0 else {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        selectionHighlightLayer.path = nil
        CATransaction.commit()
        return
      }

      layoutManager.ensureLayout(for: textContainer)
      let glyphRange = layoutManager.glyphRange(
        forCharacterRange: clampedSelectionRange, actualCharacterRange: nil)
      guard glyphRange.location != NSNotFound, glyphRange.length > 0 else {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        selectionHighlightLayer.path = nil
        CATransaction.commit()
        return
      }

      let path = UIBezierPath()
      let color = (tintColor ?? UIColor.systemBlue).withAlphaComponent(0.28)
      layoutManager.enumerateEnclosingRects(
        forGlyphRange: glyphRange,
        withinSelectedGlyphRange: glyphRange,
        in: textContainer
      ) { rect, _ in
        guard rect.width > 0, rect.height > 0 else { return }
        path.append(
          UIBezierPath(
            rect: CGRect(
              x: self.textContainerInset.left + rect.minX,
              y: self.textContainerInset.top + rect.minY,
              width: rect.width,
              height: rect.height
            ).integral)
        )
      }
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      selectionHighlightLayer.fillColor = color.cgColor
      selectionHighlightLayer.path = path.cgPath
      CATransaction.commit()
    }

    private func updateLatexImageViews() {
      latexImageViews.forEach { $0.removeFromSuperview() }
      latexImageViews.removeAll()

      guard let renderedText = attributedText, renderedText.length > 0 else { return }
      layoutManager.ensureLayout(for: textContainer)
      let fullRange = NSRange(location: 0, length: renderedText.length)
      renderedText.enumerateAttribute(.latexImage, in: fullRange) {
        [weak self] value, range, _ in
        guard let self, let image = value as? UIImage else { return }
        let glyphRange = layoutManager.glyphRange(
          forCharacterRange: range, actualCharacterRange: nil)
        guard glyphRange.location != NSNotFound, glyphRange.length > 0 else { return }

        let imageBounds =
          (renderedText.attribute(.latexBounds, at: range.location, effectiveRange: nil) as? NSValue)?
          .cgRectValue ?? CGRect(origin: .zero, size: image.size)
        let isBlock =
          (renderedText.attribute(.latexIsBlock, at: range.location, effectiveRange: nil) as? Bool)
          ?? false
        let isMarkdownImageBlock =
          (renderedText.attribute(.markdownImageBlock, at: range.location, effectiveRange: nil)
            as? Bool) ?? false
        let lineFragmentRect = layoutManager.lineFragmentRect(
          forGlyphAt: glyphRange.location, effectiveRange: nil)
        let usedLineRect = layoutManager.lineFragmentUsedRect(
          forGlyphAt: glyphRange.location, effectiveRange: nil)
        // A self-sizing cell can still have its estimated height here. TextKit returns
        // an empty rect for paragraphs that do not fit yet; never place an image there.
        guard !usedLineRect.isEmpty else { return }
        let glyphLocation = layoutManager.location(forGlyphAt: glyphRange.location)
        let x: CGFloat
        let y: CGFloat
        if isBlock {
          x =
            isMarkdownImageBlock
            ? 0 : max(0, (textContainer.size.width - imageBounds.width) / 2)
          y = usedLineRect.minY + (usedLineRect.height - imageBounds.height) / 2
        } else {
          x = lineFragmentRect.minX + glyphLocation.x
          let baselineY = lineFragmentRect.minY + glyphLocation.y
          y = baselineY + imageBounds.origin.y - imageBounds.height
        }
        let imageView = UIImageView(
          frame: CGRect(
            x: textContainerInset.left + x,
            y: textContainerInset.top + y,
            width: imageBounds.width,
            height: imageBounds.height
          )
        )
        imageView.image = image
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = false
        addSubview(imageView)
        latexImageViews.append(imageView)
      }
    }
  }

  extension MarkdownEditorConfiguration {
    fileprivate var changeCount: Int {
      var hasher = Hasher()
      hasher.combine(ObjectIdentifier(theme.bodyText))
      hasher.combine(ObjectIdentifier(theme.mutedText))
      hasher.combine(ObjectIdentifier(theme.disabledText))
      hasher.combine(ObjectIdentifier(theme.headingMarker))
      hasher.combine(ObjectIdentifier(theme.link))
      hasher.combine(ObjectIdentifier(theme.incompleteLink))
      hasher.combine(ObjectIdentifier(theme.strikethroughColor))
      hasher.combine(markers.hiddenMarkerFontSize)
      hasher.combine(markers.inlineCodeMarkerAlpha)
      hasher.combine(codeBlock.fontSizeScale)
      hasher.combine(codeBlock.paragraphSpacing)
      hasher.combine(codeBlock.horizontalIndent)
      hasher.combine(inlineCode.fontSizeScale)
      hasher.combine(lists.helpersEnabled)
      hasher.combine(lists.autoClosePairsEnabled)
      hasher.combine(lists.indentPerLevel)
      hasher.combine(lists.maximumNestingLevel)
      hasher.combine(lists.extraLineHeight)
      hasher.combine(headings.fontMultipliers)
      hasher.combine(headings.topSpacingEm)
      hasher.combine(imageEmbed.minimumWidth)
      hasher.combine(imageEmbed.fallbackMaxWidth)
      hasher.combine(imageEmbed.unreasonableMaxWidth)
      hasher.combine(imageEmbed.paragraphSpacing)
      hasher.combine(imageEmbed.imageGap)
      hasher.combine(link.activeLinkAlpha)
      hasher.combine(link.incompleteLinkAlpha)
      hasher.combine(link.automaticLinkDetectionEnabled)
      hasher.combine(paragraph.spacingFactor)
      hasher.combine(paragraph.lineHeightExtraSpacing)
      hasher.combine(textInsets.horizontal)
      hasher.combine(textInsets.vertical)
      hasher.combine(safeAreaInsets.top)
      hasher.combine(safeAreaInsets.leading)
      hasher.combine(safeAreaInsets.trailing)
      hasher.combine(safeAreaInsets.bottom)
      hasher.combine(spellChecking.continuousSpellChecking)
      hasher.combine(spellChecking.grammarChecking)
      hasher.combine(spellChecking.automaticSpellingCorrection)
      hasher.combine(services.images.fingerprint())
      hasher.combine(services.videos.fingerprint())
      hasher.combine(services.html.fingerprint())
      return hasher.finalize()
    }
  }
#endif
