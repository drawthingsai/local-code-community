import Localization
import SnapKit
import Style
import UIKit

private final class DownloadView: UIView {
  weak var delegate: DownloadItemController? = nil
  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    delegate?.traitCollectionDidChange(previousTraitCollection)
  }
}

public final class DownloadItemController {
  public struct ViewModel {
    public enum Mode {
      case download
      case `import`
      case error
      case export
      case upload
    }
    public var image: UIImage
    public var title: String
    public var subtitle: String
    public var file: String
    public var index: Int
    public var totalDownloads: Int
    public var downloadedBytes: Int64
    public var transferredBytes: Int64?
    public var totalBytes: Int64
    public var mode: Mode
    public var progress: Double?
    public init(
      image: UIImage, title: String, subtitle: String, file: String, index: Int,
      totalDownloads: Int, downloadedBytes: Int64, totalBytes: Int64, mode: Mode,
      progress: Double? = nil, transferredBytes: Int64? = nil
    ) {
      self.image = image
      self.title = title
      self.subtitle = subtitle
      self.file = file
      self.index = index
      self.totalDownloads = totalDownloads
      self.downloadedBytes = downloadedBytes
      self.transferredBytes = transferredBytes
      self.totalBytes = totalBytes
      self.mode = mode
      self.progress = progress
    }

    public var finishedBytes: Int64 {
      guard totalBytes > 0, let transferredBytes else { return downloadedBytes }
      let completed = UInt64(min(totalBytes, max(0, downloadedBytes)))
      let transferred = UInt64(min(totalBytes, max(0, transferredBytes)))
      return Int64(clamping: (completed + transferred + 1) / 2)
    }
  }

  public var view: UIView { downloadView }

  private var downloadView: DownloadView
  private let imageView: UIImageView
  private let titleLabel: UILabel
  private let subtitleLabel: UILabel
  private let downloadingLabel: UILabel
  private let downloadingCountLabel: UILabel
  private let downloadedBytesLabel: UILabel
  private let totalBytesLabel: UILabel
  private let separatorBytesLabel: UILabel
  private let downloadedPercentLabel: UILabel
  private let onProgressBarDownloadedBytesLabel: UILabel
  private let onProgressBarTotalBytesLabel: UILabel
  private let onProgressBarSeparatorBytesLabel: UILabel
  private let onProgressBarDownloadedPercentLabel: UILabel

  private let onProgressBar: UIView
  private let onProgressBackground: UIView

  private let usesAnimation: Bool
  public var progressBarView: UIView { onProgressBackground }

