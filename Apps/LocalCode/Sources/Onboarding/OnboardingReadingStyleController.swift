import Components
import Localization
import SQLiteDflat
import SnapKit
import Style
import UIKit

protocol OnboardingReadingStyleControllerDelegate: AnyObject {
  func onboardingReadingStyleController(
    _ controller: OnboardingReadingStyleController,
    didSelectTextSize textSize: OnboardingState.TextSize)
  func onboardingReadingStyleController(
    _ controller: OnboardingReadingStyleController, didSelectTextFontFamily family: String?)
  func onboardingReadingStyleController(
    _ controller: OnboardingReadingStyleController, didSelectChatWidth chatWidth: ChatWidth)
}

/// The reading style page's content: a miniature of the chat, and beside it the choices of message
/// text size, text font and chat width. A choice shows on the miniature and in the glyphs of the
/// other choices.
final class OnboardingReadingStyleController {
  weak var delegate: OnboardingReadingStyleControllerDelegate?

  var view: UIView { stack }

  /// Nil when the message zoom is none of the sizes offered.
  var textSize: OnboardingState.TextSize? = .normal {
    didSet {
      for (textSize, controller) in textSizeControllers {
        controller.isSelected = textSize == self.textSize
      }
    }
  }
  /// A font family name, or nil for the system font.
  var textFontFamily: String? {
    didSet {
      for (family, controller) in textFontControllers {
        controller.isSelected = family == textFontFamily
      }
    }
  }
  var chatWidth = ChatWidth.normal {
    didSet {
      for (chatWidth, controller) in chatWidthControllers {
        controller.isSelected = chatWidth == self.chatWidth
      }
      previewController.chatWidth = chatWidth
    }
  }
  /// Stacks the miniature above the choices when the page is too narrow for both.
  var isCompact = false {
    didSet {
      guard isCompact != oldValue else { return }
      stack.axis = isCompact ? .vertical : .horizontal
      stack.alignment = isCompact ? .fill : .center
      if isCompact {
        previewWidthConstraint?.deactivate()
      } else {
        previewWidthConstraint?.activate()
      }
    }
  }

  private let previewController: OnboardingChatPreviewController
  private lazy var stack: UIStackView = {
    let stack = UIStackView()
    stack.alignment = .center
    stack.spacing = 16
    return stack
  }()
  private lazy var choicesStack: UIStackView = {
    let stack = UIStackView()
    stack.axis = .vertical
    stack.spacing = 20
    return stack
  }()
  private lazy var textSizeTitleLabel: UILabel = {
    let label = UILabel()
    label.text = LocalizedString.forKey("text_size")
    label.textColor = .primaryText
    FontMetrics.default.scaleFont(.systemFont(ofSize: 13, weight: .medium), bindTo: label)
    return label
  }()
  private lazy var textFontTitleLabel: UILabel = {
    let label = UILabel()
    label.text = LocalizedString.forKey("font")
    label.textColor = .primaryText
    FontMetrics.default.scaleFont(.systemFont(ofSize: 13, weight: .medium), bindTo: label)
    return label
  }()
  private lazy var chatWidthTitleLabel: UILabel = {
    let label = UILabel()
    label.text = LocalizedString.forKey("chat_width")
    label.textColor = .primaryText
    FontMetrics.default.scaleFont(.systemFont(ofSize: 13, weight: .medium), bindTo: label)
    return label
  }()
  private lazy var textSizeControllers:
    [(textSize: OnboardingState.TextSize, controller: OnboardingChoiceController)] =
      OnboardingState.TextSize.allCases.map { textSize in
        // An A at the size, in the text font chosen.
        let glyphLabel = UILabel()
        glyphLabel.text = "A"
        glyphLabel.textColor = .primaryText
        FontMetrics.default.scaleFont(
          .systemFont(ofSize: 20 * CGFloat(textSize.rawValue) / 100), bindTo: glyphLabel
        ) {
          $0.font = MarkdownFonts.default.textFont(replacing: $1)
        }
        let title: String
        switch textSize {
        case .smaller: title = LocalizedString.forKey("smaller")
        case .normal: title = LocalizedString.forKey("normal")
        case .bigger: title = LocalizedString.forKey("bigger")
        }
        let controller = OnboardingChoiceController(title: title, glyphView: glyphLabel)
        controller.delegate = self
        controller.isSelected = textSize == self.textSize
        return (textSize, controller)
      }
  // The system font, then the bundled text fonts this build has.
  private lazy var textFontControllers:
    [(family: String?, controller: OnboardingChoiceController)] =
      ([nil] + MarkdownFonts.default.textFamilies).map { family in
        // The font's own letters, at the message text size chosen.
        let glyphLabel = UILabel()
        glyphLabel.text = "Aa"
        glyphLabel.textColor = .primaryText
        FontMetrics.default.scaleFont(.systemFont(ofSize: 20), bindTo: glyphLabel) {
          let font = MarkdownFonts.default.textFont(replacing: $1, family: family)
          $0.font = font.withSize(
            font.pointSize * CGFloat(MarkdownFonts.default.messageZoom) / 100)
        }
        // The font's name is in the font too.
        let controller = OnboardingChoiceController(
          title: family ?? LocalizedString.forKey("system"), titleFontFamily: family,
          glyphView: glyphLabel)
        controller.delegate = self
        controller.isSelected = family == textFontFamily
        return (family, controller)
      }
  private lazy var chatWidthControllers:
    [(chatWidth: ChatWidth, controller: OnboardingChoiceController)] =
      ChatWidth.allCases.map { chatWidth in
        // A window with lines of text as wide as the chat gets in it.
        let glyphView = BorderView.defaultBorderView(cornerRadius: 5)
        glyphView.borderColor = .senaryText
        glyphView.layer.borderWidth = 1.5
        let lines = UIStackView()
        lines.axis = .vertical
        lines.spacing = 3
        for _ in 0..<3 {
          let line = UIView(frame: .zero)
          line.backgroundColor = .primaryText
          line.layer.cornerRadius = 1
          lines.addArrangedSubview(line)
          line.snp.makeConstraints { make in
            make.height.equalTo(2)
          }
        }
        glyphView.addSubview(lines)
        glyphView.snp.makeConstraints { make in
          make.width.equalTo(48)
          make.height.equalTo(28)
        }
        lines.snp.makeConstraints { make in
          make.center.equalToSuperview()
          make.width.equalTo(chatWidth == .wide ? 36 : 20)
        }
        let title: String
        switch chatWidth {
        case .normal: title = LocalizedString.forKey("normal")
        case .wide: title = LocalizedString.forKey("wide")
        }
        let controller = OnboardingChoiceController(title: title, glyphView: glyphView)
        controller.delegate = self
        controller.isSelected = chatWidth == self.chatWidth
        return (chatWidth, controller)
      }
  private var previewWidthConstraint: Constraint?

