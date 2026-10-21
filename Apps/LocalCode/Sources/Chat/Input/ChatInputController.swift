import Components
import Localization
import MarkdownEngine
import MarkdownEngineCodeBlocks
import MarkdownEngineLatex
import PhotosUI
import SQLiteDflat
import SnapKit
import Style
import UIKit

enum ChatInputSendState: Equatable {
  case idle
  case sending
  case stopping
}

protocol ChatInputControllerDelegate: AnyObject {
  func chatInputController(
    _ controller: ChatInputController, currentText: String, shouldChangeTextIn range: NSRange,
    replacementText text: String)
  func chatInputControllerDidBeginEditing(_ controller: ChatInputController)
  func chatInputControllerDidEndEditing(_ controller: ChatInputController)
  func chatInputController(_ controller: ChatInputController, didRequestHistorySeek edits: Int)
  func chatInputControllerDidTapSend(_ controller: ChatInputController)
  func chatInputControllerDidTapStop(_ controller: ChatInputController)
  func chatInputController(
    _ controller: ChatInputController, didTapModelSelector sourceView: UIView)
  func chatInputController(
    _ controller: ChatInputController, present viewController: UIViewController)
}

final class ChatInputController {
  weak var delegate: ChatInputControllerDelegate?

  let view: UIView

  var text: String {
    textView.text ?? ""
  }

  var attachments: [ChatAttachment] {
    attachmentController.attachments
  }

  var isImportingAttachments: Bool {
    attachmentController.isImporting
  }

  var isEmptyState = true {
    didSet {
      guard oldValue != isEmptyState else { return }
      updatePlaceholderText()
    }
  }

  var maxTextHistoryPointer: Int {
    get { Int(textSlider.maximumValue.rounded()) }
    set {
      textSlider.maximumValue = Float(max(0, newValue))
      textHistoryPointer = min(textHistoryPointer, maxTextHistoryPointer)
      updateRedoUndoState()
    }
  }

  var textHistoryPointer: Int {
    get { Int(textSlider.value.rounded()) }
    set {
      let value = min(max(0, newValue), maxTextHistoryPointer)
      textSlider.value = Float(value)
      updateRedoUndoState()
    }
  }

  var sendState: ChatInputSendState = .idle {
    didSet {
      guard oldValue != sendState else { return }
      updateSendControl(animated: true)
    }
  }

  private static let defaultTextViewMaxHeight: CGFloat = 152
  private let workspace: SQLiteWorkspace
  private let objCResponder: ObjCResponder
  private var textViewMaxHeight: CGFloat
  private var textViewHeightLessThanOrEqualToConstraint: Constraint?
  private var textViewHeightEqualToConstraint: Constraint?
  private var resizeHandleStartLocation: CGPoint?
  private var resizeHandleStartTextViewMaxHeight: CGFloat?
  private var resizeHandleStartTextViewHeight: CGFloat?
  private var resizeHandleShouldUpdate = false
  private var resizePhantomView: UIView?
  private var resizePhantomLowerCornersView: UIView?
  private var resizePhantomViewHeightConstraint: Constraint?
  private var resizePhantomViewHeight: CGFloat?
  private var resizePhantomViewHeightLast: CGFloat = 0
  private var sendControlWidthConstraint: Constraint?
  private var sendButtonWidthConstraint: Constraint?
  private var stopButtonWidthConstraint: Constraint?
  private var stopButtonLeadingToDividerConstraint: Constraint?
  private var stopButtonLeadingToSuperviewConstraint: Constraint?
  private var attachmentViewHeightConstraint: Constraint?

  private var placeholderText: String {
    if isEmptyState {
      return LocalizedString.forKey("what_should_we_build_question_mark")
    } else {
      return LocalizedString.forKey("ask_a_follow_up_question_dot")
    }
  }

  private lazy var shadow2: ShadowView = {
    let view = ShadowView(frame: .zero)
    view.cornerRadius = 32
    view.contentInsets = UIEdgeInsets(top: -6, left: -6, bottom: -6, right: -6)
    view.backgroundColor = .novemdecenaryBackground
    view.layer.cornerRadius = 26
    view.layer.shadowColor = UIColor.black.cgColor
    view.layer.shadowOffset = CGSize(width: 0, height: 4)
    view.layer.shadowRadius = 6
    view.layer.shadowOpacity = 0.16
    return view
  }()

  private lazy var resizeHandleView: UIView = {
    let view = UIView(frame: .zero)
    view.backgroundColor = .sedecenaryBackground
    view.layer.cornerRadius = 2.5
    return view
  }()

  private lazy var resizeHandleBackgroundView: UIView = {
    let view = UIView(frame: .zero)
    view.addSubview(resizeHandleView)
    view.isUserInteractionEnabled = true
    resizeHandleView.snp.makeConstraints { make in
      make.width.equalToSuperview()
      make.height.equalTo(5)
      make.center.equalToSuperview()
    }
    return view
  }()

  private lazy var placeholderView: MarkdownTextView = {
    let textView = MarkdownTextView(frame: .zero, textContainer: nil)
    textView.backgroundColor = .clear
    textView.returnKeyType = .done
    textView.configuration = MarkdownEditorConfiguration(
      theme: MarkdownEditorTheme(
        bodyText: .septenaryText,
        mutedText: .septenaryText,
        disabledText: .septenaryText,
        headingMarker: .septenaryText,
        link: .colorPalette(for: .blue),
        incompleteLink: .colorPalette(for: .blue),
        latexLightModeText: .primaryText,
        latexDarkModeText: .primaryText,
        strikethroughColor: .primaryText
      ),
      services: MarkdownEditorServices(
        syntaxHighlighter: MarkdownSyntaxHighlighter.shared,
        latex: SwiftMathBridge()
      ),
      paragraph: ParagraphStyle(spacingFactor: 0, lineHeightExtraSpacing: 0),
      textInsets: TextInsets(horizontal: 0, vertical: 0),
      spellChecking: SpellCheckingPolicy(
        continuousSpellChecking: false, grammarChecking: false,
        automaticSpellingCorrection: false),
      extensions: [StrikethroughExtension()]
    )
    FontMetrics.default.scaleFont(.systemFont(ofSize: 15), bindTo: textView) {
      $0.baseFont = $1
    }
    textView.text = placeholderText
    textView.textColor = .septenaryText
    textView.tintColor = .colorPalette(for: .blue)
    textView.smartQuotesType = .no
    textView.smartInsertDeleteType = .no
    textView.smartDashesType = .no
    textView.autocorrectionType = .no
    textView.showsVerticalScrollIndicator = false
    textView.showsHorizontalScrollIndicator = false
    textView.isUserInteractionEnabled = false
    textView.isScrollEnabled = false
    textView.forwardingDelegate = objCResponder
    textView.scrollsToTop = false
    textView.isEditable = false
    textView.isSelectable = false
    textView.textContainerInset = UIEdgeInsets(top: 10, left: 0, bottom: 16, right: 16)
    textView.scrollIndicatorInsets = UIEdgeInsets(top: 10, left: 0, bottom: 16, right: 0)
    textView.clipsToBounds = true
    return textView
  }()

