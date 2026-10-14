import FanPilotControl
import FanPilotKit
import FanPilotSensors
import SwiftUI

/// Editor for Curve mode (SPEC 5.4): fan speed (percent of the fan's range) against one temperature.
/// Points can be dragged in the plot or typed in the list below it.
struct CurveEditorView: View {
    @EnvironmentObject var model: AppModel

    private let tempRange: ClosedRange<Double> = 30...110
    private let maxPoints = 12

    var body: some View {
        let curve = model.settings.policy.curve
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("Follow")
                SensorSelectorPicker(selection: Binding(get: { curve.source },
                                                        set: { v in model.updateCurve { $0.source = v } }))
                    .frame(width: 220)
                Spacer()
                if let live = liveStatus {
                    Text(live).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                }
            }

            CurvePlot(points: curve.points, tempRange: tempRange,
                      liveTemp: model.snapshot.value(for: curve.source),
                      livePercent: model.lastOutput?.curvePercent,
                      unit: model.temperatureUnit,
                      onMove: { index, temp, percent in
                          model.updateCurve { c in
                              guard c.points.indices.contains(index) else { return }
                              c.points[index] = CurvePoint(tempC: temp, percent: percent)
                          }
                      },
                      onDragEnd: { sortPoints() })
                .frame(height: 230)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(curve.points.enumerated()), id: \.offset) { index, point in
                    HStack(spacing: 8) {
                        Text("Point \(index + 1)").foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
                        Text("at")
                        TextField("", value: Binding(
                            get: { model.temperatureUnit.convert(fromCelsius: point.tempC) },
                            set: { v in setPoint(index) { $0.tempC = min(max(model.temperatureUnit.toCelsius(v), 0), 130) } }),
                                  format: .number.precision(.fractionLength(0)), prompt: Text("temp"))
                            .multilineTextAlignment(.trailing).frame(width: 52)
                            .onSubmit { sortPoints() }
                        Text(model.temperatureUnit.symbol)
                        Text("fans at")
                        TextField("", value: Binding(
                            get: { point.percent },
                            set: { v in setPoint(index) { $0.percent = min(max(v, 0), 100) } }),
                                  format: .number.precision(.fractionLength(0)), prompt: Text("%"))
                            .multilineTextAlignment(.trailing).frame(width: 44)
                        Text("%")
                        Spacer()
                        Button { removePoint(index) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .disabled(curve.points.count <= 2).help("Remove this point")
                    }
                    .font(.system(size: 12))
                }
                HStack {
                    Button { addPoint() } label: { Label("Add Point", systemImage: "plus") }
                        .disabled(curve.points.count >= maxPoints)
                    Button("Restore Defaults") { model.updateCurve { $0.points = CurveSettings.defaultPoints } }
                }
                .padding(.top, 4)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text("Smoothing").frame(width: 190, alignment: .leading)
                    Slider(value: Binding(get: { curve.emaAlpha }, set: { v in model.updateCurve { $0.emaAlpha = v } }), in: 0.05...1)
                        .frame(maxWidth: 260)
                    Text(curve.emaAlpha >= 0.95 ? "off" : String(format: "%.2f", curve.emaAlpha)).monospacedDigit().frame(width: 44, alignment: .leading)
                }
                .help("Low values ignore short spikes. The curve follows a moving average of the temperature.")
                HStack {
                    Text("Slow down only after a drop of").frame(width: 190, alignment: .leading)
                    let unit = model.temperatureUnit
                    Stepper(value: Binding(get: { unit.delta(fromCelsius: curve.fallHysteresisC) },
                                           set: { v in model.updateCurve { $0.fallHysteresisC = unit.deltaToCelsius(v) } }),
                            in: 0...unit.delta(fromCelsius: 20), step: 1) {
                        Text(unit.formatDelta(celsius: curve.fallHysteresisC)).monospacedDigit()
                    }
                }
                .help("The fans speed up at once, but slow down only when the temperature has fallen this far below the point that set the current speed.")
            }
            .font(.system(size: 12))
        }
    }

    private var liveStatus: String? {
        guard model.controlMode == .curve || model.lastOutput?.curvePercent != nil else {
            return "Choose Curve in the Fans section to use it."
        }
        guard let percent = model.lastOutput?.curvePercent else { return nil }
        return "Curve asks for \(Int(percent.rounded()))%"
    }

    private func setPoint(_ index: Int, _ change: (inout CurvePoint) -> Void) {
        model.updateCurve { curve in
            guard curve.points.indices.contains(index) else { return }
            change(&curve.points[index])
        }
    }

    private func sortPoints() {
        model.updateCurve { $0.points = $0.sortedPoints }
    }

    private func addPoint() {
        model.updateCurve { curve in
            let sorted = curve.sortedPoints
            let hottest = sorted.last?.tempC ?? 60
            let temp = min(hottest + 5, tempRange.upperBound)
            curve.points = (sorted + [CurvePoint(tempC: temp, percent: min(100, (sorted.last?.percent ?? 50) + 10))]).sorted { $0.tempC < $1.tempC }
        }
    }

    private func removePoint(_ index: Int) {
        model.updateCurve { curve in
            guard curve.points.count > 2, curve.points.indices.contains(index) else { return }
            curve.points.remove(at: index)
        }
    }
}