  init(workspace: SQLiteWorkspace, userInterfaceIdiom: UIUserInterfaceIdiom) {
    previewController = OnboardingChatPreviewController(
      workspace: workspace, userInterfaceIdiom: userInterfaceIdiom)
    stack.addArrangedSubview(previewController.view)
    stack.addArrangedSubview(choicesStack)
    previewController.view.snp.makeConstraints { make in
      previewWidthConstraint = make.width.equalTo(400).priority(.high).constraint
      make.width.lessThanOrEqualTo(stack)
    }

    let textSizeRow = UIStackView(arrangedSubviews: textSizeControllers.map(\.controller.view))
    textSizeRow.spacing = 8
    textSizeRow.distribution = .fillEqually
    let textSizeGroup = UIStackView(arrangedSubviews: [textSizeTitleLabel, textSizeRow])
    textSizeGroup.axis = .vertical
    textSizeGroup.spacing = 8
    choicesStack.addArrangedSubview(textSizeGroup)

    // A build without the bundled text fonts has only the system font to offer.
    if textFontControllers.count > 1 {
      let textFontRow = UIStackView(arrangedSubviews: textFontControllers.map(\.controller.view))
      textFontRow.spacing = 8
      textFontRow.distribution = .fillEqually
      let textFontGroup = UIStackView(arrangedSubviews: [textFontTitleLabel, textFontRow])
      textFontGroup.axis = .vertical
      textFontGroup.spacing = 8
      choicesStack.addArrangedSubview(textFontGroup)
    }

    // Only a Mac window has the room for the chat width to matter, as in Machine Settings.
    #if targetEnvironment(macCatalyst)
      let chatWidthRow = UIStackView(arrangedSubviews: chatWidthControllers.map(\.controller.view))
      chatWidthRow.spacing = 8
      chatWidthRow.distribution = .fillEqually
      let chatWidthGroup = UIStackView(arrangedSubviews: [chatWidthTitleLabel, chatWidthRow])
      chatWidthGroup.axis = .vertical
      chatWidthGroup.spacing = 8
      choicesStack.addArrangedSubview(chatWidthGroup)
    #endif
  }
}

extension OnboardingReadingStyleController: OnboardingChoiceControllerDelegate {
  func onboardingChoiceControllerDidSelect(_ controller: OnboardingChoiceController) {
    if let textSize = textSizeControllers.first(where: { $0.controller === controller })?.textSize {
      delegate?.onboardingReadingStyleController(self, didSelectTextSize: textSize)
    } else if let choice = textFontControllers.first(where: { $0.controller === controller }) {
      delegate?.onboardingReadingStyleController(self, didSelectTextFontFamily: choice.family)
    } else if let chatWidth = chatWidthControllers.first(where: { $0.controller === controller })?
      .chatWidth
    {
      delegate?.onboardingReadingStyleController(self, didSelectChatWidth: chatWidth)
    }
  }
}