  private lazy var teleportView: MarkdownTextView = {
    let textView = MarkdownTextView(frame: .zero, textContainer: nil)
    textView.backgroundColor = .clear
    textView.returnKeyType = .done
    textView.configuration = MarkdownEditorConfiguration(
      theme: MarkdownEditorTheme(
        bodyText: .primaryText,
        mutedText: .septenaryText,
        disabledText: .septenaryText,
        headingMarker: .septenaryText,
        link: .colorPalette(for: .blue),
        incompleteLink: .colorPalette(for: .blue),
        latexLightModeText: .primaryText,
        latexDarkModeText: .primaryText,
        strikethroughColor: .primaryText
      ),
      services: MarkdownEditorServices(
        syntaxHighlighter: MarkdownSyntaxHighlighter.shared,
        latex: SwiftMathBridge()
      ),
      paragraph: ParagraphStyle(spacingFactor: 0, lineHeightExtraSpacing: 0),
      textInsets: TextInsets(horizontal: 0, vertical: 0),
      spellChecking: SpellCheckingPolicy(
        continuousSpellChecking: false, grammarChecking: false,
        automaticSpellingCorrection: false),
      extensions: [StrikethroughExtension()]
    )
    FontMetrics.default.scaleFont(.systemFont(ofSize: 15), bindTo: textView) {
      $0.baseFont = $1
    }
    textView.string = placeholderText
    textView.textColor = .primaryText
    textView.smartQuotesType = .no
    textView.smartInsertDeleteType = .no
    textView.smartDashesType = .no
    textView.autocorrectionType = .no
    textView.showsVerticalScrollIndicator = false
    textView.showsHorizontalScrollIndicator = false
    textView.alwaysBounceVertical = false
    textView.isUserInteractionEnabled = false
    textView.isScrollEnabled = false
    textView.scrollsToTop = false
    textView.isEditable = false
    textView.isSelectable = false
    textView.setContentCompressionResistancePriority(.required, for: .vertical)
    textView.setContentHuggingPriority(.required, for: .vertical)
    textView.textContainerInset = UIEdgeInsets(top: 10, left: 0, bottom: 16, right: 16)
    textView.scrollIndicatorInsets = UIEdgeInsets(top: 10, left: 0, bottom: 16, right: 0)
    textView.clipsToBounds = true
    return textView
  }()

  private lazy var textView: MarkdownTextView = {
    let textView = MarkdownTextView(frame: .zero, textContainer: nil)
    // Dropped text and text files become attachments rather than being pasted in.
    if let textDropInteraction = textView.textDropInteraction {
      textView.removeInteraction(textDropInteraction)
    }
    textView.backgroundColor = .clear
    textView.returnKeyType = .done
    textView.configuration = MarkdownEditorConfiguration(
      theme: MarkdownEditorTheme(
        bodyText: .primaryText,
        mutedText: .septenaryText,
        disabledText: .septenaryText,
        headingMarker: .septenaryText,
        link: .colorPalette(for: .blue),
        incompleteLink: .colorPalette(for: .blue),
        latexLightModeText: .primaryText,
        latexDarkModeText: .primaryText,
        strikethroughColor: .primaryText
      ),
      services: MarkdownEditorServices(
        syntaxHighlighter: MarkdownSyntaxHighlighter.shared,
        latex: SwiftMathBridge()
      ),
      paragraph: ParagraphStyle(spacingFactor: 0, lineHeightExtraSpacing: 0),
      textInsets: TextInsets(horizontal: 0, vertical: 0),
      spellChecking: SpellCheckingPolicy(
        continuousSpellChecking: false, grammarChecking: false,
        automaticSpellingCorrection: false),
      extensions: [StrikethroughExtension()]
    )
    FontMetrics.default.scaleFont(.systemFont(ofSize: 15), bindTo: textView) {
      $0.baseFont = $1
    }
    textView.textColor = .primaryText
    textView.tintColor = .colorPalette(for: .blue)
    textView.smartQuotesType = .no
    textView.smartInsertDeleteType = .no
    textView.smartDashesType = .no
    textView.autocorrectionType = .no
    textView.showsVerticalScrollIndicator = false
    textView.showsHorizontalScrollIndicator = false
    textView.forwardingDelegate = objCResponder
    textView.scrollsToTop = false
    textView.textContainerInset = UIEdgeInsets(top: 10, left: 0, bottom: 16, right: 16)
    textView.scrollIndicatorInsets = UIEdgeInsets(top: 10, left: 0, bottom: 16, right: 0)
    textView.clipsToBounds = true
    return textView
  }()

  private let textViewTopBlurMaskLayer: CAGradientLayer = {
    let gradientLayer = CAGradientLayer()
    gradientLayer.colors = [
      UIColor.white.cgColor,
      UIColor.white.withAlphaComponent(0.8).cgColor,
      UIColor.white.withAlphaComponent(0).cgColor,
    ]
    gradientLayer.locations = [0, 0.2, 1]
    return gradientLayer
  }()
  private lazy var textViewTopBlurView: LayoutVisualEffectView = {
    let visualEffectView = LayoutVisualEffectView(
      effect: UIBlurEffect(style: .systemThickMaterial))
    visualEffectView.isUserInteractionEnabled = false
    visualEffectView.layer.mask = textViewTopBlurMaskLayer
    let maskLayer = textViewTopBlurMaskLayer
    visualEffectView.onLayoutChange = { view in
      guard maskLayer.frame != view.bounds else { return }
      maskLayer.frame = view.bounds
    }
    let shadeView = UIView(frame: .zero)
    shadeView.backgroundColor = .novemdecenaryBackground
    visualEffectView.contentView.addSubview(shadeView)
    shadeView.snp.makeConstraints { make in
      make.edges.equalToSuperview()
    }
    return visualEffectView
  }()

