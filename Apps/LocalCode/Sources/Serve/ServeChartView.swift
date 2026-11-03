import Charts
import Localization
import Style
import SwiftUI

/// One color per thing on every chart of the page, so prefill looks the same wherever it shows up.
/// Waiting is gray as nothing is being computed. The same orange and blue tell prefill and decode
/// apart on the Model Speed page.
enum ServeChartColor {
  static let waiting = UIColor.senaryText.withAlphaComponent(0.55)
  static let prefill = UIColor.shadePalette(for: .orange)
  static let generation = UIColor.shadePalette(for: .blue)
  static let cache = UIColor.shadePalette(for: .aqua)
  static let memory = UIColor.shadePalette(for: .lavender)
}

private struct ServeChartAxisLabel: View {
  let text: String

  var body: some View {
    let fontScale = FontMetrics.default.size.rawValue
    // A fixed width lines up the plots of charts with different ranges.
    Text(text)
      .font(.system(size: 11 * fontScale).monospacedDigit())
      .foregroundColor(Color(uiColor: .senaryText))
      .frame(minWidth: 52 * fontScale, alignment: .trailing)
  }
}

/// One value over the last few minutes.
struct ServeTimeChartView: View {
  struct Point: Identifiable, Equatable {
    /// Negative, with the latest at 0.
    let secondsAgo: Double
    let value: Double
    var id: Double { secondsAgo }
  }

  let color: UIColor
  let points: [Point]
  /// The top of the scale while the values are all smaller.
  let minimumScale: Double
  /// Drawn across the plot, as what the caption describes.
  var rule: Double? = nil
  var caption: String? = nil
  let format: (Double) -> String
  var axisFormat: ((Double) -> String)? = nil
  @State private var selected: Point?

  var body: some View {
    let fontScale = FontMetrics.default.size.rawValue
    let accent = Color(uiColor: color)
    let highlighted = selected ?? points.last
    let maximum = max((points.map(\.value).max() ?? 0) * 1.2, minimumScale)
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        Text(highlighted.map { format($0.value) } ?? "–")
          .font(.system(size: 20 * fontScale, weight: .medium).monospacedDigit())
          .foregroundColor(Color(uiColor: .primaryText))
        Spacer(minLength: 8)
        if let selected {
          Text(Self.label(forSecondsAgo: selected.secondsAgo))
            .font(.system(size: 12 * fontScale).monospacedDigit())
            .foregroundColor(Color(uiColor: .senaryText))
        } else if let caption {
          Text(caption)
            .font(.system(size: 12 * fontScale).monospacedDigit())
            .foregroundColor(Color(uiColor: .senaryText))
        }
      }
      Chart {
        if let rule {
          RuleMark(y: .value("Average", rule))
            .foregroundStyle(Color(uiColor: .senaryText))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        ForEach(points) { point in
          AreaMark(x: .value("Time", point.secondsAgo), y: .value("Value", point.value))
            .foregroundStyle(accent.opacity(0.1))
          LineMark(x: .value("Time", point.secondsAgo), y: .value("Value", point.value))
            .foregroundStyle(accent)
            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        if let selected {
          RuleMark(x: .value("Time", selected.secondsAgo))
            .foregroundStyle(Color(uiColor: .primaryBorder))
          PointMark(x: .value("Time", selected.secondsAgo), y: .value("Value", selected.value))
            .symbol {
              Circle().fill(accent).frame(width: 8, height: 8).padding(2).background(
                Circle().fill(Color(uiColor: .novemdecenaryBackground)))
            }
        }
      }
      .chartXScale(domain: -ServeMetrics.sampleWindow...0)
      .chartYScale(domain: 0...maximum)
      // Room for the label of the top mark under what's above the chart.
      .padding(.top, 4)
      .chartXAxis {
        AxisMarks(values: Array(stride(from: -ServeMetrics.sampleWindow, through: 0, by: 60))) {
          value in
          // The ends stay inside the plot, or Charts leaves the labels out.
          let seconds = value.as(Double.self) ?? 0
          AxisValueLabel(
            anchor: seconds == 0
              ? .topTrailing : (seconds == -ServeMetrics.sampleWindow ? .topLeading : .top)
          ) {
            Text(Self.label(forSecondsAgo: seconds))
              .font(.system(size: 11 * fontScale))
              .foregroundColor(Color(uiColor: .senaryText))
          }
        }
      }
      .chartYAxis {
        AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
          AxisGridLine(stroke: StrokeStyle(lineWidth: 1))
            .foregroundStyle(Color(uiColor: .primaryBorder))
          AxisValueLabel {
            if let number = value.as(Double.self) {
              ServeChartAxisLabel(text: (axisFormat ?? format)(number))
            }
          }
        }
      }
      .chartOverlay { proxy in
        GeometryReader { geometry in
          Rectangle().fill(.clear).contentShape(Rectangle())
            .onContinuousHover { phase in
              switch phase {
              case .active(let location):
                let x = location.x - geometry[proxy.plotAreaFrame].origin.x
                guard let secondsAgo = proxy.value(atX: x, as: Double.self) else { return }
                selected = points.min {
                  abs($0.secondsAgo - secondsAgo) < abs($1.secondsAgo - secondsAgo)
                }
              case .ended:
                selected = nil
              }
            }
        }
      }
    }
    // The chart scrolls with the page, which should not inset it as it passes the safe area.
    .ignoresSafeArea()
  }

  private static func label(forSecondsAgo secondsAgo: Double) -> String {
    guard secondsAgo < -0.5 else { return LocalizedString.forKey("now") }
    let seconds = Int(-secondsAgo)
    if seconds % 60 == 0 {
      return Measurement(value: Double(seconds / 60), unit: UnitDuration.minutes).formatted(
        .measurement(width: .narrow))
    }
    return Measurement(value: Double(seconds), unit: UnitDuration.seconds).formatted(
      .measurement(width: .narrow))
  }
}

