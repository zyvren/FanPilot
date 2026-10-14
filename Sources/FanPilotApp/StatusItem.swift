import AppKit
import FanPilotKit
import FanPilotSensors
import SwiftUI

// The menu bar item: what it says (`StatusBarContent`), how it is drawn (`StatusItemRenderer`) and
// how to reach the NSStatusItem button SwiftUI created for it (`StatusItemLocator`).

/// One piece of text on a line of the menu bar item.
struct StatusSegment: Equatable {
    var text: String
    /// Orange or red when a temperature crosses the warning or critical threshold.
    var zone: TemperatureZone = .normal
    /// The "fans are overridden" diamond; red when `useColorForOverrideSymbol` is on.
    var isOverrideSymbol = false
    var overrideColored = false
    /// Worst-case texts this slot can ever show ("888°C", "8888 RPM" / "Fans Off"). The item reserves
    /// the widest, so a value that grows a digit or a fan that stops does not resize the item and
    /// push its neighbours around. Empty for separators and the override diamond (fixed text).
    var reserve: [String] = []
}

/// Everything the menu bar item shows, before drawing.
struct StatusBarContent: Equatable {
    var lines: [[StatusSegment]]
    var tooltip: String
    var showIcon: Bool
    var isVertical: Bool
    var smallerFont: Bool

    var needsColor: Bool {
        lines.joined().contains { $0.zone != .normal || ($0.isOverrideSymbol && $0.overrideColored) }
    }

    /// Builds the item for the current data.
    ///
    /// - Parameters:
    ///   - snapshot: nil before the first poll; the item then shows only the icon.
    ///   - fansMayStop: true on Macs whose fans legitimately stop (every Apple Silicon Mac), which
    ///     turns "0 RPM" into "Fans Off".
    ///   - overriding: any fan is currently driven by FanPilot.
    static func make(snapshot: SensorSnapshot?, settings: AppSettings, fansMayStop: Bool,
                     overriding: Bool) -> StatusBarContent {
        let bar = settings.menuBar
        let unit = settings.tempUnit
        let alerts = settings.alerts
        let shorter = bar.useShorterTitles
        let separator = " "

        var tempSegments: [StatusSegment] = []
        var tooltipLines: [String] = []

        func temperatureSegment(_ slot: MenuBarTempSlot) -> StatusSegment? {
            guard slot.enabled else { return nil }
            let value = snapshot?.value(for: slot.source)
            let zone: TemperatureZone = (bar.useColors && value != nil)
                ? TemperatureZone(celsius: value!, alerts: alerts) : .normal
            if let snapshot {
                var line = "\(slot.source.displayName(in: snapshot)): \(unit.format(celsius: value))"
                if slot.source == .highest, let id = snapshot.aggregates.highestSensorID,
                   let name = snapshot.reading(id: id)?.sensor.name { line += " (\(name))" }
                if slot.source == .highestCPU, let id = snapshot.aggregates.highestCPUSensorID,
                   let name = snapshot.reading(id: id)?.sensor.name { line += " (\(name))" }
                tooltipLines.append(line)
            }
            return StatusSegment(text: unit.format(celsius: value, includeUnit: !shorter), zone: zone,
                                 reserve: [shorter ? "888" : "888" + unit.symbol])
        }
        if let s = temperatureSegment(bar.temp1) { tempSegments.append(s) }
        if let s = temperatureSegment(bar.temp2) { tempSegments.append(s) }

        var fanSegment: StatusSegment?
        let hasFans = !(snapshot?.fans.isEmpty ?? true)
        if bar.fan.enabled, snapshot == nil || hasFans || !(snapshot?.fanInfos.isEmpty ?? true) {
            fanSegment = StatusSegment(text: Self.fanText(snapshot: snapshot, source: bar.fan.source,
                                                          shorter: shorter, mayStop: fansMayStop),
                                       reserve: shorter ? ["8888", "Off"] : ["8888 RPM", "Fans Off"])
            if let snapshot, snapshot.fans.isEmpty == false {
                tooltipLines.append("Fan: \(fanSegment!.text)")
            }
        }
        if overriding { tooltipLines.append("FanPilot is controlling the fans") }

        // Lay out.
        var lines: [[StatusSegment]] = []
        let vertical = bar.stackOrder == .vertical
        if vertical {
            switch (tempSegments.count, fanSegment) {
            case (0, nil): break
            case (0, let fan?): lines = [[fan]]
            case (_, let fan?): lines = [tempSegments, [fan]]
            case (1, nil): lines = [tempSegments]
            default: lines = tempSegments.map { [$0] }
            }
        } else {
            var all = tempSegments
            if let fanSegment { all.append(fanSegment) }
            lines = all.isEmpty ? [] : [all]
        }
        // Join slots on one line with a separator segment.
        lines = lines.map { line in
            line.enumerated().flatMap { index, segment in
                index == 0 ? [segment] : [StatusSegment(text: separator), segment]
            }
        }
        if overriding, !lines.isEmpty {
            let last = lines.count - 1
            lines[last].append(StatusSegment(text: lines[last].isEmpty ? "" : " "))
            lines[last].append(StatusSegment(text: "\u{25C6}", isOverrideSymbol: true, overrideColored: bar.useColorForOverrideSymbol))
        }

        return StatusBarContent(lines: lines, tooltip: tooltipLines.joined(separator: "\n"),
                                showIcon: bar.showAppIcon, isVertical: vertical && lines.count > 1,
                                smallerFont: bar.useSmallerFont)
    }

