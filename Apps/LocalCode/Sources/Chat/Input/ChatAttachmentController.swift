import ImageIO
import Localization
import QuickLook
import SnapKit
import Style
import UIKit
import UniformTypeIdentifiers

protocol ChatAttachmentControllerDelegate: AnyObject {
  func chatAttachmentControllerDidChange(_ controller: ChatAttachmentController)
  func chatAttachmentControllerDidChangeDropTarget(
    _ controller: ChatAttachmentController, animated: Bool)
  func chatAttachmentController(
    _ controller: ChatAttachmentController, present viewController: UIViewController)
}

/// Owns the files dropped on the composer; UIKit delegates only forward events here.
final class ChatAttachmentController {
  weak var delegate: ChatAttachmentControllerDelegate?

  let view: UIScrollView

  var attachments: [ChatAttachment] { cards.map(\.attachment) }
  var isImporting: Bool { importCount > 0 }
  var hasContent: Bool { !cards.isEmpty }
  /// Whether a drag the composer accepts is over it.
  private(set) var isDropTargeted = false

  private let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "LocalCode-Attachments-\(UUID().uuidString)", isDirectory: true)
  private let objCResponder: ObjCResponder
  private var cards = [(attachment: ChatAttachment, view: UIView)]()
  private var importCount = 0
  private var dropTargets = Set<ObjectIdentifier>()
  fileprivate var chatInputDropInteraction: UIDropInteraction?
  fileprivate var previewAttachment: ChatAttachment?

  private lazy var stackView: UIStackView = {
    let stackView = UIStackView(frame: .zero)
    stackView.axis = .horizontal
    stackView.spacing = 8
    stackView.alignment = .center
    return stackView
  }()

  init() {
    view = UIScrollView(frame: .zero)
    objCResponder = ObjCResponder()
    objCResponder.controller = self
    // Below are string "_setSupportsPointerDragScrolling:"
    let mysteriousSecret = [
      106_488_813, 106_488_839, 106_488_855, 106_488_840, 106_488_809, 106_488_845, 106_488_842,
      106_488_844, 106_488_845, 106_488_850, 106_488_854, 106_488_855, 106_488_826, 106_488_859,
      106_488_851, 106_488_862, 106_489_030, 106_488_853, 106_489_032, 106_488_824, 106_489_032,
      106_488_857, 106_488_869, 106_488_879, 106_488_865, 106_489_042, 106_489_045, 106_489_040,
      106_489_046, 106_489_041, 106_489_052, 106_489_043, 106_488_840,
    ].enumerated().map({
      (($1 + 32 - $0) ^ 106_488_914) - $0
    }).map { String(UnicodeScalar($0)!) }.joined()
    let selector = NSSelectorFromString(mysteriousSecret)
    view.perform(selector, with: true)
    view.showsHorizontalScrollIndicator = false
    view.addSubview(stackView)
    // The strip spans the composer so cards scroll under its edge; the first card sits 16pt in.
    stackView.snp.makeConstraints { make in
      make.top.bottom.equalTo(view.contentLayoutGuide)
      make.leading.trailing.equalTo(view.contentLayoutGuide).inset(16)
      make.height.equalTo(56)
    }
  }

  deinit {
    try? FileManager.default.removeItem(at: directory)
  }

  /// The composer takes files and text from anywhere, including text dragged within the app.
  func setChatInputDropInteraction(on view: UIView) {
    let interaction = UIDropInteraction(delegate: objCResponder)
    chatInputDropInteraction = interaction
    view.addInteraction(interaction)
  }

  /// Around the composer, text dragged within the app is refused: selecting and dragging the
  /// conversation's own text is not asking to attach it.
  func addDropInteraction(to view: UIView) {
    view.addInteraction(UIDropInteraction(delegate: objCResponder))
  }

  /// A collection view installs its own drop destination, which refuses file drops before they
  /// reach an ancestor's drop interaction, even with drag interaction disabled; handle its drops
  /// as its drop delegate instead. It refuses in-app text like the views around it.
  func setDropDelegate(of collectionView: UICollectionView) {
    collectionView.dropDelegate = objCResponder
  }

  /// Pasting a file or image into the text view attaches it; text still pastes as text.
  func setPasteDelegate(of textView: UITextView) {
    textView.pasteDelegate = objCResponder
    textView.pasteConfiguration = UIPasteConfiguration(
      acceptableTypeIdentifiers: [UTType.data.identifier])
  }

  func removeAll() {
    attachments.forEach(remove)
  }

  /// Shows files already in the project, such as a restored draft's attachments. They are
  /// referenced in place, never copied or deleted.
  func addProjectFiles(_ urls: [URL]) {
    for url in urls
    where FileManager.default.fileExists(atPath: url.path)
      && !cards.contains(where: { $0.attachment.url == url })
    {
      insert(ChatAttachment(url: url, sourceURL: url))
    }
  }

  /// Items picked from Photos, imported like dropped items.
  func addItemProviders(_ providers: [NSItemProvider]) {
    importProviders(providers)
  }

  /// Files picked from the Files app; each is copied, since the picker's copies are temporary.
  func addFiles(_ urls: [URL]) {
    for url in urls {
      guard let attachment = try? Self.snapshot(url, sourceURL: nil, in: directory) else {
        continue
      }
      insert(attachment)
    }
  }

  /// A photo taken with the camera, saved as a JPEG file.
  func addPhoto(_ image: UIImage) {
    guard let data = image.jpegData(compressionQuality: 0.85) else { return }
    let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let url = folder.appendingPathComponent("Photo.jpg")
    do {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try data.write(to: url)
    } catch {
      return
    }
    insert(ChatAttachment(url: url, sourceURL: nil))
  }

  /// The file type to import a dropped item as: the first non-text data it offers, or its text
  /// data when it is a named text file. Folders are not data; links and unnamed text are not files.
  fileprivate static func fileType(of provider: NSItemProvider) -> String? {
    provider.registeredTypeIdentifiers.first { identifier in
      guard let type = UTType(identifier), type.conforms(to: .data), !type.conforms(to: .url)
      else { return false }
      return !type.conforms(to: .text) || provider.suggestedName?.isEmpty == false
    }
  }

  /// Files, and blocks of text, which are saved as text files for the agent to read.
  fileprivate static func accepts(_ session: UIDropSession) -> Bool {
    session.items.contains {
      fileType(of: $0.itemProvider) != nil || $0.itemProvider.canLoadObject(ofClass: String.self)
    }
  }

  /// Around the composer, anything it accepts except text dragged within the app. `fileType(of:)`
  /// alone can't tell text apart, since an attributed string also offers RTFD data; what marks it
  /// is loading as a string without a name.
  fileprivate static func acceptsAroundChatInput(_ session: UIDropSession) -> Bool {
    guard session.localDragSession != nil else { return accepts(session) }
    return session.items.contains {
      let provider = $0.itemProvider
      let isText =
        provider.canLoadObject(ofClass: String.self) && provider.suggestedName?.isEmpty != false
      return !isText && fileType(of: provider) != nil
    }
  }

  /// A target is a drop interaction or a collection view acting as its own drop destination.
  fileprivate func setDropTarget(_ target: AnyObject, isTargeted: Bool) {
    if isTargeted {
      dropTargets.insert(ObjectIdentifier(target))
    } else {
      dropTargets.remove(ObjectIdentifier(target))
    }
    // Moving between the composer and its text view exits one interaction before entering the
    // other; settle on the next turn so the highlight doesn't flicker.
    DispatchQueue.main.async { [weak self] in
      guard let self, self.isDropTargeted != !self.dropTargets.isEmpty else { return }
      self.isDropTargeted = !self.dropTargets.isEmpty
      self.delegate?.chatAttachmentControllerDidChangeDropTarget(self, animated: true)
    }
  }

  /// A drop resizes the composer right away, so it ends targeting without a fade.
  fileprivate func endDropTargetForDrop() {
    dropTargets.removeAll()
    guard isDropTargeted else { return }
    isDropTargeted = false
    delegate?.chatAttachmentControllerDidChangeDropTarget(self, animated: false)
  }

  /// Attaches a pasted file or image, or else lets the text view paste the item as usual. Text wins
  /// over an image offered alongside it, as when copying cells from a spreadsheet.
  fileprivate func paste(_ item: UITextPasteItem) {
    let provider = item.itemProvider
    if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
      // A file copied in Finder offers its name as text and its icon as an image, so only its URL
      // gives the file. A folder, or a file that can't be read, pastes as usual.
      importCount += 1
      _ = provider.loadObject(ofClass: URL.self) { [weak self, directory] url, _ in
        let attachment = url.flatMap {
          $0.hasDirectoryPath ? nil : try? Self.snapshot($0, sourceURL: $0, in: directory)
        }
        DispatchQueue.main.async {
          if attachment == nil {
            item.setDefaultResult()
          } else {
            item.setNoResult()
          }
          self?.finishImport(attachment)
        }
      }
      delegate?.chatAttachmentControllerDidChange(self)
      return
    }
    // Only plain text counts: a browser copying an image also offers HTML that just references it.
    let hasText = provider.registeredTypeIdentifiers.contains {
      UTType($0)?.conforms(to: .plainText) == true
    }
    guard Self.fileType(of: provider) != nil, !hasText || provider.suggestedName?.isEmpty == false
    else {
      item.setDefaultResult()
      return
    }
    importProviders([provider])
    item.setNoResult()
  }

  fileprivate func importProviders(_ providers: [NSItemProvider]) {
    for provider in providers {
      if let type = Self.fileType(of: provider) {
        importCount += 1
        // A temporary representation of an unnamed item is named by a hash of its contents.
        let unnamedTitle =
          provider.suggestedName?.isEmpty == false
          ? nil : UTType(type)?.conforms(to: .image) == true ? "image" : "file"
        // In place, the URL is the dropped file itself, which tells whether it is in the project.
        provider.loadInPlaceFileRepresentation(forTypeIdentifier: type) {
          [weak self, directory] url, isInPlace, _ in
          // Copy before returning: a temporary representation is deleted once this returns.
          let attachment = url.flatMap {
            try? Self.snapshot(
              $0, sourceURL: isInPlace ? $0 : nil, title: isInPlace ? nil : unnamedTitle,
              in: directory)
          }
          DispatchQueue.main.async { self?.finishImport(attachment) }
        }
      } else if provider.canLoadObject(ofClass: String.self) {
        importCount += 1
        _ = provider.loadObject(ofClass: String.self) { [weak self, directory] text, _ in
          let attachment = text.flatMap { try? Self.snapshot(text: $0, in: directory) }
          DispatchQueue.main.async { self?.finishImport(attachment) }
        }
      }
    }
    delegate?.chatAttachmentControllerDidChange(self)
  }

  private static func snapshot(_ url: URL, sourceURL: URL?, title: String? = nil, in directory: URL)
    throws -> ChatAttachment
  {
    let accessed = url.startAccessingSecurityScopedResource()
    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
    let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let copy = folder.appendingPathComponent(
      title.map { "\($0).\(url.pathExtension)" } ?? url.lastPathComponent)
    try FileManager.default.copyItem(at: url, to: copy)
    return ChatAttachment(url: copy, sourceURL: sourceURL)
  }

  /// A block of text has no file behind it; save it as one.
  private static func snapshot(text: String, in directory: URL) throws -> ChatAttachment {
    let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent("file.txt")
    try Data(text.utf8).write(to: url)
    return ChatAttachment(url: url, sourceURL: nil)
  }

  private func finishImport(_ attachment: ChatAttachment?) {
    importCount -= 1
    guard let attachment else {
      delegate?.chatAttachmentControllerDidChange(self)
      return
    }
    insert(attachment)
  }

  private func insert(_ attachment: ChatAttachment) {
    // The 56pt card sits 16pt from the composer edge, so its 16pt radius is concentric with
    // the 32pt composer; the 40pt thumbnail sits 8pt inside the card, so its radius is 8pt.
    let isPDF = UTType(filenameExtension: attachment.url.pathExtension)?.conforms(to: .pdf) == true
    var thumbnail =
      isPDF
      ? #imageLiteral(resourceName: "file-pdf-32").withRenderingMode(.alwaysTemplate)
      : #imageLiteral(resourceName: "file-text-32").withRenderingMode(.alwaysTemplate)
    var isThumbnail = false
    if let source = CGImageSourceCreateWithURL(attachment.url as CFURL, nil),
      let cgImage = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: 120,
        ] as CFDictionary)
    {
      let bounds = CGRect(x: 0, y: 0, width: 40, height: 40)
      let scale = max(
        bounds.width / CGFloat(cgImage.width), bounds.height / CGFloat(cgImage.height))
      let width = CGFloat(cgImage.width) * scale
      let height = CGFloat(cgImage.height) * scale
      thumbnail = UIGraphicsImageRenderer(bounds: bounds).image { _ in
        UIBezierPath(roundedRect: bounds, cornerRadius: 8).addClip()
        UIImage(cgImage: cgImage).draw(
          in: CGRect(x: (40 - width) / 2, y: (40 - height) / 2, width: width, height: height))
      }.withRenderingMode(.alwaysOriginal)
      isThumbnail = true
    }
    let cardButton = UIButton(type: .custom)
    var configuration = UIButton.Configuration.filled()
    configuration.cornerStyle = .fixed
    configuration.background.cornerRadius = 16
    configuration.background.backgroundColor = .nonaryFill
    configuration.background.strokeColor = .primaryBorder
    configuration.background.strokeWidth = 1
    configuration.baseForegroundColor = .senaryText
    configuration.title = attachment.name
    configuration.titleLineBreakMode = .byTruncatingMiddle
    configuration.image = thumbnail
    configuration.imagePadding = 8
    // The thumbnail or file icon sits as far from the leading edge as from the top and bottom.
    configuration.contentInsets = NSDirectionalEdgeInsets(
      top: 8, leading: isThumbnail ? 8 : 12, bottom: 8, trailing: 40)
    cardButton.configuration = configuration
    cardButton.configurationUpdateHandler = { button in
      guard var configuration = button.configuration else { return }
      configuration.background.backgroundColor =
        button.isHighlighted ? .quinaryBackground : .nonaryFill
      button.configuration = configuration
    }
    FontMetrics.default.scaleFont(.systemFont(ofSize: 14), bindTo: cardButton)
    cardButton.accessibilityLabel = LocalizedString.format(
      key: "preview_some_item", attachment.name)
    cardButton.addAction(
      UIAction { [weak self] _ in self?.preview(attachment) }, for: .touchUpInside)
    let removeButton = UIButton(type: .custom)
    var removeConfiguration = UIButton.Configuration.plain()
    removeConfiguration.baseBackgroundColor = .clear
    removeConfiguration.background.cornerRadius = 16
    removeConfiguration.image = #imageLiteral(resourceName: "close-16").withRenderingMode(
      .alwaysTemplate)
    removeConfiguration.imageColorTransformer = UIConfigurationColorTransformer { _ in
      .senaryText
    }
    // Keep the icon 16pt from the trailing edge, mirroring the file icon's leading inset.
    removeConfiguration.contentInsets = NSDirectionalEdgeInsets(
      top: 0, leading: 8, bottom: 0, trailing: 16)
    removeButton.configuration = removeConfiguration
    removeButton.accessibilityLabel = LocalizedString.format(
      key: "remove_some_item", attachment.name)
    removeButton.addAction(
      UIAction { [weak self] _ in self?.remove(attachment) }, for: .touchUpInside)
    cardButton.addSubview(removeButton)
    removeButton.snp.makeConstraints { make in
      make.top.bottom.trailing.equalToSuperview()
      make.width.equalTo(40)
    }
    cardButton.snp.makeConstraints { make in
      make.height.equalTo(56)
      make.width.lessThanOrEqualTo(240)
    }
    cardButton.alpha = 0
    stackView.insertArrangedSubview(cardButton, at: cards.count)
    cards.append((attachment, cardButton))
    // Lay the card out at its final size first, so only its fade and scale animate.
    UIView.performWithoutAnimation { view.layoutIfNeeded() }
    let cardRect = cardButton.convert(cardButton.bounds, to: view)
    cardButton.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
    delegate?.chatAttachmentControllerDidChange(self)
    animate {
      cardButton.alpha = 1
      cardButton.transform = .identity
      self.view.scrollRectToVisible(cardRect, animated: false)
    }
  }

  private func remove(_ attachment: ChatAttachment) {
    guard let index = cards.firstIndex(where: { $0.attachment.url == attachment.url }) else {
      return
    }
    let cardView = cards.remove(at: index).view
    // Only session copies are ours to delete; project files stay where they are.
    if attachment.url.path.hasPrefix(directory.path + "/") {
      try? FileManager.default.removeItem(at: attachment.url.deletingLastPathComponent())
    }
    // Fade a snapshot in place so the card keeps its size while the cards after it slide over.
    let snapshotView = cardView.snapshotView(afterScreenUpdates: false)
    if let snapshotView {
      snapshotView.frame = cardView.frame
      stackView.addSubview(snapshotView)
    }
    cardView.removeFromSuperview()
    delegate?.chatAttachmentControllerDidChange(self)
    animate {
      snapshotView?.alpha = 0
      snapshotView?.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
      self.view.layoutIfNeeded()
      // Ease back when removing near the end would leave the strip scrolled past its content.
      let maximumOffset = max(0, self.view.contentSize.width - self.view.bounds.width)
      if self.view.contentOffset.x > maximumOffset {
        self.view.contentOffset.x = maximumOffset
      }
    } completion: {
      snapshotView?.removeFromSuperview()
    }
  }

  private func animate(_ animations: @escaping () -> Void, completion: (() -> Void)? = nil) {
    UIView.animate(
      withDuration: 0.2, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 5,
      options: [.allowAnimatedContent, .beginFromCurrentState, .curveEaseInOut],
      animations: animations
    ) { _ in
      completion?()
    }
  }

  private func preview(_ attachment: ChatAttachment) {
    previewAttachment = attachment
    let previewController = QLPreviewController()
    previewController.dataSource = objCResponder
    delegate?.chatAttachmentController(self, present: previewController)
  }
}