/// Bars for the recent requests, one on top of another where a request has several parts. The legend
/// above reads out the latest request, or the one under the pointer.
struct ServeRequestChartView: View {
  struct Series: Identifiable {
    let title: String
    let color: UIColor
    var id: String { title }
  }

  struct Bar: Identifiable, Equatable {
    /// The request's id.
    let id: Int
    /// Follows `series`.
    let values: [Double]
  }

  let series: [Series]
  let bars: [Bar]
  let minimumScale: Double
  var rule: Double? = nil
  var caption: String? = nil
  let format: (Double) -> String
  var axisFormat: ((Double) -> String)? = nil
  @State private var selectedId: Int?

  var body: some View {
    let fontScale = FontMetrics.default.size.rawValue
    let selected = bars.first { $0.id == selectedId }
    let highlighted = selected ?? bars.last
    let maximum = max((bars.map { $0.values.reduce(0, +) }.max() ?? 0) * 1.1, minimumScale)
    // A surface-colored gap between the parts of a bar, about 2pt on a chart this tall.
    let gap = maximum * 0.015
    let slots = Self.slots(for: bars)
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 12) {
        ForEach(Array(series.enumerated()), id: \.element.id) { index, series in
          HStack(alignment: .firstTextBaseline, spacing: 4) {
            Circle().fill(Color(uiColor: series.color)).frame(
              width: 8 * fontScale, height: 8 * fontScale)
            Text(series.title)
              .foregroundColor(Color(uiColor: .senaryText))
              .lineLimit(1)
            Text(highlighted.map { format($0.values[index]) } ?? "–")
              .foregroundColor(Color(uiColor: .primaryText))
              .lineLimit(1)
          }
        }
        Spacer(minLength: 0)
        if let highlighted, selected != nil || caption == nil {
          Text("#\(highlighted.id)")
            .foregroundColor(Color(uiColor: .senaryText))
        } else if let caption {
          Text(caption)
            .foregroundColor(Color(uiColor: .senaryText))
            .lineLimit(1)
        }
      }
      .font(.system(size: 12 * fontScale).monospacedDigit())
      Chart {
        if let rule {
          RuleMark(y: .value("Average", rule))
            .foregroundStyle(Color(uiColor: .senaryText))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        if let selected {
          RuleMark(x: .value("Request", String(selected.id)))
            .foregroundStyle(Color(uiColor: .primaryBorder))
        }
        ForEach(bars) { bar in
          ForEach(Self.segments(of: bar, gap: gap)) { segment in
            BarMark(
              x: .value("Request", String(bar.id)),
              yStart: .value("From", segment.start),
              yEnd: .value("To", segment.end), width: .ratio(0.7)
            )
            .foregroundStyle(Color(uiColor: series[segment.id].color))
            .cornerRadius(2)
          }
        }
      }
      .chartXScale(domain: slots)
      .chartYScale(domain: 0...maximum)
      // Room for the label of the top mark under what's above the chart.
      .padding(.top, 4)
      .chartXAxis {
        AxisMarks(values: slots.enumerated().filter { $0.offset % 5 == 0 }.map(\.element)) {
          value in
          AxisValueLabel {
            if let label = value.as(String.self) {
              Text(label)
                .font(.system(size: 11 * fontScale).monospacedDigit())
                .foregroundColor(Color(uiColor: .senaryText))
            }
          }
        }
      }
      .chartYAxis {
        AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
          AxisGridLine(stroke: StrokeStyle(lineWidth: 1))
            .foregroundStyle(Color(uiColor: .primaryBorder))
          AxisValueLabel {
            if let number = value.as(Double.self) {
              ServeChartAxisLabel(text: (axisFormat ?? format)(number))
            }
          }
        }
      }
      .chartOverlay { proxy in
        GeometryReader { geometry in
          Rectangle().fill(.clear).contentShape(Rectangle())
            .onContinuousHover { phase in
              switch phase {
              case .active(let location):
                let x = location.x - geometry[proxy.plotAreaFrame].origin.x
                selectedId = proxy.value(atX: x, as: String.self).flatMap(Int.init)
              case .ended:
                selectedId = nil
              }
            }
        }
      }
      .overlay {
        if bars.isEmpty {
          Text(LocalizedString.forKey("no_requests_yet"))
            .font(.system(size: 12 * fontScale))
            .foregroundColor(Color(uiColor: .senaryText))
        }
      }
    }
    .ignoresSafeArea()
  }

  /// Leaves room for the requests to come, so that bars keep their width. Charts also traps on an
  /// empty category axis.
  private static func slots(for bars: [Bar]) -> [String] {
    let first = bars.first?.id ?? 1
    return (first..<(first + ServeMetrics.requestWindow)).map(String.init)
  }

  private struct Segment: Identifiable {
    /// The index of its series.
    let id: Int
    let start: Double
    let end: Double
  }

  private static func segments(of bar: Bar, gap: Double) -> [Segment] {
    var segments = [Segment]()
    var top = 0.0
    for (index, value) in bar.values.enumerated() where value > 0 {
      // A part too short for the gap still shows.
      let start = segments.isEmpty ? top : min(top + gap, top + value / 2)
      segments.append(Segment(id: index, start: start, end: top + value))
      top += value
    }
    return segments
  }
}