    private static func fanText(snapshot: SensorSnapshot?, source: MenuBarFanSource, shorter: Bool, mayStop: Bool) -> String {
        guard let snapshot, !snapshot.fans.isEmpty else { return "Invalid Fan" }
        let rpm: Double
        let several: Bool
        switch source {
        case .average:
            rpm = snapshot.averageFanRPM ?? 0
            several = snapshot.fans.count > 1
        case .fan(let index):
            guard let reading = snapshot.fans.first(where: { $0.index == index }) else { return "Invalid Fan" }
            rpm = reading.actualRPM
            several = false
        }
        if rpm < 1, mayStop { return shorter ? "Off" : (several ? "Fans Off" : "Fan Off") }
        return shorter ? String(format: "%.0f", rpm) : String(format: "%.0f RPM", rpm)
    }
}

// MARK: - Drawing

enum StatusItemRenderer {
    /// Draws the item. A template image (single color, tinted by the system for light, dark and
    /// wallpaper-dependent menu bars) is used whenever no segment needs a color; otherwise the image
    /// carries real colors and the plain text color is chosen to suit `menuBarIsDark`.
    static func image(for content: StatusBarContent, menuBarIsDark: Bool) -> NSImage {
        let thickness = max(NSStatusBar.system.thickness, 22)
        let template = !content.needsColor

        let lineFont: NSFont
        let multiline = content.lines.count > 1
        if multiline {
            lineFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        } else {
            lineFont = NSFont.monospacedDigitSystemFont(ofSize: content.smallerFont ? 12 : 13, weight: .regular)
        }

        let normal: NSColor = template ? .black : (menuBarIsDark ? NSColor.white.withAlphaComponent(0.92)
                                                                  : NSColor.black.withAlphaComponent(0.88))

        func attributed(_ line: [StatusSegment]) -> NSAttributedString {
            let result = NSMutableAttributedString()
            for segment in line {
                var color = normal
                if !template {
                    if segment.isOverrideSymbol, segment.overrideColored { color = .systemRed }
                    else if let zoneColor = segment.zone.nsTextColor { color = zoneColor }
                }
                result.append(NSAttributedString(string: segment.text, attributes: [.font: lineFont, .foregroundColor: color]))
            }
            return result
        }
        let rendered = content.lines.map(attributed)

        // Reserve the width of the worst case for every slot (not of the current text, which would
        // always equal the rendered width) so the item does not change size when a value changes.
        func width(of text: String) -> CGFloat {
            ceil(NSAttributedString(string: text, attributes: [.font: lineFont]).size().width)
        }
        let reserved = content.lines.map { line in
            line.reduce(CGFloat(0)) { total, segment in
                total + (segment.reserve.map(width(of:)).max() ?? width(of: segment.text))
            }
        }
        let textWidth = max(rendered.map { ceil($0.size().width) }.max() ?? 0, reserved.max() ?? 0)

        let iconWidth: CGFloat = content.showIcon ? 16 : 0
        let gap: CGFloat = content.showIcon && textWidth > 0 ? 4 : 0
        let width = max(iconWidth + gap + textWidth + 2, 1)
        let size = NSSize(width: width, height: thickness)

        let image = NSImage(size: size, flipped: false) { rect in
            if content.showIcon, let symbol = NSImage(systemSymbolName: "thermometer.medium", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .regular)) {
                let tinted = NSImage(size: symbol.size, flipped: false) { r in
                    symbol.draw(in: r)
                    normal.set()
                    r.fill(using: .sourceAtop)
                    return true
                }
                let y = (rect.height - tinted.size.height) / 2
                tinted.draw(in: NSRect(x: 0, y: y, width: tinted.size.width, height: tinted.size.height))
            }
            let heights = rendered.map { $0.size().height }
            let total = heights.reduce(0, +)
            var y = rect.height - (rect.height - total) / 2
            for (line, height) in zip(rendered, heights) {
                y -= height
                let lineWidth = line.size().width
                let available = textWidth
                // Centered within the text column; the placeholder width keeps the column stable.
                let x = iconWidth + gap + (available - lineWidth) / 2 + 1
                line.draw(at: NSPoint(x: x, y: y))
            }
            return true
        }
        image.isTemplate = template
        return image
    }

}

// MARK: - The status item SwiftUI created

/// MenuBarExtra owns its NSStatusItem, but a few things (tooltip, appearance, programmatic click)
/// need the button. It lives in an `NSStatusBarWindow` of this process.
@MainActor
enum StatusItemLocator {
    static func button() -> NSStatusBarButton? {
        for window in NSApp.windows where String(describing: type(of: window)).contains("StatusBarWindow") {
            if let button = find(in: window.contentView) { return button }
        }
        return nil
    }

    private static func find(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for sub in view.subviews {
            if let found = find(in: sub) { return found }
        }
        return nil
    }

    /// True when the menu bar is currently drawn with light text.
    static func menuBarIsDark() -> Bool {
        let appearance = button()?.effectiveAppearance ?? NSApp.effectiveAppearance
        return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// Whether the status item has room in the menu bar. When macOS cannot fit an item (the notch, too
    /// many items) it moves the item's window off every screen, so the check is "is the window on any
    /// screen at all". Nil when the item cannot be found yet.
    static func isVisibleOnScreen() -> Bool? {
        guard let window = button()?.window else { return nil }
        guard window.isVisible else { return false }
        return NSScreen.screens.contains { $0.frame.intersects(window.frame) }
    }

    static func setToolTip(_ text: String) {
        button()?.toolTip = text.isEmpty ? nil : text
    }
}
