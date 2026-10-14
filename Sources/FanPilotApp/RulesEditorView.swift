import AppKit
import FanPilotControl
import FanPilotKit
import FanPilotSensors
import SwiftUI

/// Picks what a rule, curve or menu bar slot looks at: an aggregate or one sensor.
struct SensorSelectorPicker: View {
    @EnvironmentObject var model: AppModel
    @Binding var selection: SensorSelector

    var body: some View {
        Picker("Sensor", selection: $selection) {
            Text("Computer Average").tag(SensorSelector.computerAverage)
            Text("Highest").tag(SensorSelector.highest)
            Divider()
            Text("Average CPU").tag(SensorSelector.averageCPU)
            Text("Highest CPU").tag(SensorSelector.highestCPU)
            ForEach(model.pickerGroups) { group in
                Section(group.area.displayName) {
                    ForEach(group.readings) { reading in
                        Text(reading.sensor.name).tag(SensorSelector.sensor(reading.id))
                    }
                }
            }
            // A rule can name a sensor that is not in the list right now (hidden "Other" sensor, a
            // different Mac, a sensor that went missing). Keep it selectable so the Picker is not blank.
            if case .sensor(let id) = selection, model.snapshot.reading(id: id) == nil
                || !model.pickerGroups.contains(where: { $0.readings.contains { $0.id == id } }) {
                Divider()
                Text(model.snapshot.reading(id: id)?.sensor.name ?? "Unavailable sensor").tag(selection)
            }
        }
        .labelsHidden()
    }
}

// MARK: - Rules

/// The Auto Boost rule list for both power sources.
struct RulesEditorView: View {
    @EnvironmentObject var model: AppModel
    @State private var copyMessage: String?

    private var source: PowerSource {
        get { model.battery.isPresent && model.extras.rulesTabIsBattery ? .battery : .adapter }
    }