/// The latest requests, for the numbers behind the bars.
struct ServeRequestsTableView: View {
  static let rowCount = 8

  /// Oldest first, as they are in the metrics.
  let requests: [ServeMetrics.Request]
  /// Fewer columns where the page is too narrow for all of them.
  let showsAllColumns: Bool

  var body: some View {
    let fontScale = FontMetrics.default.size.rawValue
    if requests.isEmpty {
      Text(LocalizedString.forKey("no_requests_yet"))
        .font(.system(size: 13 * fontScale, weight: .light))
        .foregroundColor(Color(uiColor: .senaryText))
        .frame(maxWidth: .infinity, alignment: .leading)
    } else {
      grid(of: showsAllColumns ? Self.columns : Self.columns.filter(\.isEssential))
        .font(.system(size: 12 * fontScale).monospacedDigit())
        .ignoresSafeArea()
    }
  }

  private func grid(of columns: [Column]) -> some View {
    Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 8) {
      GridRow {
        ForEach(columns) { column in
          cell(column.title).foregroundColor(Color(uiColor: .senaryText))
        }
      }
      ForEach(requests.suffix(Self.rowCount).reversed()) { request in
        GridRow {
          ForEach(columns) { column in
            cell(column.value(request)).foregroundColor(Color(uiColor: .primaryText))
          }
        }
      }
    }
  }

  /// As wide as its text, with any room left shared among the columns.
  private func cell(_ text: String) -> some View {
    Text(text)
      .lineLimit(1)
      .fixedSize(horizontal: true, vertical: false)
      .frame(maxWidth: .infinity, alignment: .trailing)
  }

  private struct Column: Identifiable {
    let title: String
    var isEssential = true
    let value: (ServeMetrics.Request) -> String
    var id: String { title }
  }

  private static let columns = [
    Column(title: "#") { "#\($0.id)" },
    Column(title: LocalizedString.forKey("time"), isEssential: false) {
      $0.date.formatted(date: .omitted, time: .shortened)
    },
    Column(title: LocalizedString.forKey("status"), isEssential: false) {
      statusTitle(of: $0.status)
    },
    Column(title: LocalizedString.forKey("in")) { count($0.inputTokens) },
    Column(title: LocalizedString.forKey("cached"), isEssential: false) {
      count($0.cachedInputTokens)
    },
    Column(title: LocalizedString.forKey("out")) { count($0.outputTokens) },
    Column(title: LocalizedString.forKey("first_token")) {
      $0.timing.timeToFirstToken.map(ServeChartFormat.seconds) ?? "–"
    },
    Column(title: LocalizedString.forKey("prompt")) {
      ServeChartFormat.optionalSpeed($0.prefillTokensPerSecond)
    },
    Column(title: LocalizedString.forKey("generation")) {
      ServeChartFormat.optionalSpeed($0.generationTokensPerSecond)
    },
  ]

  private static func statusTitle(of status: String) -> String {
    switch status {
    case "completed": return LocalizedString.forKey("completed")
    case "incomplete": return LocalizedString.forKey("incomplete")
    case "failed": return LocalizedString.forKey("failed")
    default: return LocalizedString.forKey("cancelled")
    }
  }

  private static func count(_ value: Int) -> String {
    value.formatted(.number)
  }
}