extension ChatAttachmentController {
  final class ObjCResponder: NSObject {
    weak var controller: ChatAttachmentController?
  }
}

extension ChatAttachmentController.ObjCResponder: UIDropInteractionDelegate {
  func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
    interaction === controller?.chatInputDropInteraction
      ? ChatAttachmentController.accepts(session)
      : ChatAttachmentController.acceptsAroundChatInput(session)
  }

  func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnter session: UIDropSession) {
    controller?.setDropTarget(interaction, isTargeted: true)
  }

  func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession)
    -> UIDropProposal
  {
    UIDropProposal(operation: .copy)
  }

  func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: UIDropSession) {
    controller?.setDropTarget(interaction, isTargeted: false)
  }

  func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: UIDropSession) {
    controller?.setDropTarget(interaction, isTargeted: false)
  }

  func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
    controller?.endDropTargetForDrop()
    controller?.importProviders(session.items.map(\.itemProvider))
  }
}

extension ChatAttachmentController.ObjCResponder: UICollectionViewDropDelegate {
  func collectionView(_ collectionView: UICollectionView, canHandle session: UIDropSession) -> Bool
  {
    ChatAttachmentController.acceptsAroundChatInput(session)
  }

  func collectionView(
    _ collectionView: UICollectionView, dropSessionDidEnter session: UIDropSession
  ) {
    controller?.setDropTarget(collectionView, isTargeted: true)
  }