  private lazy var undoButton: UIButton = {
    let button = UIButton(type: .custom)
    var configuration = UIButton.Configuration.filled()
    configuration.background.cornerRadius = 0
    configuration.background.backgroundColor = .clear
    configuration.baseForegroundColor = .senaryText
    configuration.image = #imageLiteral(resourceName: "undo-16").withRenderingMode(
      .alwaysTemplate)
    configuration.contentInsets = NSDirectionalEdgeInsets(
      top: 8, leading: 12, bottom: 8, trailing: 10)
    button.configurationUpdateHandler = {
      guard var configuration = $0.configuration else { return }
      if $0.state.contains(.highlighted) {
        configuration.background.backgroundColor = .quinaryBackground
      } else {
        configuration.background.backgroundColor = .clear
      }
      $0.configuration = configuration
    }
    button.configuration = configuration
    button.addAction(
      UIAction { [weak self] _ in
        guard let self = self else { return }
        self.didTapUndo()
      }, for: .touchUpInside)
    return button
  }()
  private lazy var undoButtonView: UIView = {
    let view = UIView(frame: .zero)
    view.addSubview(undoButton)
    undoButton.snp.makeConstraints { make in
      make.edges.equalToSuperview()
    }
    view.layer.cornerRadius = 16
    view.layer.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
    view.clipsToBounds = true
    return view
  }()

  private lazy var redoButton: UIButton = {
    let button = UIButton(type: .custom)
    var configuration = UIButton.Configuration.filled()
    configuration.background.cornerRadius = 0
    configuration.background.backgroundColor = .clear
    configuration.baseForegroundColor = .senaryText
    configuration.image = #imageLiteral(resourceName: "redo-16").withRenderingMode(
      .alwaysTemplate)
    configuration.contentInsets = NSDirectionalEdgeInsets(
      top: 8, leading: 10, bottom: 8, trailing: 12)
    button.configurationUpdateHandler = {
      guard var configuration = $0.configuration else { return }
      if $0.state.contains(.highlighted) {
        configuration.background.backgroundColor = .quinaryBackground
      } else {
        configuration.background.backgroundColor = .clear
      }
      $0.configuration = configuration
    }
    button.configuration = configuration
    button.isEnabled = false
    button.addAction(
      UIAction { [weak self] _ in
        guard let self = self else { return }
        self.didTapRedo()
      }, for: .touchUpInside)
    return button
  }()
  private lazy var redoButtonView: UIView = {
    let view = UIView(frame: .zero)
    view.addSubview(redoButton)
    redoButton.snp.makeConstraints { make in
      make.edges.equalToSuperview()
    }
    view.layer.cornerRadius = 16
    view.layer.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
    view.clipsToBounds = true
    return view
  }()

  private lazy var undoRedoDivider: UIView = {
    let divider = SettingsViewFactory.makeDividerView()
    divider.backgroundColor = Self.buttonBorderColor
    divider.isUserInteractionEnabled = false
    return divider
  }()

  private lazy var undoRedoOverlayView: UIView = {
    let borderView = BorderView.defaultBorderView(cornerRadius: 16)
    borderView.borderColor = Self.buttonBorderColor
    borderView.backgroundColor = .clear
    borderView.isUserInteractionEnabled = false
    return borderView
  }()

  private lazy var textSlider: UISlider = {
    let slider: UISlider
    if userInterfaceIdiom == .phone {
      // On the phone the divider under the text is the history slider.
      slider = DividerSlider(frame: .zero)
    } else {
      slider = CustomSlider(frame: .zero)
      slider.tintColor = .secondaryColor
      slider.maximumTrackTintColor = .octonaryBackground
      slider.setThumbImage(#imageLiteral(resourceName: "thumb-20"), for: .normal)
    }
    slider.minimumValue = 0
    slider.value = slider.maximumValue
    slider.addAction(
      UIAction { [weak self] _ in
        guard let self = self else { return }
        self.delegate?.chatInputController(
          self, didRequestHistorySeek: Int(self.textSlider.value.rounded()))
        self.updateRedoUndoState()
      }, for: .valueChanged)
    slider.addAction(
      UIAction { [weak self] _ in
        // Workaround a issue that setting slider value would trigger this action again.
        DispatchQueue.main.async { [weak self] in
          guard let self = self else { return }
          self.textSlider.value = (self.textSlider.value).rounded()
          self.updateRedoUndoState()
        }
      }, for: [.touchUpInside, .touchUpOutside])
    return slider
  }()

  /// Adds a photo from the camera, pictures from Photos, or files.
  private lazy var attachButton: UIButton = {
    let button = Self.makeRowButton(
      image: #imageLiteral(resourceName: "plus-heavy-24").withRenderingMode(.alwaysTemplate))
    button.accessibilityLabel = LocalizedString.forKey("attach")
    button.showsMenuAsPrimaryAction = true
    var actions = [UIMenuElement]()
    if UIImagePickerController.isSourceTypeAvailable(.camera) {
      actions.append(
        UIAction(
          title: LocalizedString.forKey("take_photo_dot"), image: UIImage(systemName: "camera")
        ) { [weak self] _ in self?.presentCamera() })
    }
    actions.append(
      UIAction(
        title: LocalizedString.forKey("add_from_photos_dot"),
        image: UIImage(systemName: "photo.on.rectangle")
      ) { [weak self] _ in self?.presentPhotoPicker() })
    actions.append(
      UIAction(
        title: LocalizedString.forKey("add_files_dot"), image: UIImage(systemName: "folder")
      ) { [weak self] _ in self?.presentDocumentPicker() })
    button.menu = UIMenu(children: actions)
    return button
  }()

  private lazy var dictationWaveformController: DictationWaveformController = {
    let controller = DictationWaveformController()
    controller.view.isHidden = true
    return controller
  }()

  /// Dictates into the text; tap again to stop.
  private lazy var dictationButton: UIButton = {
    let button = Self.makeRowButton(
      image: #imageLiteral(resourceName: "microphone-heavy-24").withRenderingMode(.alwaysTemplate))
    button.accessibilityLabel = LocalizedString.forKey("dictate")
    button.addAction(
      UIAction { [weak self] _ in
        self?.toggleDictation()
      }, for: .touchUpInside)
    // While listening, the waveform stands in for the microphone.
    button.addSubview(dictationWaveformController.view)
    dictationWaveformController.view.snp.makeConstraints { make in
      make.edges.equalToSuperview()
    }
    return button
  }()

  /// The outline of the composer's buttons. In dark mode the glass brightens over a white image and
  /// the full border rings the buttons, so dark mode takes it at half strength on glass.
  private static var buttonBorderColor: UIColor {
    guard #available(iOS 26.0, *) else { return .duodenaryBorder }
    return UIColor {
      switch $0.userInterfaceStyle {
      case .light:
        return UIColor.duodenaryBorder.resolvedColor(with: $0)
      default:
        return UIColor.duodenaryBorder.resolvedColor(with: $0).withAlphaComponent(0.5)
      }
    }
  }

  private static func makeRowButton(image: UIImage) -> UIButton {
    let button = UIButton(type: .custom)
    var configuration = UIButton.Configuration.filled()
    configuration.cornerStyle = .capsule
    configuration.baseBackgroundColor = .clear
    configuration.background.strokeColor = buttonBorderColor
    configuration.background.strokeWidth = 1
    configuration.baseForegroundColor = .primaryText
    configuration.image = image
    configuration.contentInsets = NSDirectionalEdgeInsets(
      top: 8, leading: 8, bottom: 8, trailing: 8)
    button.configuration = configuration
    return button
  }

  /// The dictation in progress, if any.
  private var dictationSession: DictationSession?
  /// The dictated text's range in the composer, replaced as the transcript improves.
  private var dictationRange: NSRange?

  private lazy var modelIconView: UIImageView = {
    let imageView = UIImageView(
      image: #imageLiteral(resourceName: "cube").withRenderingMode(.alwaysTemplate))
    imageView.contentMode = .scaleAspectFit
    imageView.tintColor = .senaryText
    imageView.isUserInteractionEnabled = false
    return imageView
  }()

  private lazy var modelButton: UIButton = {
    let button = UIButton(type: .custom)
    var configuration = UIButton.Configuration.filled()
    configuration.cornerStyle = .capsule
    configuration.background.backgroundColor = .clear
    configuration.baseForegroundColor = .primaryText
    configuration.title = LocalizedString.forKey("unspecified")
    configuration.titleLineBreakMode = .byTruncatingHead
    configuration.image = #imageLiteral(resourceName: "chevron-down-16").withRenderingMode(
      .alwaysTemplate)
    configuration.imageColorTransformer = UIConfigurationColorTransformer { _ in .senaryText }
    configuration.imagePlacement = .trailing
    configuration.imagePadding = 4
    configuration.contentInsets = NSDirectionalEdgeInsets(
      top: 0, leading: 34, bottom: 0, trailing: 10)
    button.configuration = configuration
    button.configurationUpdateHandler = { button in
      guard var configuration = button.configuration else { return }
      configuration.background.backgroundColor = button.isHighlighted ? .quinaryBackground : .clear
      button.configuration = configuration
    }
    FontMetrics.default.scaleFont(.systemFont(ofSize: 14), bindTo: button)
    button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    button.addSubview(modelIconView)
    modelIconView.snp.makeConstraints { make in
      make.leading.equalToSuperview().offset(10)
      make.centerY.equalToSuperview()
      make.width.height.equalTo(20)
    }
    return button
  }()

  private lazy var sendButton: UIButton = {
    let button = UIButton(type: .custom)
    var configuration = UIButton.Configuration.filled()
    configuration.background.cornerRadius = 0
    configuration.baseBackgroundColor = .primaryFill
    configuration.baseForegroundColor = .nonaryText
    configuration.image = #imageLiteral(resourceName: "arrow-up-thick-24").withRenderingMode(
      .alwaysTemplate)
    configuration.contentInsets = NSDirectionalEdgeInsets(
      top: 8, leading: 8, bottom: 8, trailing: 8)
    button.configurationUpdateHandler = { [weak self] button in
      guard let self = self else { return }
      guard var configuration = button.configuration else { return }
      if button.state.contains(.disabled) {
        configuration.background.backgroundColor = .septenaryFill
        configuration.baseForegroundColor = .septenaryText
        self.sendStopDivider.backgroundColor = .quinaryBorder
      } else if button.state.contains(.highlighted) {
        configuration.background.backgroundColor = .primaryFill.mixed(with: .black, weight: 0.08)
        configuration.baseForegroundColor = .nonaryText
        self.sendStopDivider.backgroundColor = .denaryBorder
      } else {
        configuration.background.backgroundColor = .primaryFill
        configuration.baseForegroundColor = .nonaryText
        self.sendStopDivider.backgroundColor = .quinaryBorder
      }
      button.configuration = configuration
    }
    button.configuration = configuration
    return button
  }()

  private lazy var sendStopDivider: UIView = {
    let divider = SettingsViewFactory.makeDividerView()
    divider.backgroundColor = .quinaryBorder
    divider.isUserInteractionEnabled = false
    return divider
  }()

  private lazy var stopButton: UIButton = {
    let button = UIButton(type: .custom)
    var configuration = UIButton.Configuration.filled()
    configuration.background.cornerRadius = 0
    configuration.baseBackgroundColor = .primaryFill
    configuration.baseForegroundColor = .nonaryText
    configuration.image = #imageLiteral(resourceName: "stop-v3-filled-24").withRenderingMode(
      .alwaysTemplate)
    configuration.contentInsets = NSDirectionalEdgeInsets(
      top: 8, leading: 8, bottom: 8, trailing: 8)
    button.accessibilityLabel = LocalizedString.forKey("stop")
    button.configurationUpdateHandler = { [weak self] button in
      guard let self = self, var configuration = button.configuration else { return }
      switch self.sendState {
      case .stopping:
        configuration.background.backgroundColor = .septenaryFill
        configuration.baseForegroundColor = .septenaryText
        button.accessibilityLabel = LocalizedString.forKey("stopping")
        self.sendStopDivider.backgroundColor = .quinaryBorder
      case .idle, .sending:
        if button.state.contains(.disabled) {
          configuration.background.backgroundColor = .septenaryFill
          configuration.baseForegroundColor = .septenaryText
          self.sendStopDivider.backgroundColor = .quinaryBorder
        } else if button.state.contains(.highlighted) {
          configuration.background.backgroundColor = .primaryFill.mixed(
            with: .black, weight: 0.08)
          configuration.baseForegroundColor = .nonaryText
          self.sendStopDivider.backgroundColor = .denaryBorder
        } else {
          configuration.background.backgroundColor = .primaryFill
          configuration.baseForegroundColor = .nonaryText
          self.sendStopDivider.backgroundColor = .quinaryBorder
        }
        button.accessibilityLabel = LocalizedString.forKey("stop")
      }
      button.configuration = configuration
    }
    button.configuration = configuration
    button.isHidden = true
    return button
  }()

  private lazy var sendControlView: UIView = {
    let view = UIView(frame: .zero)
    view.layer.cornerRadius = 20
    view.clipsToBounds = true
    view.addSubview(sendButton)
    view.addSubview(sendStopDivider)
    view.addSubview(stopButton)
    sendButton.snp.makeConstraints { make in
      make.leading.top.bottom.equalToSuperview()
      sendButtonWidthConstraint = make.width.equalTo(40).constraint
    }
    sendStopDivider.snp.makeConstraints { make in
      make.leading.equalTo(sendButton.snp.trailing).priority(.high)
      make.top.bottom.equalToSuperview()
      make.width.equalTo(1)
    }
    stopButton.snp.makeConstraints { make in
      stopButtonLeadingToDividerConstraint =
        make.leading.equalTo(sendStopDivider.snp.trailing)
        .constraint
      stopButtonLeadingToDividerConstraint?.deactivate()
      stopButtonLeadingToSuperviewConstraint = make.leading.equalToSuperview().constraint
      make.top.bottom.equalToSuperview()
      stopButtonWidthConstraint = make.width.equalTo(40).constraint
    }
    return view
  }()

  private lazy var rimGlowController = RimGlowController(cornerRadius: .fixed(32))

  fileprivate lazy var attachmentController: ChatAttachmentController = {
    let attachmentController = ChatAttachmentController()
    attachmentController.delegate = self
    return attachmentController
  }()

  /// On the phone the history slider gets its own row under the text; elsewhere it shares the
  /// button row with undo and redo.
  private let userInterfaceIdiom: UIUserInterfaceIdiom

  init(workspace: SQLiteWorkspace, userInterfaceIdiom: UIUserInterfaceIdiom) {
    self.workspace = workspace
    self.userInterfaceIdiom = userInterfaceIdiom
    self.textViewMaxHeight =
      workspace.dictionary["text_view_max_height", Double.self] ?? Self.defaultTextViewMaxHeight
    self.view = UIView(frame: .zero)
    self.objCResponder = ObjCResponder()
    objCResponder.controller = self

    view.backgroundColor = .clear

    // The shadows are cut out where the composer is, so they show from where the glass ends.
    let shadow1 = ShadowView(frame: .zero)
    shadow1.cornerRadius = 32
    shadow1.contentInsets = UIEdgeInsets(top: -10, left: -10, bottom: -10, right: -10)
    shadow1.backgroundColor = .novemdecenaryBackground
    shadow1.layer.cornerRadius = 32 - 10
    shadow1.layer.shadowColor = UIColor.black.cgColor
    shadow1.layer.shadowOffset = CGSize(width: 0, height: 8)
    shadow1.layer.shadowRadius = 10
    shadow1.layer.shadowOpacity = 0.08
    view.addSubview(shadow1)
    shadow1.snp.makeConstraints { make in
      make.edges.equalToSuperview().inset(10)
    }

    view.addSubview(shadow2)
    shadow2.snp.makeConstraints { make in
      make.edges.equalToSuperview().inset(6)
    }

    let containerView = BorderView.defaultBorderView(cornerRadius: 32)
    containerView.borderColor = .duodenaryBorder
    containerView.layer.borderWidth = 0.5
    containerView.backgroundColor = .novemdecenaryBackground
    containerView.clipsToBounds = true
    view.addSubview(containerView)
    containerView.snp.makeConstraints { make in
      make.edges.equalToSuperview()
    }
    // The composer floats over the chat in Liquid Glass, so the opaque fill steps aside.
    var isGlass = false
    if #available(iOS 26.0, *) {
      isGlass = true
      // The glass brightens over a white image in dark mode (and darkens over a black one in light
      // mode) while the text keeps its colors, so a light tint of the old fill holds it nearer the
      // mode's own surface. Dark mode takes twice the tint.
      let glassEffect = UIGlassEffect(style: .regular)
      glassEffect.tintColor = UIColor {
        switch $0.userInterfaceStyle {
        case .light:
          return UIColor.novemdecenaryBackground.resolvedColor(with: $0).withAlphaComponent(0.1)
        default:
          return UIColor.novemdecenaryBackground.resolvedColor(with: $0).withAlphaComponent(0.2)
        }
      }
      let glassView = UIVisualEffectView(effect: glassEffect)
      glassView.isUserInteractionEnabled = false
      containerView.addSubview(glassView)
      glassView.snp.makeConstraints { make in
        make.edges.equalToSuperview()
      }
      containerView.backgroundColor = .clear
      containerView.layer.cornerCurve = .continuous
    }

    containerView.addSubview(resizeHandleBackgroundView)
    resizeHandleBackgroundView.snp.makeConstraints { make in
      make.centerX.equalToSuperview()
      make.top.equalToSuperview()
      make.width.equalTo(36)
      make.height.equalTo(17)
    }

    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.lineSpacing = 2

    containerView.addSubview(attachmentController.view)
    attachmentController.view.snp.makeConstraints { make in
      make.leading.trailing.equalToSuperview()
      make.top.equalToSuperview().offset(16)
      attachmentViewHeightConstraint = make.height.equalTo(0).constraint
    }
    containerView.addSubview(teleportView)
    // The teleport view only sizes the text view; an opaque cover hides it, or on glass, which
    // has no opaque color to match, it is simply transparent.
    let hiddenView = UIView(frame: .zero)
    hiddenView.backgroundColor = isGlass ? .clear : .novemdecenaryBackground
    teleportView.alpha = isGlass ? 0 : 1
    containerView.addSubview(hiddenView)
    containerView.addSubview(textView)
    containerView.addSubview(textViewTopBlurView)
    // Its shade matches the opaque composer; glass shows the text scroll under it instead.
    textViewTopBlurView.isHidden = isGlass
    teleportView.snp.makeConstraints { make in
      make.top.leading.trailing.equalTo(textView)
    }
    hiddenView.snp.makeConstraints { make in
      make.edges.equalTo(teleportView)
    }
    textView.snp.makeConstraints { make in
      make.leading.equalToSuperview().inset(20)
      make.trailing.equalToSuperview().inset(4)
      make.top.equalTo(attachmentController.view.snp.bottom)
      textViewHeightLessThanOrEqualToConstraint =
        make.height.lessThanOrEqualTo(textViewMaxHeight).constraint
      textViewHeightEqualToConstraint =
        make.height.equalTo(textViewMaxHeight).priority(.low).constraint
      make.height.equalTo(teleportView).priority(.high)
    }
    textViewTopBlurView.snp.makeConstraints { make in
      make.leading.trailing.equalToSuperview()
      make.top.equalTo(textView)
      make.height.equalTo(10)
    }

    containerView.addSubview(placeholderView)
    placeholderView.snp.makeConstraints { make in
      make.edges.equalTo(textView)
    }

    // The row under the text holds attachments, the model, dictation and send. Its outer buttons
    // sit 12pt in, concentric with the composer's corners.
    containerView.addSubview(attachButton)
    containerView.addSubview(modelButton)
    containerView.addSubview(dictationButton)
    containerView.addSubview(sendControlView)
    attachButton.snp.makeConstraints { make in
      make.leading.equalToSuperview().inset(12)
      make.centerY.equalTo(sendControlView)
      make.width.height.equalTo(40)
    }
    dictationButton.snp.makeConstraints { make in
      make.trailing.equalTo(sendControlView.snp.leading).offset(-8)
      make.centerY.equalTo(sendControlView)
      make.width.height.equalTo(40)
    }
    if userInterfaceIdiom == .phone {
      // The divider under the text is the history slider.
      containerView.addSubview(textSlider)
      textSlider.snp.makeConstraints { make in
        make.leading.trailing.equalToSuperview().inset(12)
        make.centerY.equalTo(textView.snp.bottom).offset(4)
        make.height.equalTo(20)
      }
      modelButton.snp.makeConstraints { make in
        make.leading.equalTo(attachButton.snp.trailing).offset(12)
        make.trailing.lessThanOrEqualTo(dictationButton.snp.leading).offset(-12)
        make.centerY.equalTo(sendControlView)
        make.height.equalTo(36)
      }
      sendControlView.snp.makeConstraints { make in
        make.top.equalTo(textView.snp.bottom).offset(24)
        make.trailing.bottom.equalToSuperview().inset(12)
        make.height.equalTo(40)
        sendControlWidthConstraint = make.width.equalTo(40).constraint
      }
    } else {
      // Undo, redo and the history slider sit between attachments and the model.
      containerView.addSubview(undoButtonView)
      containerView.addSubview(redoButtonView)
      containerView.addSubview(undoRedoDivider)
      containerView.addSubview(undoRedoOverlayView)
      undoButtonView.snp.makeConstraints { make in
        make.leading.equalTo(attachButton.snp.trailing).offset(12)
        make.centerY.equalTo(sendControlView)
        make.height.equalTo(32)
      }
      redoButtonView.snp.makeConstraints { make in
        make.leading.equalTo(undoButtonView.snp.trailing).offset(1)
        make.centerY.equalTo(sendControlView)
        make.height.equalTo(32)
      }
      undoRedoOverlayView.snp.makeConstraints { make in
        make.top.bottom.leading.equalTo(undoButtonView)
        make.trailing.equalTo(redoButtonView)
      }
      undoRedoDivider.snp.makeConstraints { make in
        make.top.bottom.equalTo(undoButtonView)
        make.width.equalTo(1)
        make.leading.equalTo(undoButtonView.snp.trailing)
      }
      containerView.addSubview(textSlider)
      textSlider.snp.makeConstraints { make in
        make.centerY.equalTo(undoRedoOverlayView)
        make.leading.equalTo(undoRedoOverlayView.snp.trailing).offset(12)
        make.width.greaterThanOrEqualTo(88)
      }
      modelButton.snp.makeConstraints { make in
        make.leading.equalTo(textSlider.snp.trailing).offset(12)
        make.trailing.equalTo(dictationButton.snp.leading).offset(-12)
        make.centerY.equalTo(sendControlView)
        make.height.equalTo(32)
      }
      sendControlView.snp.makeConstraints { make in
        make.top.equalTo(textView.snp.bottom).offset(8)
        make.trailing.bottom.equalToSuperview().inset(12)
        make.height.equalTo(40)
        sendControlWidthConstraint = make.width.equalTo(40).constraint
      }
    }
    // Above everything while a drop hovers; it ignores touches and clears the middle.
    containerView.addSubview(rimGlowController.view)
    rimGlowController.view.snp.makeConstraints { make in
      make.edges.equalToSuperview()
    }

    let panGestureRecognizer = UILongPressGestureRecognizer(
      target: objCResponder, action: #selector(ObjCResponder.pan(_:)))
    panGestureRecognizer.minimumPressDuration = 0
    resizeHandleBackgroundView.addGestureRecognizer(panGestureRecognizer)
    let doubleTapGestureRecognizer = UITapGestureRecognizer(
      target: objCResponder, action: #selector(ObjCResponder.doubleTap(_:)))
    doubleTapGestureRecognizer.numberOfTapsRequired = 2
    resizeHandleBackgroundView.addGestureRecognizer(doubleTapGestureRecognizer)
    undoButton.addAction(
      UIAction { [weak self] _ in
        self?.didTapUndo()
      }, for: .touchUpInside)
    redoButton.addAction(
      UIAction { [weak self] _ in
        self?.didTapRedo()
      }, for: .touchUpInside)
    textSlider.addAction(
      UIAction { [weak self] _ in
        self?.didChangeHistorySlider()
      }, for: .valueChanged)
    sendButton.addAction(
      UIAction { [weak self] _ in
        self?.didTapSend()
      }, for: .touchUpInside)
    stopButton.addAction(
      UIAction { [weak self] _ in
        self?.didTapStop()
      }, for: .touchUpInside)
    modelButton.addAction(
      UIAction { [weak self] _ in
        self?.selectModel()
      }, for: .touchUpInside)
    updateSendControl(animated: false)
  }

  func setModel(name: String, image: UIImage) {
    modelButton.configuration?.title = name
    modelIconView.image = image
  }

  func selectModel() {
    delegate?.chatInputController(self, didTapModelSelector: modelButton)
  }

  func setText(_ text: String) {
    endDictation()
    textView.string = text
    teleportView.string = text.isEmpty ? placeholderText : text
    updatePlaceholder()
    updateTextViewScrollIndicator()
    updateSendControl(animated: true)
  }

  func stop() {
    didTapStop()
  }

  func removeAllAttachments() {
    attachmentController.removeAll()
  }

  /// Files dropped anywhere in the view become attachments; the rim glow stays on the composer.
  func addAttachmentDropInteraction(to view: UIView) {
    attachmentController.addDropInteraction(to: view)
  }

  /// Collection views take drops themselves, so their drop delegate attaches files instead.
  func setAttachmentDropDelegate(of collectionView: UICollectionView) {
    attachmentController.setDropDelegate(of: collectionView)
  }

  func addAttachments(projectFiles urls: [URL]) {
    attachmentController.addProjectFiles(urls)
  }

  func focus() {
    // A hidden input must not take the keyboard, or typing would go somewhere off screen.
    var ancestor: UIView? = textView
    while let view = ancestor {
      guard !view.isHidden else { return }
      ancestor = view.superview
    }
    textView.becomeFirstResponder()
  }

  private func updateTextViewScrollIndicator() {
    let teleportView = teleportView
    let textView = textView
    DispatchQueue.main.async {
      textView.showsVerticalScrollIndicator = teleportView.bounds.height > textView.bounds.height
    }
  }

  private func updatePlaceholder() {
    placeholderView.isHidden = !(textView.text ?? "").isEmpty
  }

  private func updatePlaceholderText() {
    placeholderView.text = placeholderText
    if (textView.text ?? "").isEmpty {
      teleportView.string = placeholderText
      updateTextViewScrollIndicator()
    }
  }

  private func updateSendControl(animated: Bool) {
    let hasContent =
      (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !attachmentController.attachments.isEmpty) && !attachmentController.isImporting
    let isGenerating = sendState != .idle
    let isSplit = hasContent && isGenerating
    let showsSendButton = hasContent || !isGenerating
    let showsStopButton = isGenerating
    let usesStopButtonSuperviewLeading = !isSplit
    var isChanged = false
    if sendButton.isHidden != !showsSendButton {
      sendButton.isHidden = !showsSendButton
      isChanged = true
    }
    if sendButton.isEnabled != hasContent {
      sendButton.isEnabled = hasContent
      isChanged = true
    }
    if stopButton.isHidden != !showsStopButton {
      stopButton.isHidden = !showsStopButton
      isChanged = true
    }
    if sendStopDivider.isHidden != !isSplit {
      sendStopDivider.isHidden = !isSplit
      isChanged = true
    }
    if stopButton.isEnabled != (sendState == .sending) {
      stopButton.isEnabled = (sendState == .sending)
      isChanged = true
    }
    if stopButtonLeadingToSuperviewConstraint?.isActive != usesStopButtonSuperviewLeading {
      stopButtonLeadingToSuperviewConstraint?.isActive = usesStopButtonSuperviewLeading
      isChanged = true
    }
    if stopButtonLeadingToDividerConstraint?.isActive != isSplit {
      stopButtonLeadingToDividerConstraint?.isActive = isSplit
      isChanged = true
    }
    sendButtonWidthConstraint?.update(offset: isSplit ? 38 : 40)
    stopButtonWidthConstraint?.update(offset: isSplit ? 38 : 40)
    sendControlWidthConstraint?.update(offset: isSplit ? 77 : 40)
    if var configuration = sendButton.configuration {
      configuration.contentInsets = NSDirectionalEdgeInsets(
        top: 8, leading: 8, bottom: 8, trailing: isSplit ? 6 : 8)
      sendButton.configuration = configuration
    }
    if var configuration = stopButton.configuration {
      configuration.contentInsets = NSDirectionalEdgeInsets(
        top: 8, leading: isSplit ? 6 : 8, bottom: 8, trailing: 8)
      stopButton.configuration = configuration
    }
    sendButton.setNeedsUpdateConfiguration()
    stopButton.setNeedsUpdateConfiguration()
    guard isChanged, animated, sendControlView.window != nil else { return }
    let superview = view.superview
    UIView.animate(
      withDuration: 0.2, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 5,
      options: [.allowAnimatedContent, .beginFromCurrentState, .curveEaseInOut]
    ) {
      superview?.layoutIfNeeded()
    }
  }

  private func updateRedoUndoState() {
    undoButton.isEnabled = textHistoryPointer > 0
    redoButton.isEnabled = textHistoryPointer < maxTextHistoryPointer
    (textSlider as? DividerSlider)?.hasHistory = maxTextHistoryPointer > 0
  }

  private func didTapUndo() {
    guard textHistoryPointer > 0 else { return }
    delegate?.chatInputController(self, didRequestHistorySeek: textHistoryPointer - 1)
  }

  private func didTapRedo() {
    guard textHistoryPointer < maxTextHistoryPointer else { return }
    delegate?.chatInputController(self, didRequestHistorySeek: textHistoryPointer + 1)
  }

  private func didChangeHistorySlider() {
    let edits = Int(textSlider.value.rounded())
    textSlider.value = Float(edits)
    delegate?.chatInputController(self, didRequestHistorySeek: edits)
  }

  private func didTapSend() {
    endDictation()
    delegate?.chatInputControllerDidTapSend(self)
  }

  // MARK: - Attachments from the camera, Photos and Files

  private func presentCamera() {
    let picker = UIImagePickerController()
    picker.sourceType = .camera
    picker.delegate = objCResponder
    delegate?.chatInputController(self, present: picker)
  }

  private func presentPhotoPicker() {
    var configuration = PHPickerConfiguration()
    configuration.selectionLimit = 0
    let picker = PHPickerViewController(configuration: configuration)
    picker.delegate = objCResponder
    delegate?.chatInputController(self, present: picker)
  }

  private func presentDocumentPicker() {
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
    picker.allowsMultipleSelection = true
    picker.delegate = objCResponder
    delegate?.chatInputController(self, present: picker)
  }

  // MARK: - Dictation

  private func toggleDictation() {
    if let dictationSession {
      dictationSession.stop()
      return
    }
    DictationSession.requestAuthorization { [weak self] isAuthorized in
      DispatchQueue.main.async {
        guard let self else { return }
        guard isAuthorized else {
          return self.presentDictationError(DictationSession.Error.notAuthorized)
        }
        self.startDictation()
      }
    }
  }

  private func startDictation() {
    // A second tap while access was being asked for may already have started one.
    guard dictationSession == nil else { return }
    let dictationSession = DictationSession()
    dictationSession.delegate = self
    do {
      try dictationSession.start()
    } catch {
      presentDictationError(error)
      return
    }
    self.dictationSession = dictationSession
    // Dictation goes where the cursor is.
    let location = min(
      textView.selectedRange.location, ((textView.text ?? "") as NSString).length)
    dictationRange = NSRange(location: location, length: 0)
    updateDictationButton()
  }

  /// Any other change to the text ends dictation, so later transcripts can't land in text that
  /// has moved on: typing, sending, a history seek or another thread's draft.
  private func endDictation() {
    guard let dictationSession else { return }
    dictationSession.cancel()
    self.dictationSession = nil
    dictationRange = nil
    updateDictationButton()
  }

  /// Replaces the dictated text so far, as typing would, so text history records it.
  private func replaceDictation(with transcript: String) {
    guard let range = dictationRange,
      NSMaxRange(range) <= ((textView.text ?? "") as NSString).length
    else { return }
    delegate?.chatInputController(
      self, currentText: textView.text ?? "", shouldChangeTextIn: range,
      replacementText: transcript)
    textView.string = ((textView.text ?? "") as NSString).replacingCharacters(
      in: range, with: transcript)
    let length = (transcript as NSString).length
    dictationRange = NSRange(location: range.location, length: length)
    textView.selectedRange = NSRange(location: range.location + length, length: 0)
    textViewDidChange(textView)
  }

  private func updateDictationButton() {
    let isRunning = dictationSession != nil
    var configuration = dictationButton.configuration
    configuration?.image =
      isRunning
      ? nil : #imageLiteral(resourceName: "microphone-heavy-24").withRenderingMode(.alwaysTemplate)
    configuration?.baseBackgroundColor =
      isRunning ? UIColor.colorPalette(for: .blue).withAlphaComponent(0.07) : .clear
    configuration?.background.strokeColor = isRunning ? .clear : Self.buttonBorderColor
    dictationButton.configuration = configuration
    dictationWaveformController.reset()
    dictationWaveformController.view.isHidden = !isRunning
    dictationButton.accessibilityLabel = LocalizedString.forKey(
      isRunning ? "stop_dictation" : "dictate")
  }

  private func presentDictationError(_ error: Error) {
    let alert = UIAlertController(
      title: LocalizedString.forKey("dictate"),
      message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
      preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: LocalizedString.forKey("ok"), style: .default))
    delegate?.chatInputController(self, present: alert)
  }

  private func didTapStop() {
    delegate?.chatInputControllerDidTapStop(self)
  }

  private func newResizePhantomView() -> (UIView, UIView) {
    let resizePhantomView = UIView(frame: .zero)
    resizePhantomView.isUserInteractionEnabled = false
    let upperCornersView = BorderView.defaultBorderView(cornerRadius: 32)
    upperCornersView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
    upperCornersView.borderColor = .colorPalette(for: .blue)
    upperCornersView.layer.borderWidth = 2
    upperCornersView.backgroundColor = .colorPalette(for: .blue).withAlphaComponent(0.3)
    let lowerCornersView = BorderView.defaultBorderView(cornerRadius: 32)
    lowerCornersView.layer.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
    lowerCornersView.borderColor = .colorPalette(for: .blue)
    lowerCornersView.layer.borderWidth = 2
    lowerCornersView.backgroundColor = .colorPalette(for: .blue).withAlphaComponent(0.3)
    resizePhantomView.addSubview(upperCornersView)
    resizePhantomView.addSubview(lowerCornersView)
    upperCornersView.snp.makeConstraints { make in
      make.leading.trailing.top.equalToSuperview()
      make.bottom.equalToSuperview().offset(-72)
    }
    lowerCornersView.snp.makeConstraints { make in
      make.leading.trailing.bottom.equalToSuperview()
      make.top.equalTo(upperCornersView.snp.bottom).offset(-1)
    }
    return (resizePhantomView, lowerCornersView)
  }

  private func didMoveResizeHandleBegan(_ point: CGPoint) {
    guard textViewHeightEqualToConstraint != nil,
      textViewHeightLessThanOrEqualToConstraint != nil
    else {
      return
    }
    resizeHandleStartLocation = point
    resizeHandleStartTextViewMaxHeight = textViewMaxHeight
    resizeHandleStartTextViewHeight = textView.frame.height
    let (resizePhantomView, lowerCornersView) = newResizePhantomView()
    view.insertSubview(resizePhantomView, aboveSubview: shadow2)
    let resizePhantomViewHeight =
      (view.frame.height + 4 + textViewMaxHeight - textView.frame.height).rounded()
    resizePhantomView.snp.makeConstraints { make in
      make.leading.trailing.bottom.equalTo(view).inset(-2)
      resizePhantomViewHeightConstraint = make.height.equalTo(resizePhantomViewHeight).constraint
    }
    resizePhantomViewHeightLast = resizePhantomViewHeight
    self.resizePhantomViewHeight = view.frame.height + 4
    resizePhantomView.alpha = 0
    view.layoutIfNeeded()
    UIView.animate(
      withDuration: 0.2, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 5,
      options: [.beginFromCurrentState, .curveEaseOut]
    ) {
      resizePhantomView.alpha = 1
    }
    if let lastResizePhantomView = self.resizePhantomView {
      lastResizePhantomView.removeFromSuperview()
    }
    self.resizePhantomView = resizePhantomView
    self.resizePhantomLowerCornersView = lowerCornersView
    resizeHandleShouldUpdate = false
  }

  private func didMoveResizeHandleChanged(_ point: CGPoint) {
    guard let resizeHandleStartLocation,
      let resizeHandleStartTextViewHeight,
      let resizePhantomViewHeight
    else { return }
    let textViewHeight = (resizeHandleStartTextViewHeight + resizeHandleStartLocation.y - point.y)
      .rounded()
    let clippedTextViewHeight = max(40, textViewHeight)
    let roundedTextViewHeight = ((clippedTextViewHeight - 16) / 24).rounded() * 24 + 16
    if Int(roundedTextViewHeight)
      != Int(((resizeHandleStartTextViewHeight - 16) / 24).rounded() * 24 + 16)
    {
      resizeHandleShouldUpdate = true
    }
    if resizeHandleShouldUpdate {
      let newResizePhantomViewHeight =
        (roundedTextViewHeight - resizeHandleStartTextViewHeight + resizePhantomViewHeight)
        .rounded()
      if Int(newResizePhantomViewHeight) != Int(resizePhantomViewHeightLast) {
        resizePhantomViewHeightConstraint?.update(offset: newResizePhantomViewHeight)
        resizePhantomViewHeightLast = newResizePhantomViewHeight
        let hostView = self.view
        UIView.animate(
          withDuration: 0.2, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 5,
          options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseOut]
        ) {
          hostView.layoutIfNeeded()
        }
      }
    }
    if textViewHeight < 56 {
      let f: CGFloat = 56 - textViewHeight
      let d: CGFloat = 56
      let c: CGFloat = 0.55
      textViewMaxHeight = (56 - (1.0 - (1.0 / (f * c / d + 1))) * d).rounded()
    } else {
      textViewMaxHeight = clippedTextViewHeight
    }
    textViewHeightEqualToConstraint?.update(offset: textViewMaxHeight)
    textViewHeightLessThanOrEqualToConstraint?.update(offset: textViewMaxHeight)
  }

  private func didMoveResizeHandleEnded(_ point: CGPoint) {
    guard let resizeHandleStartLocation,
      let resizeHandleStartTextViewMaxHeight,
      let resizeHandleStartTextViewHeight,
      let resizePhantomView
    else { return }
    self.resizeHandleStartLocation = nil
    self.resizeHandleStartTextViewMaxHeight = nil
    self.resizePhantomView = nil
    self.resizePhantomLowerCornersView = nil
    self.resizePhantomViewHeightConstraint = nil
    if resizeHandleShouldUpdate {
      textViewMaxHeight = max(
        56, resizeHandleStartTextViewHeight + resizeHandleStartLocation.y - point.y)
      textViewMaxHeight = ((textViewMaxHeight - 32) / 24).rounded() * 24 + 32
      workspace.dictionary["text_view_max_height", Double.self] = textViewMaxHeight
    } else {
      textViewMaxHeight = resizeHandleStartTextViewMaxHeight
    }
    textViewHeightEqualToConstraint?.update(offset: textViewMaxHeight)
    textViewHeightLessThanOrEqualToConstraint?.update(offset: textViewMaxHeight)
    let superview = view.superview
    UIView.animate(
      withDuration: 0.2, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 5,
      options: [.beginFromCurrentState, .curveEaseOut]
    ) {
      superview?.layoutIfNeeded()
      resizePhantomView.alpha = 0
    } completion: { _ in
      resizePhantomView.removeFromSuperview()
    }
  }

  private func pan(_ gestureRecognizer: UILongPressGestureRecognizer) {
    let coordinateView = view.superview ?? view
    let point = gestureRecognizer.location(in: coordinateView)
    switch gestureRecognizer.state {
    case .began:
      didMoveResizeHandleBegan(point)
    case .changed:
      didMoveResizeHandleChanged(point)
    case .ended, .cancelled:
      didMoveResizeHandleEnded(point)
    default:
      break
    }
  }

  private func setTextViewMaxHeightAnimated() {
    guard let textViewHeightEqualToConstraint,
      let textViewHeightLessThanOrEqualToConstraint
    else { return }
    textViewMaxHeight = Self.defaultTextViewMaxHeight
    workspace.dictionary["text_view_max_height", Double.self] = textViewMaxHeight
    let (resizePhantomView, _) = newResizePhantomView()
    view.insertSubview(resizePhantomView, aboveSubview: shadow2)
    let resizePhantomViewHeight =
      (view.frame.height + 4 + textViewMaxHeight - textView.frame.height).rounded()
    resizePhantomView.snp.makeConstraints { make in
      make.leading.trailing.bottom.equalTo(view).inset(-2)
      make.height.equalTo(resizePhantomViewHeight)
    }
    view.layoutIfNeeded()
    textViewHeightEqualToConstraint.update(offset: textViewMaxHeight)
    textViewHeightLessThanOrEqualToConstraint.update(offset: textViewMaxHeight)
    let superview = view.superview
    UIView.animate(
      withDuration: 0.2, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 5,
      options: [.beginFromCurrentState, .curveEaseOut]
    ) {
      resizePhantomView.alpha = 0
      superview?.layoutIfNeeded()
    } completion: { _ in
      resizePhantomView.removeFromSuperview()
    }
  }

  private func doubleTap(_ gestureRecognizer: UITapGestureRecognizer) {
    setTextViewMaxHeightAnimated()
  }
}

