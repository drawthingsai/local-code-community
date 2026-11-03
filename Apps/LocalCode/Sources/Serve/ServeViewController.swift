import Components
import Localization
import SnapKit
import Style
import SwiftUI
import UIKit

protocol ServeViewControllerDelegate: AnyObject {
  func serveViewController(_ viewController: ServeViewController, didCopy text: String)
  func serveViewController(
    _ viewController: ServeViewController, displayNameForModel model: String
  ) -> String
}

final class ServeViewController: UIViewController {
  private static let spacing: CGFloat = 16
  private static let maximumColumnWidth: CGFloat = 1_120
  /// Below this, two cards side by side would leave a chart too narrow to read.
  private static let minimumWideColumnWidth: CGFloat = 680
  private static let minimumFullTableColumnWidth: CGFloat = 640
  private static let chartHeight: CGFloat = 150
  /// Plotted in gigabytes, for axis marks at round numbers.
  private static let bytesPerGigabyte: Double = 1_073_741_824
  private static func curlExample(port: Int) -> String {
    """
    curl \(ServeController.baseURL(port: port))/responses \\
      -H "Content-Type: application/json" \\
      -d '{"input": "Say hello.", "stream": true}'
    """
  }

  weak var delegate: ServeViewControllerDelegate?
  var state = ServeState() {
    didSet {
      guard isViewLoaded, state != oldValue else { return }
      render()
      if state.metrics != oldValue.metrics {
        renderMetrics()
      }
    }
  }
  var contextCachePath: String? {
    didSet {
      guard isViewLoaded else { return }
      render()
    }
  }