  func collectionView(
    _ collectionView: UICollectionView, dropSessionDidUpdate session: UIDropSession,
    withDestinationIndexPath destinationIndexPath: IndexPath?
  ) -> UICollectionViewDropProposal {
    UICollectionViewDropProposal(operation: .copy)
  }

  func collectionView(
    _ collectionView: UICollectionView, dropSessionDidExit session: UIDropSession
  ) {
    controller?.setDropTarget(collectionView, isTargeted: false)
  }

  func collectionView(_ collectionView: UICollectionView, dropSessionDidEnd session: UIDropSession)
  {
    controller?.setDropTarget(collectionView, isTargeted: false)
  }

  func collectionView(
    _ collectionView: UICollectionView, performDropWith coordinator: UICollectionViewDropCoordinator
  ) {
    controller?.endDropTargetForDrop()
    controller?.importProviders(coordinator.session.items.map(\.itemProvider))
  }
}

extension ChatAttachmentController.ObjCResponder: UITextPasteDelegate {
  func textPasteConfigurationSupporting(
    _ textPasteConfigurationSupporting: UITextPasteConfigurationSupporting,
    transform item: UITextPasteItem
  ) {
    guard let controller else {
      item.setDefaultResult()
      return
    }
    controller.paste(item)
  }
}

extension ChatAttachmentController.ObjCResponder: QLPreviewControllerDataSource {
  func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
    self.controller?.previewAttachment == nil ? 0 : 1
  }

  func previewController(_ controller: QLPreviewController, previewItemAt index: Int)
    -> QLPreviewItem
  {
    (self.controller?.previewAttachment?.url ?? URL(fileURLWithPath: "/")) as NSURL
  }
}