    private var rules: [BoostRule] { model.settings.policy.boost.rules(for: source) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.battery.isPresent {
                Picker("Power source", selection: Binding(get: { model.extras.rulesTabIsBattery },
                                                          set: { model.extras.rulesTabIsBattery = $0 })) {
                    Text("Power Adapter").tag(false)
                    Text("Battery").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 260)
            } else {
                Text("Rules for this Mac").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            }

            Group {
                if rules.isEmpty {
                    Text("No rules. Fans stay under system control in this mode until you add one.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 80)
                } else {
                    List {
                        ForEach(rules) { rule in
                            RuleRow(rule: rule, active: model.lastOutput?.activeBoostRuleIDs.contains(rule.id) ?? false)
                                .listRowInsets(EdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4))
                        }
                        .onMove { from, to in moveRules(from: from, to: to) }
                    }
                    .listStyle(.bordered(alternatesRowBackgrounds: true))
                }
            }
            .frame(minHeight: 120, maxHeight: 230)

            HStack(spacing: 10) {
                Button { addRule() } label: { Image(systemName: "plus") }
                    .help("Add a rule")
                if model.battery.isPresent {
                    Button(source == .adapter ? "Copy all to Battery" : "Copy all to Power Adapter") { copyAll() }
                        .help("Adds copies of these rules to the other power source; rules already there are kept")
                }
                Button("Restore Defaults") { restoreDefaults() }
                Spacer()
            }
            if let copyMessage {
                Text(copyMessage).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private func addRule() {
        model.updateBoost { boost in
            let new = BoostRule(sensor: .highestCPU, limitC: 70, percent: 100, fanIndex: nil, powerSource: source)
            boost.rules = Self.ordered(boost.rules + [new])
        }
    }

    private func moveRules(from: IndexSet, to: Int) {
        model.updateBoost { boost in
            var mine = boost.rules.filter { $0.powerSource == source }
            let others = boost.rules.filter { $0.powerSource != source }
            mine.move(fromOffsets: from, toOffset: to)
            boost.rules = Self.ordered(mine + others)
        }
    }

    private func restoreDefaults() {
        model.updateBoost { boost in
            let defaults = BoostSettings.defaultRules.filter { $0.powerSource == source }
            boost.rules = Self.ordered(boost.rules.filter { $0.powerSource != source } + defaults)
        }
    }

    /// Copies every rule that the other set does not already contain (same fields), as new rules.
    private func copyAll() {
        let target: PowerSource = source == .adapter ? .battery : .adapter
        var copied = 0
        model.updateBoost { boost in
            let existing = boost.rules.filter { $0.powerSource == target }
            var added: [BoostRule] = []
            for rule in boost.rules where rule.powerSource == source {
                let duplicate = (existing + added).contains {
                    $0.enabled == rule.enabled && $0.sensor == rule.sensor && $0.limitC == rule.limitC
                        && $0.percent == rule.percent && $0.fanIndex == rule.fanIndex
                }
                if duplicate { continue }
                var copy = rule
                copy.id = UUID()
                copy.powerSource = target
                added.append(copy)
            }
            copied = added.count
            boost.rules = Self.ordered(boost.rules + added)
        }
        let name = target == .battery ? "Battery" : "Power Adapter"
        copyMessage = copied == 0 ? "Nothing to copy: \(name) already has these rules."
                                  : "Copied \(copied) rule\(copied == 1 ? "" : "s") to \(name). Switch tabs to see them."
    }

    /// Adapter rules first, then battery rules; the order inside each set is kept.
    static func ordered(_ rules: [BoostRule]) -> [BoostRule] {
        rules.filter { $0.powerSource == .adapter } + rules.filter { $0.powerSource == .battery }
    }
}

private struct RuleRow: View {
    @EnvironmentObject var model: AppModel
    let rule: BoostRule
    let active: Bool

    var body: some View {
        HStack(spacing: 6) {
            Toggle("", isOn: bind(\.enabled)).labelsHidden().toggleStyle(.checkbox)
                .help("Turn this rule on or off")

            Picker("Fans", selection: bind(\.fanIndex)) {
                if model.fanCount > 1 {
                    Text("All Fans").tag(Int?.none)
                    Divider()
                    ForEach(model.fanInfos) { Text($0.name).tag(Int?.some($0.index)) }
                } else {
                    Text(model.fanInfos.first?.name ?? "All Fans").tag(Int?.none)
                }
            }
            .labelsHidden().frame(width: 130)

            Text("to")

            if model.usePercent {
                TextField("", value: Binding(get: { rule.percent }, set: { value in update { $0.percent = min(max(value, 0), 100) } }),
                          format: .number.precision(.fractionLength(0)))
                    .multilineTextAlignment(.trailing).frame(width: 40)
                Text("%")
            } else {
                Text("100%").foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
            }

            Text("when")
            SensorSelectorPicker(selection: bind(\.sensor)).frame(width: 190)
            Text("is above")
            TextField("", value: Binding(
                get: { model.temperatureUnit.convert(fromCelsius: rule.limitC) },
                set: { value in update { $0.limitC = min(max(model.temperatureUnit.toCelsius(value), 0), 130) } }),
                      format: .number.precision(.fractionLength(0)))
                .multilineTextAlignment(.trailing).frame(width: 44)
            Text(model.temperatureUnit.symbol)

            Spacer(minLength: 4)
            if active {
                Image(systemName: "bolt.fill").foregroundStyle(.orange).help("This rule is active now")
            }
            Button { remove() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.plain).help("Remove this rule")
        }
        .font(.system(size: 12))
        .opacity(rule.enabled ? 1 : 0.55)
    }

    private func update(_ change: @escaping (inout BoostRule) -> Void) {
        let id = rule.id
        model.updateBoost { boost in
            guard let index = boost.rules.firstIndex(where: { $0.id == id }) else { return }
            change(&boost.rules[index])
        }
    }

    private func bind<Value>(_ keyPath: WritableKeyPath<BoostRule, Value>) -> Binding<Value> {
        Binding(get: { rule[keyPath: keyPath] }, set: { value in update { $0[keyPath: keyPath] = value } })
    }

    private func remove() {
        let id = rule.id
        model.updateBoost { $0.rules.removeAll { $0.id == id } }
    }
}

// MARK: - Options

/// Ramp times, hysteresis and the Auto Boost / Auto Max switch (Fan pane).
struct BoostOptionsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let boost = model.settings.policy.boost
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(get: { boost.usePercent }, set: { value in model.updateBoost { $0.usePercent = value } })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use Auto Boost instead of Auto Max")
                    Text("Auto Boost lets every rule pick its own fan speed in percent. Auto Max runs the fans at full speed whenever any rule fires.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            SecondsSlider(title: "Speed up over", value: boost.rampUpSeconds, range: 1...120,
                          help: "How long the fans take to reach a higher speed.") { v in model.updateBoost { $0.rampUpSeconds = v } }
            SecondsSlider(title: "Slow down over", value: boost.rampDownSeconds, range: 1...120,
                          help: "How long the fans take to come back down. Longer avoids fans pumping up and down.") { v in model.updateBoost { $0.rampDownSeconds = v } }
            SecondsSlider(title: "Hold each rule for at least", value: boost.minHoldSeconds, range: 0...120,
                          help: "A rule that fired stays active at least this long.") { v in model.updateBoost { $0.minHoldSeconds = v } }
            SecondsSlider(title: "Return to system control after", value: boost.releaseDelaySeconds, range: 0...120,
                          help: "Once no rule is active and the fans are back at their minimum.") { v in model.updateBoost { $0.releaseDelaySeconds = v } }
            HStack {
                Text("Rules release at")
                let unit = model.temperatureUnit
                Stepper(value: Binding(get: { unit.delta(fromCelsius: boost.hysteresisC) },
                                       set: { v in model.updateBoost { $0.hysteresisC = unit.deltaToCelsius(v) } }),
                        in: 0...unit.delta(fromCelsius: 20), step: 1) {
                    Text("\(unit.formatDelta(celsius: boost.hysteresisC)) below their limit").monospacedDigit()
                }
                .help("A rule stays active until the temperature has dropped this far under its limit.")
            }
        }
        .font(.system(size: 12))
    }
}

private struct SecondsSlider: View {
    var title: String
    var value: Double
    var range: ClosedRange<Double>
    var help: String
    var onChange: (Double) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(title).frame(width: 190, alignment: .leading)
            Slider(value: Binding(get: { value }, set: { onChange($0.rounded()) }), in: range)
                .frame(maxWidth: 260)
            Text("\(Int(value)) sec").monospacedDigit().frame(width: 60, alignment: .leading)
        }
        .help(help)
    }
}

// MARK: - Main window page

struct BoostPage: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.usePercent ? "Auto Boost rules" : "Auto Max rules").font(.system(size: 15, weight: .semibold))
                    Text("When a sensor goes above its limit the fans speed up. The highest matching rule wins. Choose \(Fmt.modeName(.boost, usePercent: model.usePercent)) in the Fans section to turn the rules on.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                RulesEditorView()
                Divider()
                BoostOptionsView()
            }
            .padding(20)
            .frame(maxWidth: 820, alignment: .leading)
        }
    }
}
