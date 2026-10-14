import AppKit
import FanPilotControl
import FanPilotKit
import FanPilotSensors
import SwiftUI

// MARK: - Fans

/// The Fans pane: rules, ramp times, sleep behavior, linking, and the helper row.
struct FanPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                group("\(model.usePercent ? "Auto Boost" : "Auto Max") Rules") {
                    RulesEditorView()
                }

                group("Gradual Speed Changes") {
                    BoostOptionsView()
                }

                group("System Sleep") {
                    Toggle(isOn: $model.settings.turnOffFanControlForSleep) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Give the fans back to the system while the Mac sleeps")
                            Text("On newer Macs the fans stop soon after sleep begins anyway. FanPilot resumes five seconds after wake.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }

                group("Starting Up and Linking") {
                    Toggle(isOn: $model.settings.resumeOnLaunch) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Resume the last mode when FanPilot starts")
                            Text("Off by default: FanPilot starts with the fans in system control, and the menu offers \u{201C}Resume\u{201D}.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    Toggle(isOn: Binding(get: { model.settings.policy.linkFans }, set: { model.setLinkFans($0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Link fan speeds in Manual mode")
                            Text("Moving one slider moves the others to the same position in their own range.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }

                group("Fan Curve") {
                    HStack {
                        Text("Curve mode sets the fan speed from one temperature along a line you draw.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Edit Curve\u{2026}") { WindowCoordinator.shared.showMainWindow(page: .curve) }
                    }
                }

                Divider()
                HelperStatusRow()
            }
            .padding(20)
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold))
            content()
        }
    }
}

/// The helper line at the bottom of the Fans pane.
struct HelperStatusRow: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            StatusLight(status: model.helper.isConnected && !model.helper.monitorOnly && !model.helper.failsafe.active ? .good : .problem)
            Text(HelperDescription.summary(model)).font(.system(size: 12)).lineLimit(2)
            Spacer()
            if !model.helper.isConnected {
                Button(HelperInstaller.isInstalledOnDisk ? "Reinstall Fan Helper\u{2026}" : "Install Fan Helper\u{2026}") {
                    model.confirmAndInstallHelper()
                }
                .disabled(model.installInProgress)
            }
        }
    }
}

// MARK: - Helper

struct HelperPane: View {
    @EnvironmentObject var model: AppModel
    @State private var copied = false

    var body: some View {
        Form {
            Section("Status") {
                HStack(alignment: .top, spacing: 10) {
                    StatusLight(status: model.helper.isConnected && !model.helper.monitorOnly && !model.helper.failsafe.active ? .good : .problem)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(HelperDescription.summary(model)).fixedSize(horizontal: false, vertical: true)
                        if let error = model.helper.status?.lastError ?? model.helper.lastCommandError {
                            Text("Last problem: \(error)").font(.system(size: 11)).foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    Button("Reconnect") { model.client.retryNow() }.controlSize(.small)
                }
                if let hello = model.helper.hello {
                    LabeledContent("Version", value: hello.version)
                    LabeledContent("Safety limit", value: "\(Fmt.temperature(hello.failsafeTempC, unit: model.temperatureUnit)) (set in helper.json)")
                    LabeledContent("Longest lease", value: "\(Int(hello.leaseMaxS)) sec")
                    if let dict = model.helper.status?.dict {
                        LabeledContent("System fan override flag", value: dict == 0 ? "off" : "on")
                    }
                }
                LabeledContent("Socket", value: Constants.socketPath)
                LabeledContent("Installed files", value: HelperInstaller.isInstalledOnDisk ? "present" : "none")
            }

            if let fans = model.helper.hello?.fans, !fans.isEmpty {
                Section("Fans the Helper Can Control") {
                    ForEach(fans) { fan in
                        LabeledContent(model.fanInfos.first { $0.index == fan.index }?.name ?? fan.name) {
                            Text("\(Fmt.rpm(fan.minRPM, includeUnit: false))\u{2013}\(Fmt.rpm(fan.maxRPM))  \u{00B7}  \(fan.backend.canControl ? fan.backend.kind : "monitor only")")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Install or Remove") {
                HStack {
                    Button(HelperInstaller.isInstalledOnDisk ? "Reinstall Helper\u{2026}" : "Install Helper\u{2026}") {
                        model.confirmAndInstallHelper()
                    }
                    .disabled(model.installInProgress)
                    Button("Remove Helper\u{2026}", role: .destructive) { model.confirmAndUninstallHelper() }
                        .disabled(model.installInProgress || !HelperInstaller.isInstalledOnDisk)
                    if model.installInProgress { ProgressView().controlSize(.small) }
                    Spacer()
                }
                Text("Installing asks for your administrator password once. The helper runs as a launch daemon and can change fan speeds only within each fan's own safe range.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !HelperInstaller.isPayloadAvailable {
                    Label("This copy of FanPilot has no bundled helper. Build the app with scripts/build_app.sh.", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                }
                if let output = model.installOutput, !output.isEmpty {
                    ScrollView {
                        Text(output).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 90)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                }
            }

            Section("From a Terminal") {
                Text("You can also install the helper yourself. This runs the same script:")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Text(terminalCommand).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(copied ? "Copied" : "Copy Command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(terminalCommand, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                    }
                    .controlSize(.small)
                    Button("Reveal Helper Log") {
                        NSWorkspace.shared.selectFile(Constants.helperLogPath, inFileViewerRootedAtPath: "/var/log")
                    }
                    .controlSize(.small)
                    .disabled(!FileManager.default.fileExists(atPath: Constants.helperLogPath))
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.client.pollStatus() }
    }

    private var terminalCommand: String {
        let dir = HelperInstaller.payloadDirectory()?.path ?? "<FanPilot.app>/Contents/Resources/helper"
        return "sudo \(HelperInstaller.shellQuote(dir + "/install_helper.sh")) --daemon \(HelperInstaller.shellQuote(dir + "/fanpilotd")) --ctl \(HelperInstaller.shellQuote(dir + "/fanpilotctl")) --uid \(getuid())"
    }
}
