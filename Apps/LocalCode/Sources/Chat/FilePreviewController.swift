import QuickLook
import UIKit

/// Quick Look on one file, full screen to zoom into, save, or share. It's its own data source and
/// delegate, which a preview controller holds weakly.
final class FilePreviewController: QLPreviewController, QLPreviewControllerDataSource,
  QLPreviewControllerDelegate
{
  private let url: URL
  private weak var sourceView: UIView?

  /// `sourceView` shows the file where it was opened from: the preview zooms out of it, and back
  /// into it when swiped down to close.
  init(url: URL, sourceView: UIView? = nil) {
    self.url = url
    self.sourceView = sourceView
    super.init(nibName: nil, bundle: nil)
    dataSource = self
    delegate = self
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

  func previewController(_ controller: QLPreviewController, previewItemAt index: Int)
    -> QLPreviewItem
  {
    url as NSURL
  }

  // Quick Look shows a file out of process on a device, where touches never reach this app's views,
  // so it has to close the file itself: it lets a swipe down close it only with a view to zoom to.
  func previewController(
    _ controller: QLPreviewController, transitionViewFor item: QLPreviewItem
  ) -> UIView? {
    sourceView
  }
}