  private lazy var scrollView: UIScrollView = {
    let scrollView = UIScrollView()
    scrollView.alwaysBounceVertical = true
    scrollView.showsVerticalScrollIndicator = false
    scrollView.showsHorizontalScrollIndicator = false
    scrollView.contentInsetAdjustmentBehavior = .never
    scrollView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 32, right: 0)
    return scrollView
  }()
  // Cards soften as they scroll under the top edge, as the chat and Model Speed do.
  private lazy var topBlurMaskLayer: CAGradientLayer = {
    let gradientLayer = CAGradientLayer()
    gradientLayer.colors = [
      UIColor.white.cgColor,
      UIColor.white.withAlphaComponent(0.8).cgColor,
      UIColor.white.withAlphaComponent(0).cgColor,
    ]
    gradientLayer.locations = [0, 0.2, 1]
    return gradientLayer
  }()
  private lazy var topBlurView: LayoutVisualEffectView = {
    let visualEffectView = LayoutVisualEffectView(
      effect: UIBlurEffect(style: .systemThickMaterial))
    visualEffectView.isUserInteractionEnabled = false
    visualEffectView.layer.mask = topBlurMaskLayer
    let maskLayer = topBlurMaskLayer
    visualEffectView.onLayoutChange = { view in
      guard maskLayer.frame != view.bounds else { return }
      maskLayer.frame = view.bounds
    }
    let shadeView = UIView(frame: .zero)
    shadeView.backgroundColor = .tertiaryBackground
    visualEffectView.contentView.addSubview(shadeView)
    shadeView.snp.makeConstraints { make in
      make.edges.equalToSuperview()
    }
    return visualEffectView
  }()
  private lazy var scrollIndicatorController: VerticalScrollIndicatorController = {
    let controller = VerticalScrollIndicatorController(scrollView: scrollView)
    scrollView.delegate = controller.objCResponder
    return controller
  }()
  private lazy var scrollContent = UIView()
  private lazy var column = UIView()
  private lazy var pageStack: UIStackView = {
    let stack = UIStackView()
    stack.axis = .vertical
    stack.spacing = Self.spacing
    return stack
  }()
  /// Side by side where the page is wide enough, or else one above the other.
  private var adaptiveRows = [UIStackView]()
  private var isWideLayout: Bool?
  private var showsAllRequestColumns = true
  private lazy var titleLabel: UILabel = {
    let label = UILabel()
    label.numberOfLines = 0
    label.text = LocalizedString.forKey("serve")
    label.textColor = .primaryText
    FontMetrics.default.scaleFont(.systemFont(ofSize: 28, weight: .medium), bindTo: label)
    return label
  }()
  private lazy var subtitleLabel: UILabel = {
    let label = UILabel()
    label.numberOfLines = 0
    label.text = LocalizedString.forKey("serve_subtitle_detail")
    label.textColor = .senaryText
    FontMetrics.default.scaleFont(.systemFont(ofSize: 14, weight: .light), bindTo: label)
    return label
  }()

  private lazy var statusValueLabel = makeValueLabel()
  private lazy var addressValueLabel = makeValueLabel(isMonospaced: true)
  private lazy var addressCopyButton = makeCopyButton { [weak self] in
    ServeController.baseURL(port: self?.state.port ?? ServeController.defaultPort)
  }
  private lazy var addressRow = makeRow(
    title: LocalizedString.forKey("address"), valueLabel: addressValueLabel,
    accessoryView: addressCopyButton)
  private lazy var modelValueLabel = makeValueLabel()
  private lazy var modelRow = makeRow(
    title: LocalizedString.forKey("model"), valueLabel: modelValueLabel)
  private lazy var hintLabel: UILabel = {
    let label = makeDetailLabel()
    label.text = LocalizedString.forKey("serve_off_detail")
    return label
  }()

  private lazy var nowValueLabel = makeValueLabel()
  private lazy var inLineValueLabel = makeValueLabel()
  private lazy var prefillProgressView: UIProgressView = {
    let progressView = UIProgressView(progressViewStyle: .bar)
    progressView.progressTintColor = ServeChartColor.prefill
    progressView.trackTintColor = .primaryBorder
    progressView.layer.cornerRadius = 2
    progressView.clipsToBounds = true
    return progressView
  }()

  private lazy var servedValueLabel = makeTileValueLabel()
  private lazy var servedCaptionLabel = makeTileCaptionLabel()
  private lazy var generatedValueLabel = makeTileValueLabel()
  private lazy var generatedCaptionLabel = makeTileCaptionLabel()
  private lazy var cacheReuseValueLabel = makeTileValueLabel()
  private lazy var cacheReuseCaptionLabel = makeTileCaptionLabel()
  private lazy var firstTokenValueLabel = makeTileValueLabel()
  private lazy var firstTokenCaptionLabel = makeTileCaptionLabel()

  private lazy var generationSpeedChart = UIHostingController(
    rootView: makeGenerationSpeedChart(metrics: ServeMetrics()))
  private lazy var prefillSpeedChart = UIHostingController(
    rootView: makePrefillSpeedChart(metrics: ServeMetrics()))
  private lazy var promptTokensChart = UIHostingController(
    rootView: makePromptTokensChart(metrics: ServeMetrics()))
  private lazy var requestTimeChart = UIHostingController(
    rootView: makeRequestTimeChart(metrics: ServeMetrics()))
  private lazy var memoryChart = UIHostingController(
    rootView: makeMemoryChart(metrics: ServeMetrics()))
  private lazy var contextCacheChart = UIHostingController(
    rootView: makeContextCacheChart(metrics: ServeMetrics()))
  private lazy var requestsTable: UIHostingController<ServeRequestsTableView> = {
    let controller = UIHostingController(
      rootView: ServeRequestsTableView(requests: [], showsAllColumns: true))
    controller.sizingOptions = .intrinsicContentSize
    return controller
  }()

  private lazy var curlCopyButton = makeCopyButton { [weak self] in
    Self.curlExample(port: self?.state.port ?? ServeController.defaultPort)
  }
  private lazy var curlLabel: UILabel = {
    let label = makeDetailLabel()
    label.textColor = .primaryText
    label.lineBreakMode = .byCharWrapping
    FontMetrics.default.scaleFont(
      .monospacedSystemFont(ofSize: 12, weight: .regular), bindTo: label)
    return label
  }()

  private lazy var cachePathValueLabel: UILabel = {
    let label = makeValueLabel(isMonospaced: true)
    label.numberOfLines = 1
    label.lineBreakMode = .byTruncatingHead
    return label
  }()

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .tertiaryBackground
    view.addSubview(scrollView)
    view.addSubview(topBlurView)
    view.addSubview(scrollIndicatorController.view)
    scrollView.addSubview(scrollContent)
    scrollContent.addSubview(column)
    column.addSubview(pageStack)
    scrollView.snp.makeConstraints { make in
      make.edges.equalToSuperview()
    }
    topBlurView.snp.makeConstraints { make in
      make.top.equalTo(scrollView)
      make.height.equalTo(26)
      make.leading.trailing.equalToSuperview()
    }
    scrollIndicatorController.view.snp.makeConstraints { make in
      make.top.bottom.trailing.equalToSuperview()
      make.width.equalTo(12)
    }
    scrollContent.snp.makeConstraints { make in
      make.edges.equalTo(scrollView.contentLayoutGuide)
      make.width.equalTo(scrollView.frameLayoutGuide)
    }
    // The page scrolls, so it starts as far from the top as from the sides, rather than as low as
    // Model Speed's, which fits on one screen.
    column.snp.makeConstraints { make in
      make.top.equalToSuperview().offset(24)
      make.bottom.equalToSuperview()
      make.centerX.equalToSuperview()
      make.leading.greaterThanOrEqualToSuperview().offset(24)
      make.trailing.lessThanOrEqualToSuperview().offset(-24)
      make.width.lessThanOrEqualTo(Self.maximumColumnWidth)
      // Above the rows' compression resistance and hugging, so the column sets their width.
      make.width.equalToSuperview().offset(-48).priority(.required.advanced(by: -1))
      make.width.equalTo(Self.maximumColumnWidth).priority(.required.advanced(by: -2))
    }
    pageStack.snp.makeConstraints { make in
      make.edges.equalToSuperview()
    }

    let heading = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
    heading.axis = .vertical
    heading.spacing = 4
    heading.isLayoutMarginsRelativeArrangement = true
    heading.layoutMargins = UIEdgeInsets(top: 6, left: 12, bottom: 8, right: 12)
    pageStack.addArrangedSubview(heading)

    prefillProgressView.snp.makeConstraints { make in
      make.height.equalTo(4)
    }
    addRow(
      makeCard(
        title: LocalizedString.forKey("responses_api"), titleAccessoryView: nil,
        rows: [
          makeRow(title: LocalizedString.forKey("status"), valueLabel: statusValueLabel),
          addressRow,
          modelRow,
          hintLabel,
        ]),
      makeCard(
        title: LocalizedString.forKey("activities"), titleAccessoryView: nil,
        rows: [
          makeRow(title: LocalizedString.forKey("now"), valueLabel: nowValueLabel),
          prefillProgressView,
          makeRow(title: LocalizedString.forKey("in_line"), valueLabel: inLineValueLabel),
        ]))
    // Two and two when they can't all fit in a row, as each only needs a number's width.
    addRow(
      makeTilePair(
        makeTile(
          title: LocalizedString.forKey("served"), valueLabel: servedValueLabel,
          captionLabel: servedCaptionLabel),
        makeTile(
          title: LocalizedString.forKey("tokens_generated"), valueLabel: generatedValueLabel,
          captionLabel: generatedCaptionLabel)),
      makeTilePair(
        makeTile(
          title: LocalizedString.forKey("cache_reuse"), valueLabel: cacheReuseValueLabel,
          captionLabel: cacheReuseCaptionLabel),
        makeTile(
          title: LocalizedString.forKey("time_to_first_token"), valueLabel: firstTokenValueLabel,
          captionLabel: firstTokenCaptionLabel)))
    addRow(
      makeChartCard(title: LocalizedString.forKey("token_generation"), chart: generationSpeedChart),
      makeChartCard(title: LocalizedString.forKey("prompt_processing"), chart: prefillSpeedChart))
    addRow(
      makeChartCard(title: LocalizedString.forKey("prompt_tokens"), chart: promptTokensChart),
      makeChartCard(title: LocalizedString.forKey("time_per_request"), chart: requestTimeChart))
    addRow(
      makeChartCard(title: LocalizedString.forKey("memory"), chart: memoryChart),
      makeChartCard(
        title: LocalizedString.forKey("context_cache"), chart: contextCacheChart,
        rows: [
          makeRow(title: LocalizedString.forKey("location"), valueLabel: cachePathValueLabel),
          {
            let label = makeDetailLabel()
            label.text = LocalizedString.forKey("serve_context_cache_detail")
            return label
          }(),
        ]))
    addRow(
      makeCard(
        title: LocalizedString.forKey("try_it"), titleAccessoryView: curlCopyButton,
        rows: [curlLabel]),
      makeCard(
        title: LocalizedString.forKey("limits"), titleAccessoryView: nil,
        rows: [
          {
            let label = makeDetailLabel()
            label.text = LocalizedString.forKey("serve_limits_detail")
            return label
          }()
        ]))
    addChild(requestsTable)
    requestsTable.view.backgroundColor = .clear
    pageStack.addArrangedSubview(
      makeCard(
        title: LocalizedString.forKey("recent_requests"), titleAccessoryView: nil,
        rows: [requestsTable.view]))
    requestsTable.didMove(toParent: self)
    render()
    renderMetrics()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    // From the view, as the column only gets its width after this, in the scroll view's layout.
    let columnWidth = min(view.bounds.width - 48, Self.maximumColumnWidth)
    let showsAllRequestColumns =
      columnWidth >= Self.minimumFullTableColumnWidth * FontMetrics.default.size.rawValue
    if showsAllRequestColumns != self.showsAllRequestColumns {
      self.showsAllRequestColumns = showsAllRequestColumns
      requestsTable.rootView = ServeRequestsTableView(
        requests: state.metrics.requests, showsAllColumns: showsAllRequestColumns)
    }
    let isWideLayout = columnWidth >= Self.minimumWideColumnWidth
    guard isWideLayout != self.isWideLayout else { return }
    self.isWideLayout = isWideLayout
    for row in adaptiveRows {
      row.axis = isWideLayout ? .horizontal : .vertical
      row.distribution = isWideLayout ? .fillEqually : .fill
    }
  }

  private func addRow(_ first: UIView, _ second: UIView) {
    let row = UIStackView(arrangedSubviews: [first, second])
    row.axis = .vertical
    row.spacing = Self.spacing
    adaptiveRows.append(row)
    pageStack.addArrangedSubview(row)
  }

  private func render() {
    switch state.listener {
    case .off:
      statusValueLabel.text = LocalizedString.forKey("off")
    case .starting:
      statusValueLabel.text = LocalizedString.forKey("starting_dot")
    case .listening:
      statusValueLabel.text = LocalizedString.forKey("listening")
    case .portInUse:
      statusValueLabel.text = LocalizedString.format(
        key: "port_x_is_in_use", String(state.port))
    case .failed(let message):
      statusValueLabel.text = LocalizedString.format(key: "could_not_start_x", message)
    }
    hintLabel.isHidden = state.isEnabled
    addressRow.isHidden = state.listener != .listening
    // While off, nothing here knows the model; the settings beside the page show it.
    modelRow.isHidden = !state.isEnabled
    addressValueLabel.text = ServeController.baseURL(port: state.port)
    curlLabel.text = Self.curlExample(port: state.port)
    modelValueLabel.text =
      state.model.flatMap { delegate?.serveViewController(self, displayNameForModel: $0) }
      ?? LocalizedString.forKey("unspecified")

    switch state.activePhase {
    case nil:
      nowValueLabel.text = LocalizedString.forKey("idle")
    case .waiting:
      nowValueLabel.text = LocalizedString.forKey("waiting_for_the_chat")
    case .prefilling(let finished, let total):
      nowValueLabel.text = LocalizedString.format(
        key: "processing_x_of_y_tokens", Self.count(finished), Self.count(total))
    case .generating(let tokens, let tokensPerSecond):
      nowValueLabel.text = LocalizedString.format(
        key: "generating_x_tokens_at_y", Self.count(tokens), Self.count(Int(tokensPerSecond)))
    }
    if case .prefilling(let finished, let total) = state.activePhase, total > 0 {
      prefillProgressView.isHidden = false
      prefillProgressView.progress = Float(finished) / Float(total)
    } else {
      prefillProgressView.isHidden = true
    }
    inLineValueLabel.text = Self.count(state.queuedRequestCount)
    cachePathValueLabel.text = contextCachePath ?? "–"
  }

  private func renderMetrics() {
    let metrics = state.metrics
    servedValueLabel.text = Self.count(metrics.requestCount)
    servedCaptionLabel.text = LocalizedString.format(
      key: "x_failed", Self.count(metrics.failedRequestCount))
    generatedValueLabel.text = ServeChartFormat.compactCount(Double(metrics.outputTokens))
    generatedCaptionLabel.text = LocalizedString.format(
      key: "x_tokens_processed",
      ServeChartFormat.compactCount(Double(metrics.inputTokens - metrics.cachedInputTokens)))
    cacheReuseValueLabel.text =
      metrics.cacheReuse?.formatted(.percent.precision(.fractionLength(0))) ?? "–"
    cacheReuseCaptionLabel.text = LocalizedString.format(
      key: "x_of_y_tokens", ServeChartFormat.compactCount(Double(metrics.cachedInputTokens)),
      ServeChartFormat.compactCount(Double(metrics.inputTokens)))
    firstTokenValueLabel.text = metrics.medianTimeToFirstToken.map(ServeChartFormat.seconds) ?? "–"
    firstTokenCaptionLabel.text =
      metrics.requests.isEmpty
      ? "–" : LocalizedString.format(key: "median_of_last_x", Self.count(metrics.requests.count))

    generationSpeedChart.rootView = makeGenerationSpeedChart(metrics: metrics)
    prefillSpeedChart.rootView = makePrefillSpeedChart(metrics: metrics)
    promptTokensChart.rootView = makePromptTokensChart(metrics: metrics)
    requestTimeChart.rootView = makeRequestTimeChart(metrics: metrics)
    memoryChart.rootView = makeMemoryChart(metrics: metrics)
    contextCacheChart.rootView = makeContextCacheChart(metrics: metrics)
    requestsTable.rootView = ServeRequestsTableView(
      requests: metrics.requests, showsAllColumns: showsAllRequestColumns)
  }

  private func timePoints(
    of metrics: ServeMetrics, value: (ServeMetrics.Sample) -> Double
  ) -> [ServeTimeChartView.Point] {
    guard let latest = metrics.samples.last?.date else { return [] }
    return metrics.samples.map {
      ServeTimeChartView.Point(
        secondsAgo: $0.date.timeIntervalSince(latest), value: value($0))
    }
  }

  private func makeGenerationSpeedChart(metrics: ServeMetrics) -> ServeTimeChartView {
    // Over the time spent generating, which is what the speed of the model is about.
    let speeds = metrics.samples.map(\.generationTokensPerSecond).filter { $0 > 0 }
    let average = speeds.isEmpty ? nil : speeds.reduce(0, +) / Double(speeds.count)
    return ServeTimeChartView(
      color: ServeChartColor.generation,
      points: timePoints(of: metrics) { $0.generationTokensPerSecond }, minimumScale: 10,
      rule: average,
      caption: average.map {
        LocalizedString.format(key: "average_x", ServeChartFormat.speed($0))
      },
      format: { value in
        value >= 1_000 ? ServeChartFormat.compactCount(value) : ServeChartFormat.speed(value)
      }, axisFormat: ServeChartFormat.axisSpeed)
  }

  private func makePrefillSpeedChart(metrics: ServeMetrics) -> ServeRequestChartView {
    let speeds = metrics.requests.map(\.prefillTokensPerSecond).filter { $0 > 0 }
    let average = speeds.isEmpty ? nil : speeds.reduce(0, +) / Double(speeds.count)
    return ServeRequestChartView(
      series: [
        .init(title: LocalizedString.forKey("prompt"), color: ServeChartColor.prefill)
      ],
      bars: metrics.requests.map { .init(id: $0.id, values: [$0.prefillTokensPerSecond]) },
      minimumScale: 100, rule: average,
      caption: average.map {
        LocalizedString.format(key: "average_x", ServeChartFormat.speed($0))
      }, format: ServeChartFormat.speed, axisFormat: ServeChartFormat.axisSpeed)
  }

  private func makePromptTokensChart(metrics: ServeMetrics) -> ServeRequestChartView {
    ServeRequestChartView(
      series: [
        .init(title: LocalizedString.forKey("cached"), color: ServeChartColor.cache),
        .init(title: LocalizedString.forKey("processed"), color: ServeChartColor.prefill),
      ],
      bars: metrics.requests.map {
        .init(
          id: $0.id,
          values: [Double($0.cachedInputTokens), Double($0.inputTokens - $0.cachedInputTokens)])
      },
      minimumScale: 100, format: ServeChartFormat.compactCount)
  }

  private func makeRequestTimeChart(metrics: ServeMetrics) -> ServeRequestChartView {
    ServeRequestChartView(
      series: [
        .init(title: LocalizedString.forKey("waiting"), color: ServeChartColor.waiting),
        .init(title: LocalizedString.forKey("prompt"), color: ServeChartColor.prefill),
        .init(title: LocalizedString.forKey("generation"), color: ServeChartColor.generation),
      ],
      bars: metrics.requests.map {
        .init(
          id: $0.id,
          values: [$0.timing.waitingSeconds, $0.timing.prefillSeconds, $0.timing.generationSeconds])
      },
      minimumScale: 1, format: ServeChartFormat.seconds, axisFormat: ServeChartFormat.axisSeconds)
  }

  private func makeMemoryChart(metrics: ServeMetrics) -> ServeTimeChartView {
    ServeTimeChartView(
      color: ServeChartColor.memory,
      points: timePoints(of: metrics) { Double($0.memoryBytes) / Self.bytesPerGigabyte },
      minimumScale: 1,
      caption: LocalizedString.format(
        key: "of_x",
        ByteCountFormatter.string(
          fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory), countStyle: .memory)),
      format: ServeChartFormat.gigabytes, axisFormat: ServeChartFormat.axisGigabytes)
  }

  private func makeContextCacheChart(metrics: ServeMetrics) -> ServeTimeChartView {
    ServeTimeChartView(
      color: ServeChartColor.cache,
      points: timePoints(of: metrics) { Double($0.contextCacheBytes) / Self.bytesPerGigabyte },
      minimumScale: 1, format: ServeChartFormat.gigabytes,
      axisFormat: ServeChartFormat.axisGigabytes)
  }

  private static func count(_ value: Int) -> String {
    NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
  }

  /// A chart's height gives way where the card beside it is taller.
  private func makeChartCard<Content: View>(
    title: String, chart: UIHostingController<Content>, rows: [UIView] = []
  ) -> UIView {
    addChild(chart)
    chart.view.backgroundColor = .clear
    let card = makeCard(
      title: title, titleAccessoryView: nil, rows: [chart.view] + rows, fillsHeight: true)
    chart.didMove(toParent: self)
    chart.view.snp.makeConstraints { make in
      make.height.greaterThanOrEqualTo(Self.chartHeight)
      // Below the labels' hugging, so the chart is what takes the extra height.
      make.height.equalTo(Self.chartHeight).priority(UILayoutPriority.defaultLow.rawValue - 1)
    }
    return card
  }

  private func makeTile(title: String, valueLabel: UILabel, captionLabel: UILabel) -> UIView {
    let card = BorderView.defaultBorderView(cornerRadius: 16)
    card.backgroundColor = .novemdecenaryBackground
    card.borderColor = .primaryBorder

    let titleLabel = UILabel()
    titleLabel.text = title
    titleLabel.numberOfLines = 0
    titleLabel.textColor = .senaryText
    FontMetrics.default.scaleFont(.systemFont(ofSize: 13, weight: .light), bindTo: titleLabel)

    let stack = UIStackView(arrangedSubviews: [titleLabel, valueLabel, captionLabel])
    stack.axis = .vertical
    stack.spacing = 4
    card.addSubview(stack)
    stack.snp.makeConstraints { make in
      make.edges.equalToSuperview().inset(UIEdgeInsets(top: 14, left: 16, bottom: 14, right: 16))
    }
    return card
  }

  private func makeTilePair(_ first: UIView, _ second: UIView) -> UIView {
    let pair = UIStackView(arrangedSubviews: [first, second])
    pair.axis = .horizontal
    pair.distribution = .fillEqually
    pair.spacing = Self.spacing
    return pair
  }

  private func makeTileValueLabel() -> UILabel {
    let label = UILabel()
    label.textColor = .primaryText
    label.adjustsFontSizeToFitWidth = true
    label.minimumScaleFactor = 0.6
    FontMetrics.default.scaleFont(
      .monospacedDigitSystemFont(ofSize: 24, weight: .medium), bindTo: label)
    return label
  }

  private func makeTileCaptionLabel() -> UILabel {
    let label = UILabel()
    label.numberOfLines = 0
    label.textColor = .senaryText
    FontMetrics.default.scaleFont(.systemFont(ofSize: 12, weight: .light), bindTo: label)
    return label
  }

  /// Beside a taller card, `fillsHeight` stretches its rows to match, or else they stay at the top.
  private func makeCard(
    title: String, titleAccessoryView: UIView?, rows: [UIView], fillsHeight: Bool = false
  ) -> UIView {
    let card = BorderView.defaultBorderView(cornerRadius: 16)
    card.backgroundColor = .novemdecenaryBackground
    card.borderColor = .primaryBorder

    let titleLabel = UILabel()
    titleLabel.numberOfLines = 0
    titleLabel.text = title
    titleLabel.textColor = .primaryText
    FontMetrics.default.scaleFont(.systemFont(ofSize: 16, weight: .medium), bindTo: titleLabel)

    let titleRow = UIStackView(
      arrangedSubviews: [titleLabel] + [titleAccessoryView].compactMap { $0 })
    titleRow.axis = .horizontal
    titleRow.alignment = .center
    titleRow.spacing = 8

    let stack = UIStackView(arrangedSubviews: [titleRow] + rows)
    stack.axis = .vertical
    stack.spacing = 8
    stack.setCustomSpacing(12, after: titleRow)
    card.addSubview(stack)
    // A stack view with its row centered could otherwise take the extra height itself.
    titleRow.snp.makeConstraints { make in
      make.height.equalTo(0).priority(UILayoutPriority.defaultLow.rawValue + 1)
    }
    stack.snp.makeConstraints { make in
      make.top.equalToSuperview().inset(16)
      make.leading.trailing.equalToSuperview().inset(20)
      if fillsHeight {
        make.bottom.equalToSuperview().inset(16)
      } else {
        make.height.equalTo(0).priority(UILayoutPriority.defaultLow.rawValue + 1)
        make.bottom.lessThanOrEqualToSuperview().inset(16)
        make.bottom.equalToSuperview().inset(16).priority(.low)
      }
    }
    return card
  }

  private func makeRow(title: String, valueLabel: UILabel, accessoryView: UIView? = nil) -> UIView {
    let titleLabel = UILabel()
    titleLabel.text = title
    titleLabel.textColor = .senaryText
    FontMetrics.default.scaleFont(.systemFont(ofSize: 13, weight: .light), bindTo: titleLabel)
    titleLabel.setContentHuggingPriority(.required, for: .horizontal)
    titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

    let row = UIStackView(
      arrangedSubviews: [titleLabel, valueLabel] + [accessoryView].compactMap { $0 })
    row.axis = .horizontal
    row.alignment = accessoryView == nil ? .firstBaseline : .center
    row.spacing = 12
    return row
  }

  private func makeValueLabel(isMonospaced: Bool = false) -> UILabel {
    let label = UILabel()
    label.numberOfLines = 0
    label.textAlignment = .right
    label.textColor = .primaryText
    FontMetrics.default.scaleFont(
      isMonospaced
        ? .monospacedSystemFont(ofSize: 13, weight: .regular)
        : .systemFont(ofSize: 13, weight: .regular), bindTo: label)
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return label
  }

  private func makeDetailLabel() -> UILabel {
    let label = UILabel()
    label.numberOfLines = 0
    label.textColor = .senaryText
    FontMetrics.default.scaleFont(.systemFont(ofSize: 13, weight: .light), bindTo: label)
    return label
  }

  /// Says it copied for a moment in place of its title.
  private func makeCopyButton(text: @escaping () -> String) -> UIButton {
    let button = UIButton(type: .custom)
    var configuration = UIButton.Configuration.plain()
    configuration.baseBackgroundColor = .clear
    configuration.background.cornerRadius = 12
    configuration.cornerStyle = .capsule
    configuration.contentInsets = NSDirectionalEdgeInsets(
      top: 4, leading: 8, bottom: 4, trailing: 8)
    configuration.baseForegroundColor = .senaryText
    configuration.title = LocalizedString.forKey("copy")
    configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
      var attributes = $0
      attributes.font = .systemFont(ofSize: 12, weight: .medium)
      return attributes
    }
    button.configuration = configuration
    button.configurationUpdateHandler = { button in
      guard var configuration = button.configuration else { return }
      configuration.background.backgroundColor =
        button.isHighlighted ? .quinaryBackground : .clear
      button.configuration = configuration
    }
    button.setContentHuggingPriority(.required, for: .horizontal)
    button.setContentCompressionResistancePriority(.required, for: .horizontal)
    button.addAction(
      UIAction { [weak self, weak button] _ in
        guard let self, let button else { return }
        self.delegate?.serveViewController(self, didCopy: text())
        button.configuration?.title = LocalizedString.forKey("copied")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak button] in
          button?.configuration?.title = LocalizedString.forKey("copy")
        }
      }, for: .touchUpInside)
    return button
  }
}
