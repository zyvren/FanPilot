import XCTest
@testable import FanPilotKit

final class ModelsTests: XCTestCase {
    // MARK: HelperConfig

    func testHelperConfigDefaultsAreRestrictive() {
        let config = HelperConfig()
        XCTAssertEqual(config.allowedUIDs, [])
        XCTAssertEqual(config.authMode, .uid)
        XCTAssertEqual(config.failsafeTempC, 95)
        XCTAssertEqual(config.leaseMaxSeconds, 30)
        XCTAssertEqual(config.socketPath, "/var/run/fanpilot.sock")
        XCTAssertTrue(config.isUIDAllowed(0))
        XCTAssertFalse(config.isUIDAllowed(501))
    }

    func testHelperConfigDecodesSpecExample() throws {
        let json = #"{"allowedUIDs":[501],"authMode":"pinned","pinnedCdhashes":["ABCDEF0123"],"failsafeTempC":90,"leaseMaxSeconds":20,"socketPath":"/var/run/fanpilot.sock"}"#
        let config = try JSONDecoder().decode(HelperConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.allowedUIDs, [501])
        XCTAssertEqual(config.authMode, .pinned)
        XCTAssertTrue(config.isCdhashPinned("abcdef0123"))
        XCTAssertTrue(config.isUIDAllowed(501))
        XCTAssertEqual(config.failsafeTempC, 90)
        XCTAssertEqual(config.leaseMaxSeconds, 20)
    }