extension ChatInputController {
  final class ObjCResponder: NSObject {
    weak var controller: ChatInputController?

    @objc
    func pan(_ gestureRecognizer: UILongPressGestureRecognizer) {
      controller?.pan(gestureRecognizer)
    }

    @objc
    func doubleTap(_ gestureRecognizer: UITapGestureRecognizer) {
      controller?.doubleTap(gestureRecognizer)
    }
  }
}

extension ChatInputController.ObjCResponder: UITextViewDelegate {
  func textViewDidBeginEditing(_ textView: UITextView) {
    controller?.textViewDidBeginEditing(textView)
  }

  func textViewDidEndEditing(_ textView: UITextView) {
    controller?.textViewDidEndEditing(textView)
  }

  func textView(
    _ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String
  ) -> Bool {
    controller?.textView(textView, shouldChangeTextIn: range, replacementText: text) ?? true
  }

  func textViewDidChange(_ textView: UITextView) {
    controller?.textViewDidChange(textView)
  }
}

extension ChatInputController {
  func textViewDidBeginEditing(_ textView: UITextView) {
    delegate?.chatInputControllerDidBeginEditing(self)
  }

  func textViewDidEndEditing(_ textView: UITextView) {
    delegate?.chatInputControllerDidEndEditing(self)
  }

