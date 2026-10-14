import FanPilotControl
import FanPilotKit
import FanPilotSensors
import SwiftUI

// Fan controls shared by the menu panel and the main window: the mode control, the link toggle,
// and the gauge with the overlaid target slider.

/// The mode control: System | Manual | Max | Boost | Curve.
///
/// FanPilot offers every mode directly; none is hidden behind a preference.
/// Segments are disabled while the helper cannot drive the fans, except System, which is always
/// available so a user can always get back to automatic control.
struct FanModeControl: View {
    @EnvironmentObject var model: AppModel
    var controlSize: ControlSize = .small

    var body: some View {
        Picker("Fan mode", selection: selection) {
            ForEach(ControlMode.allCases, id: \.self) { mode in
                Text(Fmt.segmentName(mode, usePercent: model.usePercent))
                    .tag(Optional(mode))
                    .disabled(mode != .auto && !model.canControlFans)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(controlSize)
        .help(model.canControlFans ? "Choose how the fans are controlled" : "Fan control needs the helper")
    }

    private var selection: Binding<ControlMode?> {
        Binding(get: { model.controlMode },
                set: { if let mode = $0 { model.setMode(mode) } })
    }
}

/// The "link fans" toggle: visible in Manual mode with more than one fan.
struct LinkFansToggle: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if model.fanCount > 1, model.controlMode == .manual {
            Toggle(isOn: Binding(get: { model.settings.policy.linkFans }, set: { model.setLinkFans($0) })) {
                Image(systemName: model.settings.policy.linkFans ? "link" : "link.badge.plus")
                    .frame(width: 16)
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help(model.settings.policy.linkFans ? "Fans move together. Click to move them separately."
                                                 : "Fans move separately. Click to link them.")
            .accessibilityLabel("Link fan speeds")
        }
    }
}

/// A knob that sits on top of a gauge. Dragging it sets the target; it draws no track of its own, so
/// the gauge underneath stays visible.
struct TargetKnob: View {
    var range: ClosedRange<Double>
    var value: Double
    var onChange: (Double) -> Void

    private let knob: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let travel = max(geo.size.width - knob, 1)
            let span = max(range.upperBound - range.lowerBound, 1)
            let fraction = min(max((value - range.lowerBound) / span, 0), 1)
            ZStack(alignment: .leading) {
                Color.clear
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.25), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                    .frame(width: knob, height: knob)
                    .offset(x: travel * fraction)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let f = min(max((drag.location.x - knob / 2) / travel, 0), 1)
                onChange(range.lowerBound + f * span)
            })
        }
        .accessibilityRepresentation {
            Slider(value: Binding(get: { value }, set: onChange), in: range, step: 1)
        }
    }
}

/// Level bar for the actual speed with the target slider on top (shown only in Manual mode) and a
/// tick for the target in the other modes.
struct FanGauge: View {
    @EnvironmentObject var model: AppModel
    var info: FanInfo
    var reading: FanReading?
    var showKnob: Bool
    var height: CGFloat = 22

    var body: some View {
        let limits = FanLimits(info)
        let target = model.directive(forFan: info.index)?.command.rpm
        ZStack {
            LevelBar.fan(actual: reading?.actualRPM, info: info,
                         target: showKnob ? nil : target, height: 8)
                .padding(.horizontal, 7)
            if showKnob, limits.isUsable {
                TargetKnob(range: info.minRPM...info.maxRPM,
                           value: model.manualTargetRPM(fan: info.index) ?? info.minRPM) { rpm in
                    model.setManualRPM(rpm, fan: info.index)
                }
            }
        }
        .frame(height: height)
        .help(tooltip)
    }

    private var tooltip: String {
        var parts = ["Actual: \(Fmt.rpm(reading?.actualRPM))"]
        if let target = model.directive(forFan: info.index)?.command.rpm { parts.append("Target: \(Fmt.rpm(target))") }
        parts.append("Range: \(Fmt.rpm(info.minRPM, includeUnit: false)) to \(Fmt.rpm(info.maxRPM))")
        return parts.joined(separator: "\n")
    }
}