    func testHelperConfigNeverAllowsFailsafeAbove100OrBelow85() {
        XCTAssertEqual(HelperConfig(failsafeTempC: 150).failsafeTempC, 100)
        XCTAssertEqual(HelperConfig(failsafeTempC: 20).failsafeTempC, 85)
        XCTAssertEqual(HelperConfig(failsafeTempC: .nan).failsafeTempC, 95)
        XCTAssertEqual(HelperConfig(leaseMaxSeconds: 100_000).leaseMaxSeconds, 120)
        XCTAssertEqual(HelperConfig(leaseMaxSeconds: 0).leaseMaxSeconds, 5)
        XCTAssertEqual(HelperConfig(socketPath: "").socketPath, Constants.socketPath)
        let decoded = HelperConfig.decode(from: Data(#"{"failsafeTempC":500}"#.utf8))
        XCTAssertEqual(decoded.failsafeTempC, 100)
    }

    func testHelperConfigIsTolerantAndFailsClosed() {
        XCTAssertEqual(HelperConfig.decode(from: Data()), HelperConfig())
        XCTAssertEqual(HelperConfig.decode(from: Data("{ not json".utf8)), HelperConfig())
        XCTAssertEqual(HelperConfig.decode(from: Data("{}".utf8)), HelperConfig())
        let partial = HelperConfig.decode(from: Data(#"{"allowedUIDs":"oops","failsafeTempC":88,"authMode":"magic"}"#.utf8))
        XCTAssertEqual(partial.allowedUIDs, [])
        XCTAssertEqual(partial.authMode, .uid)
        XCTAssertEqual(partial.failsafeTempC, 88)
        XCTAssertEqual(HelperConfig.load(from: "/nonexistent/helper.json"), HelperConfig())
    }

    func testHelperConfigRoundTrip() throws {
        let config = HelperConfig(allowedUIDs: [501, 502], authMode: .pinned, pinnedCdhashes: ["AA", "bb"],
                                  failsafeTempC: 92, leaseMaxSeconds: 45, socketPath: "/tmp/x.sock")
        XCTAssertEqual(HelperConfig.decode(from: try config.encoded()), config.normalized())
    }

    // MARK: Sensors and fans

    func testSensorIDsAndAreaOrder() {
        let s = Sensor.smc(key: "Tp04", name: "Super Core 1", area: .cpu)
        XCTAssertEqual(s.id, "smc:Tp04")
        XCTAssertEqual(Sensor.hid(key: "NAND CH0 temp", name: "SSD", area: .storage).id, "hid:NAND CH0 temp")
        XCTAssertEqual(SensorArea.allCases.first, .cpu)
        XCTAssertEqual(SensorArea.allCases.last, .other)
        XCTAssertEqual(SensorArea.allCases.sorted(by: >).first, .other)
        XCTAssertEqual(Set(SensorArea.allCases.map(\.rawValue)).count, 13)
        XCTAssertEqual(SensorArea.airflow.displayName, "Logic Board")
        XCTAssertEqual(SensorArea.palmRest.rawValue, "palmRest")
    }

    func testSensorCodableAndUnavailableReading() throws {
        let s = Sensor.smc(key: "TCHP", name: "Charger", area: .power)
        let back = try JSONDecoder().decode(Sensor.self, from: try JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
        let na = SensorReading.unavailable(s)
        XCTAssertFalse(na.valid)
        XCTAssertTrue(na.value.isNaN)
        XCTAssertEqual(na.id, s.id)
    }

    func testSensorSelectorStorageStrings() throws {
        let cases: [(SensorSelector, String)] = [
            (.computerAverage, "average"), (.highest, "highest"), (.averageCPU, "avgCPU"),
            (.highestCPU, "highestCPU"), (.sensor("smc:Tp04"), "sensor:smc:Tp04"),
        ]
        for (selector, text) in cases {
            XCTAssertEqual(selector.storageString, text)
            XCTAssertEqual(SensorSelector(storageString: text), selector)
            let data = try JSONEncoder().encode([selector])
            XCTAssertEqual(String(decoding: data, as: UTF8.self), "[\"\(text)\"]")
        }
        XCTAssertEqual(SensorSelector(storageString: "nonsense"), .highest)
        XCTAssertEqual(SensorSelector(storageString: "sensor:"), .highest)
        XCTAssertEqual(try JSONDecoder().decode(SensorSelector.self, from: Data("42".utf8)), .highest)
    }

    func testValidTemperatureWindow() {
        XCTAssertTrue(Constants.isValidTemperature(41.5))
        XCTAssertTrue(Constants.isValidTemperature(124.9))
        XCTAssertFalse(Constants.isValidTemperature(125))
        XCTAssertFalse(Constants.isValidTemperature(9.9))
        XCTAssertFalse(Constants.isValidTemperature(-9201))
        XCTAssertFalse(Constants.isValidTemperature(.nan))
    }

    func testFanInfoWireShapeAndRoundTrip() throws {
        let fan = FanInfo(index: 1, name: "Right Side", minRPM: 1350, maxRPM: 5777,
                          backend: .appleSiliconMd(modeKey: "F1md"))
        XCTAssertEqual(fan.modeKey, "F1md")
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fan)) as! [String: Any]
        XCTAssertEqual(object["backend"] as? String, "appleSiliconMd")
        XCTAssertEqual(object["modeKey"] as? String, "F1md")
        XCTAssertEqual(try JSONDecoder().decode(FanInfo.self, from: JSONEncoder().encode(fan)), fan)

        let intel = FanInfo(index: 0, name: "Fan 1", minRPM: 1200, maxRPM: 6000, backend: .intelForced)
        XCTAssertNil(intel.modeKey)
        XCTAssertEqual(try JSONDecoder().decode(FanInfo.self, from: JSONEncoder().encode(intel)), intel)
        XCTAssertFalse(FanBackend.none.canControl)
        XCTAssertTrue(FanBackend.intelForced.canControl)
    }

    func testFanBackendCodable() throws {
        for backend in [FanBackend.appleSiliconMd(modeKey: "F0Md"), .intelForced, .none] {
            XCTAssertEqual(try JSONDecoder().decode(FanBackend.self, from: JSONEncoder().encode(backend)), backend)
        }
        XCTAssertThrowsError(try JSONDecoder().decode(FanBackend.self, from: Data(#"{"kind":"appleSiliconMd"}"#.utf8)))
    }

    func testFanReadingNormalizedSpeed() {
        let r = FanReading(index: 0, actualRPM: 3349.5, targetRPM: 0, mode: 0, minRPM: 1350, maxRPM: 5349)
        XCTAssertEqual(r.normalizedSpeed, 0.5, accuracy: 1e-9)
        XCTAssertEqual(FanReading(index: 0, actualRPM: 0, targetRPM: 0, mode: 0, minRPM: 1350, maxRPM: 5349).normalizedSpeed, 0)
        XCTAssertEqual(FanReading(index: 0, actualRPM: 9000, targetRPM: 0, mode: 1, minRPM: 1350, maxRPM: 5349).normalizedSpeed, 1)
        XCTAssertTrue(FanReading(index: 0, actualRPM: 0, targetRPM: 0, mode: 1, minRPM: 0, maxRPM: 0).isManual)
        XCTAssertEqual(FanReading(index: 0, actualRPM: 1, targetRPM: 0, mode: 0, minRPM: 5, maxRPM: 5).normalizedSpeed, 0)
    }

    // MARK: Policy

    func testControlModeOrderAndNames() {
        XCTAssertEqual(ControlMode.allCases.map(\.rawValue), ["auto", "manual", "max", "boost", "curve"])
        XCTAssertFalse(ControlMode.auto.takesControl)
        XCTAssertTrue(ControlMode.max.takesControl)
    }

    func testDefaultBoostRulesMatchSpec() {
        let adapter = BoostSettings().rules(for: .adapter)
        XCTAssertEqual(adapter.map(\.limitC), [58, 70, 82])
        XCTAssertEqual(adapter.map(\.percent), [35, 65, 100])
        XCTAssertTrue(adapter.allSatisfy { $0.sensor == .highestCPU && $0.fanIndex == nil && $0.enabled })
        XCTAssertEqual(BoostSettings().rules(for: .battery).count, 3)
        XCTAssertEqual(Set(BoostSettings().rules.map(\.id)).count, 6, "default rule ids are unique")
        XCTAssertEqual(BoostSettings(), BoostSettings(), "defaults are deterministic")
        let s = BoostSettings()
        XCTAssertEqual(s.hysteresisC, 3)
        XCTAssertEqual(s.minHoldSeconds, 15)
        XCTAssertEqual(s.rampUpSeconds, 6)
        XCTAssertEqual(s.rampDownSeconds, 20)
        XCTAssertEqual(s.releaseDelaySeconds, 10)
    }

    func testCorruptBoostRuleIsSkippedNotFatal() throws {
        let json = """
        {"rules":[
          {"id":"FA11F170-0000-4000-8000-0000000000A1","limitC":61,"percent":40,"powerSource":"adapter"},
          "garbage",
          {"limitC":"hot"},
          {"limitC":75,"percent":250,"fanIndex":99,"powerSource":"nonsense"}
        ],"hysteresisC":"x"}
        """
        let settings = try JSONDecoder().decode(BoostSettings.self, from: Data(json.utf8)).normalized()
        XCTAssertEqual(settings.rules.count, 3, "the string element is dropped; bad fields inside rules become defaults")
        XCTAssertEqual(settings.rules[0].limitC, 61)
        XCTAssertEqual(settings.rules[0].percent, 40)
        XCTAssertEqual(settings.rules[1].limitC, 70, "wrong type falls back to the default")
        XCTAssertEqual(settings.rules[2].percent, 100, "clamped to 0...100")
        XCTAssertNil(settings.rules[2].fanIndex, "out-of-range fan means all fans")
        XCTAssertEqual(settings.rules[2].powerSource, .adapter)
        XCTAssertEqual(settings.hysteresisC, 3)
    }

    func testCurveSettingsNormalization() {
        var curve = CurveSettings(points: [CurvePoint(tempC: 80, percent: 120), CurvePoint(tempC: 50, percent: -5),
                                           CurvePoint(tempC: .nan, percent: 10)], emaAlpha: 9, fallHysteresisC: -1)
        curve = curve.normalized()
        XCTAssertEqual(curve.points, [CurvePoint(tempC: 50, percent: 0), CurvePoint(tempC: 80, percent: 100)])
        XCTAssertEqual(curve.emaAlpha, 1)
        XCTAssertEqual(curve.fallHysteresisC, 0)
        XCTAssertEqual(CurveSettings(points: []).normalized().points, CurveSettings.defaultPoints)
        XCTAssertEqual(CurveSettings.defaultPoints.map(\.tempC), CurveSettings.defaultPoints.map(\.tempC).sorted())
    }

    func testPolicyAccessorsPadAndUniformMode() {
        var policy = Policy()
        XCTAssertTrue(policy.linkFans)
        XCTAssertEqual(policy.fanPolicy(at: 3), FanPolicy())
        XCTAssertNil(policy.uniformMode(fanCount: 0))
        XCTAssertEqual(policy.uniformMode(fanCount: 2), .auto)

        policy.setMode(.boost, fanCount: 2)
        XCTAssertEqual(policy.perFan.count, 2)
        XCTAssertEqual(policy.uniformMode(fanCount: 2), .boost)

        policy.setFanPolicy(FanPolicy(mode: .manual, manualRPM: 3000), at: 1)
        XCTAssertNil(policy.uniformMode(fanCount: 2))
        XCTAssertEqual(policy.fanPolicy(at: 1).manualRPM, 3000)

        policy.setFanPolicy(FanPolicy(mode: .max), at: 99)
        XCTAssertEqual(policy.perFan.count, 2, "out of range index is ignored")

        XCTAssertEqual(policy.normalized(fanCount: 1).perFan.count, 1)
        XCTAssertEqual(policy.normalized(fanCount: 4).perFan.count, 4)
    }

    func testFanPolicyNormalization() {
        let p = FanPolicy(mode: .manual, manualRPM: -5, manualPercent: 400, manualUnit: .percent).normalized()
        XCTAssertEqual(p.manualRPM, 0)
        XCTAssertEqual(p.manualPercent, 100)
    }

    // MARK: AppSettings

    func testAppSettingsDefaults() {
        let s = AppSettings()
        XCTAssertEqual(s.updateIntervalSecs, 2)
        XCTAssertEqual(s.tempUnit, .celsius)
        XCTAssertTrue(s.linkFans)
        XCTAssertTrue(s.turnOffFanControlForSleep)
        XCTAssertFalse(s.resumeOnLaunch, "FanPilot starts in Auto (SPEC 4.6)")
        XCTAssertEqual(s.menuBar.temp1, MenuBarTempSlot(enabled: true, source: .highest))
        XCTAssertEqual(s.menuBar.temp2, MenuBarTempSlot(enabled: true, source: .averageCPU))
        XCTAssertEqual(s.menuBar.fan, MenuBarFanSlot(enabled: true, source: .average))
        XCTAssertEqual(s.menuBar.stackOrder, .vertical)
        XCTAssertTrue(s.menuBar.useColors)
        XCTAssertFalse(s.menuBar.showAppIcon)
        XCTAssertEqual(s.alerts.warningTempC, 90)
        XCTAssertEqual(s.alerts.criticalTempC, 100)
        XCTAssertTrue(s.alerts.anySensorEnabled)
        XCTAssertEqual(s.alerts.anySensorLimitC, 100)
        XCTAssertFalse(s.alerts.highestCPUEnabled)
        XCTAssertEqual(s.alerts.repeatIntervalSeconds, 600)
        XCTAssertFalse(s.showDockIcon)
        XCTAssertFalse(s.launchAtLogin)
        XCTAssertEqual(s.schemaVersion, 1)
    }

    func testAppSettingsRoundTrip() throws {
        var s = AppSettings()
        s.updateIntervalSecs = 5
        s.tempUnit = .fahrenheit
        s.resumeOnLaunch = true
        s.lastMode = .boost
        s.menuBar.temp1 = MenuBarTempSlot(enabled: false, source: .sensor("smc:Tp04"))
        s.menuBar.fan = MenuBarFanSlot(enabled: true, source: .fan(1))
        s.policy.setMode(.manual, fanCount: 2)
        s.policy.setFanPolicy(FanPolicy(mode: .manual, manualRPM: 3100, manualPercent: 40, manualUnit: .percent), at: 0)
        s.policy.boost.rules.append(BoostRule(sensor: .sensor("hid:NAND CH0 temp"), limitC: 70, percent: 50, fanIndex: 1, powerSource: .battery))
        s.pinnedSensorIDs = ["smc:TB0T"]
        s.alerts.playSound = true
        s.alerts.soundName = "Glass"
        XCTAssertEqual(AppSettings.decode(from: try s.encoded()), s.normalized())
        XCTAssertEqual(AppSettings.decode(from: try AppSettings().encoded()), AppSettings())
    }

    func testAppSettingsDecodeNeverFails() {
        XCTAssertEqual(AppSettings.decode(from: nil), AppSettings())
        XCTAssertEqual(AppSettings.decode(from: Data()), AppSettings())
        XCTAssertEqual(AppSettings.decode(from: Data("{}".utf8)), AppSettings())
        XCTAssertEqual(AppSettings.decode(from: Data("\u{0}\u{1}garbage".utf8)), AppSettings())
        XCTAssertEqual(AppSettings.decode(from: Data("[1,2,3]".utf8)), AppSettings())
        XCTAssertEqual(AppSettings.decode(from: Data("null".utf8)), AppSettings())
    }

    func testAppSettingsReplacesOnlyTheBrokenValues() {
        let json = """
        {"schemaVersion":99,"updateIntervalSecs":"fast","tempUnit":"kelvin","turnOffFanControlForSleep":false,
         "menuBar":{"temp1":7,"stackOrder":"horizontal","useColors":"yes"},
         "alerts":{"warningTempC":85,"criticalTempC":50},
         "policy":{"perFan":[{"mode":"boost"},"junk",{"mode":"warp","manualRPM":2500}],"linkFans":false},
         "unknownFutureKey":{"a":1}}
        """
        let s = AppSettings.decode(from: Data(json.utf8))
        XCTAssertEqual(s.updateIntervalSecs, 2)
        XCTAssertEqual(s.tempUnit, .celsius)
        XCTAssertFalse(s.turnOffFanControlForSleep, "valid values are kept")
        XCTAssertEqual(s.menuBar.temp1, MenuBarTempSlot(enabled: true, source: .highest))
        XCTAssertEqual(s.menuBar.stackOrder, .horizontal)
        XCTAssertTrue(s.menuBar.useColors)
        XCTAssertEqual(s.alerts.warningTempC, 85)
        XCTAssertEqual(s.alerts.criticalTempC, 85, "critical can never be below warning")
        XCTAssertEqual(s.policy.perFan.map(\.mode), [.boost, .auto, .auto])
        XCTAssertEqual(s.policy.perFan[2].manualRPM, 2500)
        XCTAssertFalse(s.linkFans)
        XCTAssertEqual(s.schemaVersion, AppSettings.currentSchemaVersion)
    }

    func testAppSettingsClampsRanges() {
        XCTAssertEqual(AppSettings.decode(from: Data(#"{"updateIntervalSecs":0}"#.utf8)).updateIntervalSecs, 1)
        XCTAssertEqual(AppSettings.decode(from: Data(#"{"updateIntervalSecs":-4}"#.utf8)).updateIntervalSecs, 1)
        XCTAssertEqual(AppSettings.decode(from: Data(#"{"updateIntervalSecs":9999}"#.utf8)).updateIntervalSecs, 60)
        let hidden = AppSettings.decode(from: Data(#"{"menuBar":{"temp1":{"enabled":false},"temp2":{"enabled":false},"fan":{"enabled":false}}}"#.utf8))
        XCTAssertTrue(hidden.menuBar.hasVisibleContent, "the menu bar item must stay clickable")
    }

    func testTemperatureUnitFormatting() {
        XCTAssertEqual(TemperatureUnit.celsius.format(celsius: 41.6), "42°C")
        XCTAssertEqual(TemperatureUnit.fahrenheit.format(celsius: 100), "212°F")
        XCTAssertEqual(TemperatureUnit.fahrenheit.format(celsius: 0, includeUnit: false), "32")
        XCTAssertEqual(TemperatureUnit.celsius.format(celsius: nil), "N/A")
        XCTAssertEqual(TemperatureUnit.celsius.format(celsius: .nan), "N/A")
        XCTAssertEqual(TemperatureUnit.fahrenheit.toCelsius(212), 100, accuracy: 1e-9)
    }

    func testConstants() {
        XCTAssertEqual(Constants.socketPath, "/var/run/fanpilot.sock")
        XCTAssertEqual(Constants.helperLabel, "com.fanpilot.helper")
        XCTAssertEqual(Constants.maxLineBytes, 65_536)
        XCTAssertTrue(Constants.helperInstallPath.hasSuffix(Constants.helperLabel))
        XCTAssertTrue(Constants.launchDaemonPlistPath.contains(Constants.helperLabel))
        XCTAssertTrue(Constants.helperConfigPath.hasPrefix(Constants.supportDirectory))
        XCTAssertGreaterThan(Constants.defaultLeaseSeconds, Constants.heartbeatIntervalSeconds * 2,
                             "one lost heartbeat must not expire the lease")
        XCTAssertLessThanOrEqual(Constants.defaultLeaseSeconds, Constants.defaultLeaseMaxSeconds)
    }
}
