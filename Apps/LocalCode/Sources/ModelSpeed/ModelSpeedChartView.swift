import Charts
import Style
import SwiftUI

/// Plots tokens per second against the context length each measurement ran at.
struct ModelSpeedChartView: View {
  struct Point: Identifiable, Equatable {
    let contextLength: Int
    let tokensPerSecond: Double
    var id: Int { contextLength }
  }

  /// Sets the prefill and decode charts apart, which otherwise share a page and a layout.
  let palette: UIColor.ColorPalette
  /// Every context length the run covers, so the axis is laid out before results arrive.
  let contextLengths: [Int]
  let points: [Point]
  @State private var selectedContextLength: Int?

  init(palette: UIColor.ColorPalette, contextLengths: [Int], points: [Point]) {
    self.palette = palette
    self.contextLengths = contextLengths
    self.points = points
  }

  static func label(for contextLength: Int) -> String {
    contextLength == 0 ? "0" : "\(contextLength / 1_024)K"
  }

  var body: some View {
    let fontScale = FontMetrics.default.size.rawValue
    let accent = Color(uiColor: .shadePalette(for: palette))
    let surface = Color(uiColor: .novemdecenaryBackground)
    let grid = Color(uiColor: .primaryBorder)
    let axisText = Color(uiColor: .senaryText)
    let selected = points.first { $0.contextLength == selectedContextLength }
    // The selected point is labeled, or the latest one while nothing is selected.
    let highlighted = selected ?? points.last
    // Headroom above the fastest point keeps its label inside the chart.
    let maximum = max((points.map(\.tokensPerSecond).max() ?? 0) * 1.25, 1)
    Chart {
      if let selected {
        RuleMark(x: .value("Context", Self.label(for: selected.contextLength)))
          .foregroundStyle(grid)
          .lineStyle(StrokeStyle(lineWidth: 1))
      }
      ForEach(points) { point in
        AreaMark(
          x: .value("Context", Self.label(for: point.contextLength)),
          y: .value("Speed", point.tokensPerSecond)
        )
        .foregroundStyle(accent.opacity(0.1))
        LineMark(
          x: .value("Context", Self.label(for: point.contextLength)),
          y: .value("Speed", point.tokensPerSecond)
        )
        .foregroundStyle(accent)
        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        PointMark(
          x: .value("Context", Self.label(for: point.contextLength)),
          y: .value("Speed", point.tokensPerSecond)
        )
        .symbol {
          Circle().fill(accent).frame(width: 8, height: 8).padding(2).background(
            Circle().fill(surface))
        }
      }
      if let highlighted {
        PointMark(
          x: .value("Context", Self.label(for: highlighted.contextLength)),
          y: .value("Speed", highlighted.tokensPerSecond)
        )
        .symbol {
          Circle().fill(accent).frame(width: 10, height: 10).padding(2).background(
            Circle().fill(surface))
        }
        .annotation(position: .top, alignment: annotationAlignment(for: highlighted), spacing: 6) {
          // The surface behind the label keeps it legible where the line runs under it.
          Text(
            "\(highlighted.tokensPerSecond.formatted(.number.precision(.fractionLength(1)))) tok/s"
          )
          .font(.system(size: 12 * fontScale, weight: .semibold).monospacedDigit())
          .foregroundColor(Color(uiColor: .secondaryText))
          .padding(.horizontal, 4)
          .padding(.vertical, 2)
          .background(RoundedRectangle(cornerRadius: 4).fill(surface))
        }
      }
    }
    // Charts traps on an empty category axis, as when the model can't run here.
    .chartXScale(domain: (contextLengths.isEmpty ? [0] : contextLengths).map(Self.label(for:)))
    .chartYScale(domain: 0...maximum)
    .chartXAxis {
      AxisMarks { _ in
        AxisValueLabel()
          .font(.system(size: 11 * fontScale))
          .foregroundStyle(axisText)
      }
    }
    .chartYAxis {
      AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
        AxisGridLine(stroke: StrokeStyle(lineWidth: 1))
          .foregroundStyle(grid)
        AxisValueLabel {
          // A fixed width lines up the plots of charts with different ranges.
          if let speed = value.as(Double.self) {
            Text(speed.formatted(.number.notation(.compactName)))
              .font(.system(size: 11 * fontScale).monospacedDigit())
              .foregroundColor(axisText)
              .frame(minWidth: 28 * fontScale, alignment: .trailing)
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
              select(at: location, proxy: proxy, geometry: geometry)
            case .ended:
              selectedContextLength = nil
            }
          }
          .gesture(
            SpatialTapGesture().onEnded { value in
              select(at: value.location, proxy: proxy, geometry: geometry)
            })
      }
    }
    .animation(.easeOut(duration: 0.3), value: points)
    // The chart scrolls with the page, which should not inset it as it passes the safe area.
    .ignoresSafeArea()
  }

  private func select(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
    let x = location.x - geometry[proxy.plotAreaFrame].origin.x
    let label: String? = proxy.value(atX: x)
    selectedContextLength =
      points.first { Self.label(for: $0.contextLength) == label }?
      .contextLength
  }

  /// Labels at either end of the axis grow inward so they stay inside the chart.
  private func annotationAlignment(for point: Point) -> Alignment {
    switch contextLengths.firstIndex(of: point.contextLength) {
    case 0:
      return .leading
    case contextLengths.count - 1:
      return .trailing
    default:
      return .center
    }
  }
}