  func textView(
    _ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String
  ) -> Bool {
    guard let textView = textView as? MarkdownTextView else { return false }
    endDictation()
    if text == "\n" && !textView.isShiftPressed {
      delegate?.chatInputControllerDidTapSend(self)
      return false
    }
    delegate?.chatInputController(
      self, currentText: textView.text ?? "", shouldChangeTextIn: range, replacementText: text)
    return true
  }

  func textViewDidChange(_ textView: UITextView) {
    teleportView.string = (textView.text?.isEmpty ?? true) ? placeholderText : textView.text ?? ""
    updatePlaceholder()
    updateTextViewScrollIndicator()
    updateSendControl(animated: true)
  }
}

extension ChatInputController.ObjCResponder: UIImagePickerControllerDelegate,
  UINavigationControllerDelegate
{
  func imagePickerController(
    _ picker: UIImagePickerController,
    didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
  ) {
    picker.dismiss(animated: true)
    guard let image = info[.originalImage] as? UIImage else { return }
    controller?.attachmentController.addPhoto(image)
  }

  func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
    picker.dismiss(animated: true)
  }
}

extension ChatInputController.ObjCResponder: PHPickerViewControllerDelegate {
  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)
    controller?.attachmentController.addItemProviders(results.map(\.itemProvider))
  }
}