/// Describes what the controller is doing with a fan, in a few words.
@MainActor
enum FanActivity {
    static func caption(fan: FanInfo, model: AppModel) -> String {
        let policy = model.settings.policy.fanPolicy(at: fan.index)
        if policy.mode == .auto { return "System control" }
        if !model.helper.controllableFans.contains(fan.index) {
            return model.helper.failsafe.active ? (model.helper.failsafe.isBlind ? "System control (no temperatures)" : "Failsafe active") : "Monitor only"
        }
        if model.helper.failsafe.active {
            return model.helper.failsafe.isBlind ? "System control (helper cannot read temperatures)" : "Failsafe: maximum speed"
        }
        // The helper turned the last command down: the target below was never applied.
        if model.refusedFans.contains(fan.index) { return "Not applied: the helper refused the command" }
        guard let directive = model.directive(forFan: fan.index) else { return Fmt.modeName(policy.mode, usePercent: model.usePercent) }
        switch directive.command {
        case .auto:
            return policy.mode == .boost || policy.mode == .curve ? "\(Fmt.modeName(policy.mode, usePercent: model.usePercent)): idle" : "System control"
        case .rpm(let rpm):
            let limits = FanLimits(fan)
            let percent = Int(RPMMath.percent(forRPM: rpm, limits: limits).rounded())
            let arrow = directive.isRamping ? "\u{2197} " : ""
            if policy.mode == .manual, policy.manualUnit == .percent {
                return "Target \(arrow)\(percent)%  (\(Fmt.rpm(rpm)))"
            }
            return "Target \(arrow)\(Fmt.rpm(rpm))  (\(percent)%)"
        }
    }
}

/// One fan in the menu panel: name and speed on the left, gauge on the right.
struct MenuFanRow: View {
    @EnvironmentObject var model: AppModel
    var info: FanInfo

    var body: some View {
        let reading = model.fanReading(info.index)
        let mode = model.settings.policy.fanPolicy(at: info.index).mode
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(info.name).font(.system(size: 13)).lineLimit(1)
                Text(Fmt.rpm(reading?.actualRPM))
                    .font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .frame(width: 104, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) {
                FanGauge(info: info, reading: reading, showKnob: mode == .manual && model.canControlFans, height: 20)
                Text(FanActivity.caption(fan: info, model: model))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 3)
    }
}

/// A fan "card" for the main window grid: name, gauge with slider, min/max labels.
struct MainFanCard: View {
    @EnvironmentObject var model: AppModel
    var info: FanInfo

    var body: some View {
        let reading = model.fanReading(info.index)
        let policy = model.settings.policy.fanPolicy(at: info.index)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(info.name).font(.system(size: 13, weight: .medium))
                Spacer()
                if model.fanCount > 1, model.canControlFans {
                    Menu {
                        ForEach(ControlMode.allCases, id: \.self) { mode in
                            Button(Fmt.modeName(mode, usePercent: model.usePercent)) { model.setFanMode(mode, fan: info.index) }
                        }
                    } label: {
                        Text(Fmt.segmentName(policy.mode, usePercent: model.usePercent)).font(.system(size: 11))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Mode of this fan only")
                }
            }
            FanGauge(info: info, reading: reading, showKnob: policy.mode == .manual && model.canControlFans, height: 22)
            HStack {
                Text(Fmt.rpm(reading?.actualRPM)).font(.system(size: 11, weight: .bold)).monospacedDigit()
                Spacer()
                Text(Fmt.rpm(info.minRPM)).font(.system(size: 11)).foregroundStyle(.secondary)
                Text("\u{2013}").font(.system(size: 11)).foregroundStyle(.secondary)
                Text(Fmt.rpm(info.maxRPM)).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text(FanActivity.caption(fan: info, model: model))
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