struct CurvePlot: View {
    var points: [CurvePoint]
    var tempRange: ClosedRange<Double>
    var liveTemp: Double?
    var livePercent: Double?
    var unit: TemperatureUnit
    var onMove: (Int, Double, Double) -> Void
    var onDragEnd: () -> Void

    private let inset = EdgeInsets(top: 10, leading: 38, bottom: 26, trailing: 14)

    var body: some View {
        GeometryReader { geo in
            let plot = CGRect(x: inset.leading, y: inset.top,
                              width: max(geo.size.width - inset.leading - inset.trailing, 1),
                              height: max(geo.size.height - inset.top - inset.bottom, 1))
            let sorted = points.sorted { $0.tempC < $1.tempC }
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    drawGrid(context: &context, plot: plot)
                    // Curve: flat before the first and after the last point.
                    var line = Path()
                    if let first = sorted.first {
                        line.move(to: CGPoint(x: plot.minX, y: y(first.percent, plot)))
                        for p in sorted { line.addLine(to: CGPoint(x: x(p.tempC, plot), y: y(p.percent, plot))) }
                        if let last = sorted.last { line.addLine(to: CGPoint(x: plot.maxX, y: y(last.percent, plot))) }
                    }
                    context.stroke(line, with: .color(.accentColor), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
                    if let liveTemp {
                        var mark = Path()
                        let lx = x(liveTemp, plot)
                        mark.move(to: CGPoint(x: lx, y: plot.minY))
                        mark.addLine(to: CGPoint(x: lx, y: plot.maxY))
                        context.stroke(mark, with: .color(.orange), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        if let livePercent {
                            let dot = CGRect(x: lx - 4, y: y(livePercent, plot) - 4, width: 8, height: 8)
                            context.fill(Path(ellipseIn: dot), with: .color(.orange))
                        }
                    }
                }
                ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                    Circle()
                        .fill(Color.accentColor)
                        .overlay(Circle().strokeBorder(Color.white, lineWidth: 2))
                        .frame(width: 14, height: 14)
                        .contentShape(Circle().inset(by: -6))
                        .position(x: x(point.tempC, plot), y: y(point.percent, plot))
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("curve"))
                            .onChanged { drag in
                                let temp = tempRange.lowerBound + (drag.location.x - plot.minX) / plot.width
                                    * (tempRange.upperBound - tempRange.lowerBound)
                                let percent = (plot.maxY - drag.location.y) / plot.height * 100
                                onMove(index, min(max(temp.rounded(), tempRange.lowerBound), tempRange.upperBound),
                                       min(max(percent.rounded(), 0), 100))
                            }
                            .onEnded { _ in onDragEnd() })
                        .help("\(unit.format(celsius: point.tempC)), \(Int(point.percent))%")
                }
            }
            .coordinateSpace(name: "curve")
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
    }

    private func x(_ temp: Double, _ plot: CGRect) -> CGFloat {
        plot.minX + CGFloat((temp - tempRange.lowerBound) / (tempRange.upperBound - tempRange.lowerBound)) * plot.width
    }

    private func y(_ percent: Double, _ plot: CGRect) -> CGFloat {
        plot.maxY - CGFloat(percent / 100) * plot.height
    }

    private func drawGrid(context: inout GraphicsContext, plot: CGRect) {
        let grid = Color(nsColor: .separatorColor)
        for percent in stride(from: 0.0, through: 100.0, by: 25.0) {
            var line = Path()
            line.move(to: CGPoint(x: plot.minX, y: y(percent, plot)))
            line.addLine(to: CGPoint(x: plot.maxX, y: y(percent, plot)))
            context.stroke(line, with: .color(grid), lineWidth: 0.5)
            context.draw(Text("\(Int(percent))%").font(.system(size: 10)).foregroundColor(.secondary),
                         at: CGPoint(x: plot.minX - 6, y: y(percent, plot)), anchor: .trailing)
        }
        for temp in stride(from: tempRange.lowerBound, through: tempRange.upperBound, by: 10) {
            var line = Path()
            line.move(to: CGPoint(x: x(temp, plot), y: plot.minY))
            line.addLine(to: CGPoint(x: x(temp, plot), y: plot.maxY))
            context.stroke(line, with: .color(grid), lineWidth: 0.5)
            context.draw(Text(unit.format(celsius: temp)).font(.system(size: 10)).foregroundColor(.secondary),
                         at: CGPoint(x: x(temp, plot), y: plot.maxY + 4), anchor: .top)
        }
    }
}

struct CurvePage: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Fan curve").font(.system(size: 15, weight: .semibold))
                    Text("Sets the fan speed from one temperature. Drag the points, or type values below. Speeds are percent of each fan's own range.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                CurveEditorView()
            }
            .padding(20)
            .frame(maxWidth: 820, alignment: .leading)
        }
    }
}