extension ChatInputController.ObjCResponder: UIDocumentPickerDelegate {
  func documentPicker(
    _ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]
  ) {
    self.controller?.attachmentController.addFiles(urls)
  }
}

extension ChatInputController: DictationSessionDelegate {
  func dictationSession(_ session: DictationSession, didTranscribe transcript: String) {
    guard session === dictationSession, let range = dictationRange else { return }
    // After a word, the transcript starts with a space in languages that put spaces between words.
    // The range includes that space, so the character before it is still the word's.
    let text = (textView.text ?? "") as NSString
    let needsSpace =
      session.separatesWordsWithSpaces && range.location > 0 && range.location <= text.length
      && !CharacterSet.whitespacesAndNewlines.contains(
        UnicodeScalar(text.character(at: range.location - 1)) ?? " ")
    replaceDictation(with: (needsSpace ? " " : "") + transcript)
  }

  func dictationSession(_ session: DictationSession, didUpdateLevel level: Float) {
    guard session === dictationSession else { return }
    dictationWaveformController.setLevel(level)
  }

  func dictationSessionDidFinish(_ session: DictationSession, error: Error?) {
    guard session === dictationSession else { return }
    dictationSession = nil
    dictationRange = nil
    updateDictationButton()
    if let error, (error as NSError).code != 1110 {  // 1110: nothing was said.
      presentDictationError(error)
    }
  }
}

extension ChatInputController: ChatAttachmentControllerDelegate {
  func chatAttachmentControllerDidChange(_ controller: ChatAttachmentController) {
    // 56pt cards plus 2pt: with the text view's 10pt inset and the font's ascent, the text sits
    // about 16pt below the cards, as the cards sit 16pt below the top. Don't overlap the text
    // view instead; its opaque top shade would cover the cards.
    attachmentViewHeightConstraint?.update(offset: controller.hasContent ? 58 : 0)
    updateSendControl(animated: true)
    guard view.window != nil else { return }
    let superview = view.superview
    UIView.animate(
      withDuration: 0.2, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 5,
      options: [.allowAnimatedContent, .beginFromCurrentState, .curveEaseInOut]
    ) {
      superview?.layoutIfNeeded()
    }
  }

  func chatAttachmentControllerDidChangeDropTarget(
    _ controller: ChatAttachmentController, animated: Bool
  ) {
    rimGlowController.setGlowing(controller.isDropTargeted, animated: animated)
  }

  func chatAttachmentController(
    _ controller: ChatAttachmentController, present viewController: UIViewController
  ) {
    delegate?.chatInputController(self, present: viewController)
  }
}