  public var viewModel: ViewModel {
    didSet {
      imageView.image = viewModel.image
      if oldValue.title != viewModel.title {
        titleLabel.text = viewModel.title
      }
      if oldValue.subtitle != viewModel.subtitle {
        subtitleLabel.text = viewModel.subtitle.isEmpty ? "––" : viewModel.subtitle
      }
      if oldValue.file != viewModel.file || oldValue.mode != viewModel.mode {
        switch viewModel.mode {
        case .download:
          downloadingLabel.text = "\(LocalizedString.forKey("downloading")): \(viewModel.file)"
        case .import:
          downloadingLabel.text = "\(LocalizedString.forKey("importing")): \(viewModel.file)"
        case .error:
          downloadingLabel.text = "\(LocalizedString.forKey("error")): \(viewModel.file)"
        case .export:
          downloadingLabel.text = "\(LocalizedString.forKey("exporting")): \(viewModel.file)"
        case .upload:
          downloadingLabel.text = "\(LocalizedString.forKey("uploading")): \(viewModel.file)"
        }
      }
      if oldValue.index != viewModel.index || oldValue.totalDownloads != viewModel.totalDownloads {
        downloadingCountLabel.text =
          viewModel.totalDownloads > 1
          ? "\(viewModel.index + 1) of \(viewModel.totalDownloads)" : nil
      }
      if oldValue.downloadedBytes != viewModel.downloadedBytes
        || oldValue.transferredBytes != viewModel.transferredBytes
        || oldValue.totalBytes != viewModel.totalBytes
        || oldValue.progress != viewModel.progress
      {
        if viewModel.totalBytes > 0 {
          downloadedBytesLabel.text =
            "\((Double(viewModel.finishedBytes) / (1024 * 1024)).formatted(.number.precision(.fractionLength(2)))) MiB"
          totalBytesLabel.text =
            "\((Double(viewModel.totalBytes) / (1024 * 1024)).formatted(.number.precision(.fractionLength(2)))) MiB"
          onProgressBarDownloadedBytesLabel.text = downloadedBytesLabel.text
          onProgressBarTotalBytesLabel.text = totalBytesLabel.text
          separatorBytesLabel.isHidden = false
          onProgressBarSeparatorBytesLabel.isHidden = false
        } else {
          downloadedBytesLabel.text = nil
          totalBytesLabel.text = nil
          onProgressBarDownloadedBytesLabel.text = downloadedBytesLabel.text
          onProgressBarTotalBytesLabel.text = totalBytesLabel.text
          separatorBytesLabel.isHidden = true
          onProgressBarSeparatorBytesLabel.isHidden = true
        }

        let progress: Double =
          viewModel.progress
          ?? (viewModel.totalBytes > 0
            ? Double(viewModel.finishedBytes) / Double(viewModel.totalBytes) : 0)
        downloadedPercentLabel.text = progress.formatted(.percent.precision(.fractionLength(0)))

        onProgressBarDownloadedPercentLabel.text = downloadedPercentLabel.text
        // Text might need to layout, to avoid animate, layout first before changing onProgressBar constraints.
        if usesAnimation { view.layoutIfNeeded() }

        onProgressBar.snp.remakeConstraints { make in
          make.top.bottom.leading.equalToSuperview()
          make.width.equalToSuperview().multipliedBy(progress)
        }
        if usesAnimation {
          let view = view
          UIView.animate(
            withDuration: 0.1, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]
          ) {
            view.layoutIfNeeded()
          }
        }
      }
    }
  }

  public init(
    viewModel: ViewModel, headerTrailingInset: CGFloat = 24, contentInset: CGFloat = 24,
    progressBarInset: CGFloat = 12, fullyRoundedProgressBar: Bool = false,
    usesAnimation: Bool = true
  ) {
    self.viewModel = viewModel
    self.usesAnimation = usesAnimation
    downloadView = DownloadView(frame: .zero)
    downloadView.backgroundColor = .tertiaryBackground
    downloadView.layer.cornerRadius = 16
    downloadView.layer.borderWidth = 1
    downloadView.layer.borderColor = UIColor.primaryBorder.cgColor
    downloadView.layer.masksToBounds = true
    let borderView = BorderView.defaultBorderView()
    borderView.backgroundColor = .secondaryBackground
    borderView.layer.cornerRadius = 12
    borderView.layer.masksToBounds = true
    borderView.layer.shadowOpacity = 0.24
    borderView.layer.shadowColor = UIColor.black.cgColor
    borderView.layer.shadowRadius = 4
    borderView.layer.shadowOffset = CGSize(width: 0, height: 2)
    imageView = UIImageView(image: viewModel.image)
    imageView.contentMode = .scaleAspectFit
    imageView.layer.cornerRadius = 12
    imageView.layer.masksToBounds = true
    borderView.addSubview(imageView)
    downloadView.addSubview(borderView)
    borderView.snp.makeConstraints { make in
      make.top.leading.equalToSuperview().inset(contentInset)
      make.size.equalTo(48).priority(.high)
    }
    imageView.snp.makeConstraints { make in
      make.center.equalToSuperview()
      make.size.lessThanOrEqualTo(48)
    }
    titleLabel = UILabel(frame: .zero)
    titleLabel.textColor = .primaryText
    titleLabel.text = viewModel.title
    FontMetrics.default.scaleFont(.systemFont(ofSize: 14, weight: .medium), bindTo: titleLabel)
    titleLabel.lineBreakMode = .byTruncatingTail
    downloadView.addSubview(titleLabel)
    titleLabel.snp.makeConstraints { make in
      make.leading.equalTo(borderView.snp.trailing).offset(12)
      make.centerY.equalTo(borderView).offset(-12)
      make.trailing.equalToSuperview().offset(-headerTrailingInset)
    }
    subtitleLabel = UILabel(frame: .zero)
    subtitleLabel.textColor = .septenaryText
    subtitleLabel.text = viewModel.subtitle.isEmpty ? "––" : viewModel.subtitle
    FontMetrics.default.scaleFont(.systemFont(ofSize: 11, weight: .light), bindTo: subtitleLabel)
    downloadView.addSubview(subtitleLabel)
    subtitleLabel.snp.makeConstraints { make in
      make.centerY.equalTo(borderView).offset(12)
      make.leading.equalTo(borderView.snp.trailing).offset(12)
      make.trailing.lessThanOrEqualToSuperview().offset(-headerTrailingInset)
    }
    downloadingLabel = UILabel(frame: .zero)
    downloadingLabel.textColor = .secondaryText
    switch viewModel.mode {
    case .download:
      downloadingLabel.text = "\(LocalizedString.forKey("downloading")): \(viewModel.file)"
    case .import:
      downloadingLabel.text = "\(LocalizedString.forKey("importing")): \(viewModel.file)"
    case .error:
      downloadingLabel.text = "\(LocalizedString.forKey("error")): \(viewModel.file)"
    case .export:
      downloadingLabel.text = "\(LocalizedString.forKey("exporting")): \(viewModel.file)"
    case .upload:
      downloadingLabel.text = "\(LocalizedString.forKey("uploading")): \(viewModel.file)"
    }
    FontMetrics.default.scaleFont(.systemFont(ofSize: 14), bindTo: downloadingLabel)
    downloadingLabel.lineBreakMode = .byTruncatingTail
    downloadingLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    downloadView.addSubview(downloadingLabel)
    downloadingCountLabel = UILabel(frame: .zero)
    downloadingCountLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    downloadingCountLabel.textColor = .tertiaryText
    downloadingCountLabel.textAlignment = .right
    downloadingCountLabel.text =
      viewModel.totalDownloads > 1 ? "\(viewModel.index + 1) of \(viewModel.totalDownloads)" : nil
    FontMetrics.default.scaleFont(
      .systemFont(ofSize: 14, weight: .light), bindTo: downloadingCountLabel)
    downloadView.addSubview(downloadingCountLabel)
    let downloadingCountLabel = downloadingCountLabel
    downloadingLabel.snp.makeConstraints { make in
      make.leading.equalToSuperview().inset(contentInset)
      make.centerY.equalTo(borderView.snp.bottom).offset(24 + 10)
      make.trailing.equalTo(downloadingCountLabel.snp.leading).offset(-12)
    }
    let downloadingLabel = downloadingLabel
    downloadingCountLabel.snp.makeConstraints { make in
      make.trailing.equalToSuperview().inset(contentInset)
      make.centerY.equalTo(downloadingLabel)
    }
    onProgressBackground = UIView(frame: .zero)
    onProgressBackground.layer.cornerRadius = fullyRoundedProgressBar ? 16 : 8
    onProgressBackground.backgroundColor = .quinaryBackground
    onProgressBackground.layer.masksToBounds = true
    downloadView.addSubview(onProgressBackground)
    onProgressBackground.snp.makeConstraints { make in
      make.leading.trailing.bottom.equalToSuperview().inset(progressBarInset)
      make.height.equalTo(32)
      make.top.equalTo(downloadingLabel.snp.centerY).offset(18)
    }
    downloadedPercentLabel = UILabel(frame: .zero)
    downloadedPercentLabel.textColor = .quaternaryText
    FontMetrics.default.scaleFont(.systemFont(ofSize: 14), bindTo: downloadedPercentLabel)
    onProgressBackground.addSubview(downloadedPercentLabel)
    downloadedPercentLabel.snp.makeConstraints { make in
      make.centerY.equalToSuperview()
      make.leading.equalToSuperview().offset(12)
    }
    totalBytesLabel = UILabel(frame: .zero)
    totalBytesLabel.textColor = .quaternaryText
    totalBytesLabel.setContentHuggingPriority(.required, for: .horizontal)
    FontMetrics.default.scaleFont(.systemFont(ofSize: 14, weight: .light), bindTo: totalBytesLabel)
    onProgressBackground.addSubview(totalBytesLabel)
    totalBytesLabel.snp.makeConstraints { make in
      make.centerY.equalToSuperview()
      make.trailing.equalToSuperview().offset(-12)
    }
    separatorBytesLabel = UILabel(frame: .zero)
    separatorBytesLabel.text = "/"
    separatorBytesLabel.textColor = .quaternaryText
    separatorBytesLabel.setContentHuggingPriority(.required, for: .horizontal)
    FontMetrics.default.scaleFont(
      .systemFont(ofSize: 14, weight: .light), bindTo: separatorBytesLabel)
    onProgressBackground.addSubview(separatorBytesLabel)
    let totalBytesLabel = totalBytesLabel
    separatorBytesLabel.snp.makeConstraints { make in
      make.centerY.equalToSuperview()
      make.trailing.equalTo(totalBytesLabel.snp.leading).offset(-4)
    }
    downloadedBytesLabel = UILabel(frame: .zero)
    downloadedBytesLabel.textColor = .quaternaryText
    downloadedBytesLabel.textAlignment = .right
    FontMetrics.default.scaleFont(
      .systemFont(ofSize: 14, weight: .light), bindTo: downloadedBytesLabel)
    onProgressBackground.addSubview(downloadedBytesLabel)
    let separatorBytesLabel = separatorBytesLabel
    downloadedBytesLabel.snp.makeConstraints { make in
      make.centerY.equalToSuperview()
      make.trailing.equalTo(separatorBytesLabel.snp.leading).offset(-4)
      make.leading.equalToSuperview()
    }
    let progress: Double =
      viewModel.progress
      ?? (viewModel.totalBytes > 0
        ? Double(viewModel.finishedBytes) / Double(viewModel.totalBytes) : 0)
    onProgressBar = UIView(frame: .zero)
    onProgressBar.backgroundColor = .primaryFill
    onProgressBar.clipsToBounds = true
    onProgressBackground.addSubview(onProgressBar)
    onProgressBar.snp.makeConstraints { make in
      make.top.bottom.leading.equalToSuperview()
      make.width.equalToSuperview().multipliedBy(progress)
    }

    onProgressBarDownloadedPercentLabel = UILabel(frame: .zero)
    onProgressBarDownloadedPercentLabel.textColor = .nonaryText
    FontMetrics.default.scaleFont(
      .systemFont(ofSize: 14), bindTo: onProgressBarDownloadedPercentLabel)
    onProgressBar.addSubview(onProgressBarDownloadedPercentLabel)
    let downloadedPercentLabel = downloadedPercentLabel
    onProgressBarDownloadedPercentLabel.snp.makeConstraints { make in
      make.edges.equalTo(downloadedPercentLabel)
    }
    onProgressBarTotalBytesLabel = UILabel(frame: .zero)
    onProgressBarTotalBytesLabel.textColor = .nonaryText
    FontMetrics.default.scaleFont(
      .systemFont(ofSize: 14, weight: .light), bindTo: onProgressBarTotalBytesLabel)
    onProgressBar.addSubview(onProgressBarTotalBytesLabel)
    onProgressBarTotalBytesLabel.snp.makeConstraints { make in
      make.edges.equalTo(totalBytesLabel)
    }
    onProgressBarSeparatorBytesLabel = UILabel(frame: .zero)
    onProgressBarSeparatorBytesLabel.text = "/"
    onProgressBarSeparatorBytesLabel.textColor = .nonaryText
    FontMetrics.default.scaleFont(
      .systemFont(ofSize: 14, weight: .light), bindTo: onProgressBarSeparatorBytesLabel)
    onProgressBar.addSubview(onProgressBarSeparatorBytesLabel)
    onProgressBarSeparatorBytesLabel.snp.makeConstraints { make in
      make.edges.equalTo(separatorBytesLabel)
    }
    onProgressBarDownloadedBytesLabel = UILabel(frame: .zero)
    onProgressBarDownloadedBytesLabel.textColor = .nonaryText
    onProgressBarDownloadedBytesLabel.textAlignment = .right
    FontMetrics.default.scaleFont(
      .systemFont(ofSize: 14, weight: .light), bindTo: onProgressBarDownloadedBytesLabel)
    onProgressBar.addSubview(onProgressBarDownloadedBytesLabel)
    let downloadedBytesLabel = downloadedBytesLabel
    onProgressBarDownloadedBytesLabel.snp.makeConstraints { make in
      make.edges.equalTo(downloadedBytesLabel)
    }
    downloadedPercentLabel.text = progress.formatted(.percent.precision(.fractionLength(0)))
    onProgressBarDownloadedPercentLabel.text = downloadedPercentLabel.text

    if viewModel.totalBytes > 0 {
      downloadedBytesLabel.text =
        "\((Double(viewModel.finishedBytes) / (1024 * 1024)).formatted(.number.precision(.fractionLength(2)))) MiB"
      totalBytesLabel.text =
        "\((Double(viewModel.totalBytes) / (1024 * 1024)).formatted(.number.precision(.fractionLength(2)))) MiB"
      separatorBytesLabel.isHidden = false
      onProgressBarSeparatorBytesLabel.isHidden = false
    } else {
      downloadedBytesLabel.text = nil
      totalBytesLabel.text = nil
      onProgressBarDownloadedBytesLabel.text = downloadedBytesLabel.text
      onProgressBarTotalBytesLabel.text = totalBytesLabel.text
      separatorBytesLabel.isHidden = true
      onProgressBarSeparatorBytesLabel.isHidden = true
    }

    onProgressBarDownloadedBytesLabel.text = downloadedBytesLabel.text
    onProgressBarTotalBytesLabel.text = totalBytesLabel.text

    downloadView.delegate = self
  }

  fileprivate func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    view.layer.borderColor = UIColor.primaryBorder.cgColor
  }
}