/// The units the page's numbers read in.
enum ServeChartFormat {
  static func speed(_ tokensPerSecond: Double) -> String {
    let fractionLength = tokensPerSecond < 100 ? 1 : 0
    return
      "\(tokensPerSecond.formatted(.number.precision(.fractionLength(fractionLength)))) tok/s"
  }

  static func optionalSpeed(_ tokensPerSecond: Double) -> String {
    tokensPerSecond > 0 ? speed(tokensPerSecond) : "–"
  }

  static func seconds(_ seconds: Double) -> String {
    "\(seconds.formatted(.number.precision(.fractionLength(seconds < 10 ? 1 : 0)))) s"
  }

  static func compactCount(_ count: Double) -> String {
    count.formatted(.number.notation(.compactName))
  }

  static func gigabytes(_ gigabytes: Double) -> String {
    guard gigabytes >= 1 else {
      return "\(Int(gigabytes * 1_024)) MB"
    }
    return "\(gigabytes.formatted(.number.precision(.fractionLength(1)))) GB"
  }

  static func axisSpeed(_ tokensPerSecond: Double) -> String {
    "\(axisNumber(tokensPerSecond)) tok/s"
  }

  static func axisSeconds(_ seconds: Double) -> String {
    "\(axisNumber(seconds)) s"
  }

  static func axisGigabytes(_ gigabytes: Double) -> String {
    "\(axisNumber(gigabytes)) GB"
  }

  private static func axisNumber(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(0...1)))
  }
}
