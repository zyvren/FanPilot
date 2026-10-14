import Darwin
import FanPilotKit
import XCTest
@testable import FanPilotHelperCore

/// A synchronous test client speaking the wire protocol over a real Unix socket.
final class TestClient {
    let connection: LineSocketConnection
    private var nextID = 1

    init(path: String, maxLineBytes: Int = Constants.maxLineBytes) throws {
        connection = try LineSocketConnection.connect(path: path, maxLineBytes: maxLineBytes)
    }

    deinit { connection.close() }

    func send(_ command: WireCommand) throws {
        try connection.sendRequest(WireRequest(id: nextID, command: command))
        nextID += 1
    }

    @discardableResult
    func call(_ command: WireCommand, timeout: TimeInterval = 3) throws -> WireReply {
        try send(command)
        guard let reply = try connection.readReply(timeout: timeout) else { throw LineSocketError.closed }
        return reply
    }

    @discardableResult
    func hello() throws -> WireReply {
        try call(.hello(proto: 1, client: "tests"))
    }

    /// True if the server closed the connection (EOF) within the timeout.
    func waitForClose(timeout: TimeInterval = 3) -> Bool {
        do { return try connection.readLine(timeout: timeout) == nil } catch { return false }
    }
}

func eventually(timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return condition()
}

final class HelperServerTests: XCTestCase {
    private var logs: LogCapture!
    private var servers: [HelperServer] = []

    override func setUp() {
        super.setUp()
        logs = LogCapture()
    }

    override func tearDown() {
        servers.forEach { $0.stop() }
        servers.removeAll()
        logs = nil
        super.tearDown()
    }

    private func makeServer(authorizer: PeerAuthorizer = AllowAllPeerAuthorizer(),
                            helloTimeout: TimeInterval = 2,
                            idleTimeout: TimeInterval = 60,
                            maxConnections: Int = 4,
                            hot: StubHotSet = StubHotSet(45)) throws -> (HelperServer, EngineHarness, String) {
        let harness = EngineHarness(hot: hot)
        let path = "/tmp/fp-test-\(UUID().uuidString.prefix(8)).sock"
        let server = HelperServer(engine: harness.engine, authorizer: authorizer, socketPath: path,
                                  helloTimeout: helloTimeout, idleTimeout: idleTimeout, maxConnections: maxConnections)
        try server.start()
        servers.append(server)
        return (server, harness, path)
    }

    // MARK: Protocol over a real socket

    func testEndToEndSetStatusHeartbeatBye() throws {
        let (_, h, path) = try makeServer()
        let client = try TestClient(path: path)

        let hello = try client.hello()
        guard case .hello(let info) = hello.body else { return XCTFail("\(hello)") }
        XCTAssertEqual(info.fans.count, 2)

        let set = try client.call(.set(fan: 0, rpm: 3000, ttl: 15))
        XCTAssertEqual(set.setReply, SetReply(applied: 3000, clamped: false))
        XCTAssertEqual(h.smc.byte("F0md"), 1)
        XCTAssertEqual(h.smc.float("F0Tg"), 3000)

        let status = try client.call(.status)
        XCTAssertEqual(status.statusReply?.fans[0].owned, true)
        XCTAssertEqual(try client.call(.heartbeat(ttl: 15)).heartbeatOwned, [0])

        let bye = try client.call(.bye)
        XCTAssertTrue(bye.ok)
        XCTAssertTrue(client.waitForClose())
        XCTAssertTrue(eventually { h.smc.byte("F0md") == 0 })
    }

    func testAbruptDisconnectReleasesTheFans() throws {
        let (_, h, path) = try makeServer()
        let client = try TestClient(path: path)
        try client.hello()
        try client.call(.set(fan: 0, rpm: 3000, ttl: 15))
        try client.call(.set(fan: 1, rpm: 3000, ttl: 15))
        XCTAssertEqual(h.smc.byte("F1md"), 1)

        client.connection.close()     // no bye: the app crashed

        XCTAssertTrue(eventually { h.smc.byte("F0md") == 0 && h.smc.byte("F1md") == 0 },
                      "fans must return to auto when the client disappears")
    }

    func testRepliesArriveOnePerRequestInOrder() throws {
        let (_, _, path) = try makeServer()
        let client = try TestClient(path: path)
        try client.hello()
        for _ in 0..<20 { try client.send(.status) }
        var ids: [Int] = []
        for _ in 0..<20 {
            let reply = try XCTUnwrap(try client.connection.readReply(timeout: 3))
            XCTAssertTrue(reply.ok)
            ids.append(reply.id)
        }
        XCTAssertEqual(ids, Array(2...21))
    }

    func testHelloMustArriveInTime() throws {
        let (_, _, path) = try makeServer(helloTimeout: 0.3)
        let client = try TestClient(path: path)
        let started = Date()
        XCTAssertTrue(client.waitForClose(timeout: 3), "a silent connection is dropped")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    }

    func testFirstMessageMustBeHello() throws {
        let (_, h, path) = try makeServer()
        let client = try TestClient(path: path)
        let reply = try client.call(.set(fan: 0, rpm: 3000, ttl: nil))
        XCTAssertEqual(reply.err, .badRequest)
        XCTAssertTrue(client.waitForClose())
        XCTAssertTrue(h.smc.writes.isEmpty)
    }

    func testMalformedLinesAreAnsweredAndTheConnectionSurvives() throws {
        let (_, _, path) = try makeServer()
        let client = try TestClient(path: path)
        try client.hello()

        try client.connection.writeLine(Data("this is not json".utf8))
        let garbage = try XCTUnwrap(try client.connection.readReply(timeout: 3))
        XCTAssertEqual(garbage.err, .badRequest)
        XCTAssertEqual(garbage.id, 0)

        try client.connection.writeLine(Data(#"{"id":77,"op":"explode"}"#.utf8))
        let unknown = try XCTUnwrap(try client.connection.readReply(timeout: 3))
        XCTAssertEqual(unknown.err, .badRequest)
        XCTAssertEqual(unknown.id, 77, "the id is echoed when it can be found")

        XCTAssertTrue(try client.call(.status).ok, "still usable afterwards")
    }

    func testOverlongLineClosesTheConnection() throws {
        let (_, _, path) = try makeServer()
        let client = try TestClient(path: path, maxLineBytes: 200_000)
        try client.hello()
        // The server may hang up while the rest of the line is still being written, so a failing
        // write is fine; what matters is that the connection ends and the helper stays healthy.
        try? client.connection.writeLine(Data(repeating: 0x41, count: 100_000))
        if let reply = try? client.connection.readReply(timeout: 3) {
            XCTAssertEqual(reply.err, .badRequest)
        }
        XCTAssertTrue(client.waitForClose())
        XCTAssertTrue(try TestClient(path: path).hello().ok, "other clients are unaffected")
    }

    func testSocketFileIsWorldConnectable() throws {
        let (_, _, path) = try makeServer()
        var info = stat()
        XCTAssertEqual(lstat(path, &info), 0)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFSOCK)
        XCTAssertEqual(info.st_mode & 0o777, 0o666, "access control is by peer credentials, not file mode")
    }

    // MARK: Connection limits and authorization

    func testConnectionCap() throws {
        let (server, _, path) = try makeServer(maxConnections: 2)
        let a = try TestClient(path: path)
        let b = try TestClient(path: path)
        try a.hello()
        try b.hello()

        let third = try TestClient(path: path)
        XCTAssertTrue(third.waitForClose(), "the connection over the cap is dropped")
        XCTAssertEqual(server.activeConnections, 2)

        a.connection.close()
        XCTAssertTrue(eventually { server.activeConnections == 1 })
        let fourth = try TestClient(path: path)
        XCTAssertTrue(try fourth.hello().ok, "a slot is free again")
    }

    func testUnauthorizedUserGetsOneRefusalAndNothingElse() throws {
        try XCTSkipIf(geteuid() == 0, "root is always authorized")
        let config = HelperConfig(allowedUIDs: [])     // nobody but root
        let (server, h, path) = try makeServer(authorizer: ConfigPeerAuthorizer(config: config))
        let client = try TestClient(path: path)

        try client.send(.hello(proto: 1, client: "intruder"))
        let reply = try XCTUnwrap(try client.connection.readReply(timeout: 3))
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.err, .unauthorized)
        XCTAssertEqual(reply.id, 1)
        XCTAssertTrue(client.waitForClose())
        XCTAssertEqual(server.onCore { $0.connectionCount }, 0, "refused peers never reach the engine")
        XCTAssertTrue(h.smc.writes.isEmpty)
        XCTAssertTrue(logs.contains(.info, "REFUSED"))
    }

    func testAFloodOfRefusedPeersCannotCrowdOutAuthorizedOnes() throws {
        /// Refuses the first twelve connections, accepts the rest (deterministic, unlike flipping a flag).
        final class FirstN: PeerAuthorizer, @unchecked Sendable {
            private let lock = NSLock()
            private var calls = 0
            func authorize(_ connection: LineSocketConnection) -> PeerDecision {
                lock.lock(); defer { lock.unlock() }
                calls += 1
                return PeerDecision(allowed: calls > 12, reason: "test")
            }
        }
        let (_, _, path) = try makeServer(authorizer: FirstN(), maxConnections: 2)

        var intruders: [TestClient] = []
        for _ in 0..<12 { intruders.append(try TestClient(path: path)) }   // silent, like a flood

        let a = try TestClient(path: path)
        let b = try TestClient(path: path)
        XCTAssertTrue(try a.hello().ok)
        XCTAssertTrue(try b.hello().ok, "refused peers do not use up the authorized slots")
        withExtendedLifetime(intruders) {}
    }

    func testIdleClientsAreDroppedSoTheyCannotStarveEveryoneElse() throws {
        let (server, _, path) = try makeServer(helloTimeout: 0.3, idleTimeout: 0.6, maxConnections: 2)
        let a = try TestClient(path: path)
        let b = try TestClient(path: path)
        try a.hello()
        try b.hello()   // both say hello, then go silent
        XCTAssertTrue(a.waitForClose(), "no heartbeat for longer than the idle timeout: dropped")
        XCTAssertTrue(b.waitForClose())
        XCTAssertTrue(eventually { server.activeConnections == 0 })

        let c = try TestClient(path: path)
        XCTAssertTrue(try c.hello().ok, "the slots are free again")
    }

    func testAHeartbeatingClientIsNotDropped() throws {
        let (_, _, path) = try makeServer(helloTimeout: 0.3, idleTimeout: 0.6)
        let client = try TestClient(path: path)
        try client.hello()
        for _ in 0..<5 {
            Thread.sleep(forTimeInterval: 0.25)
            XCTAssertTrue(try client.call(.heartbeat(ttl: nil)).ok)
        }
    }

    func testRootKeepsTwoReservedSlotsWhenOrdinaryClientsFillTheCap() throws {
        /// uid 0 for the third and later connections, uid 501 for the first two.
        final class RootLast: PeerAuthorizer, @unchecked Sendable {
            private let lock = NSLock()
            private var calls = 0
            func authorize(_ connection: LineSocketConnection) -> PeerDecision {
                lock.lock(); defer { lock.unlock() }
                calls += 1
                return PeerDecision(allowed: true, uid: calls > 2 ? 0 : 501, reason: "test")
            }
        }
        let (server, _, path) = try makeServer(authorizer: RootLast(), maxConnections: 2)
        let a = try TestClient(path: path)
        let b = try TestClient(path: path)
        try a.hello()
        try b.hello()

        let root = try TestClient(path: path)
        XCTAssertTrue(try root.hello().ok, "root gets through although the cap is full")
        XCTAssertEqual(server.activeConnections, 3)
    }

    func testConnectionFloodIsLoggedOncePerSecondNotPerConnect() throws {
        let (_, _, path) = try makeServer()
        let before = logs.lines.count
        for _ in 0..<40 { _ = try TestClient(path: path) }
        Thread.sleep(forTimeInterval: 0.3)
        let connectionLines = logs.lines.dropFirst(before).filter { $0.1.hasPrefix("connection:") }.count
        XCTAssertLessThanOrEqual(connectionLines, 2, "40 connects must not produce 40 log lines")
    }

    func testLogThrottleCountsWhatItSwallowed() {
        var clock: TimeInterval = 100
        let throttle = LogThrottle(now: { clock })
        XCTAssertEqual(throttle.admit("a", every: 1), 0)
        XCTAssertNil(throttle.admit("a", every: 1))
        XCTAssertNil(throttle.admit("a", every: 1))
        XCTAssertEqual(throttle.admit("b", every: 1), 0, "keys are independent")
        clock += 1.5
        XCTAssertEqual(throttle.admit("a", every: 1), 2)
    }

    func testControlCharactersCannotForgeALogLine() {
        let hostile = "/tmp/x\n2026-10-14T21:30:00Z [CRITICAL] FAILSAFE: fake\u{1B}[2J\tkept"
        let safe = HelperLog.sanitized(hostile)
        XCTAssertFalse(safe.contains("\n"))
        XCTAssertFalse(safe.contains("\u{1B}"))
        XCTAssertTrue(safe.contains("\\x0A"))
        XCTAssertTrue(safe.contains("\t"), "tabs are harmless")
        XCTAssertEqual(HelperLog.sanitized("plain text"), "plain text")
    }

    func testListedUserIsAccepted() throws {
        let config = HelperConfig(allowedUIDs: [UInt32(getuid())])
        let (_, _, path) = try makeServer(authorizer: ConfigPeerAuthorizer(config: config))
        let client = try TestClient(path: path)
        XCTAssertTrue(try client.hello().ok)
        XCTAssertTrue(logs.contains(.info, "accepted"))
    }

    func testPinnedModeAcceptsOnlyAPinnedCodeDirectoryHash() throws {
        let ownHash = try XCTUnwrap(CodeSignature.cdhashOfCurrentProcess(), "this process has no code signature")
        let uid = UInt32(getuid())
        try XCTSkipIf(uid == 0, "pinned mode does not apply to root")

        // The peer is this very process, so its audit token (LOCAL_PEERTOKEN) resolves to our own cdhash.
        let pinned = HelperConfig(allowedUIDs: [uid], authMode: .pinned, pinnedCdhashes: [ownHash])
        let (_, _, goodPath) = try makeServer(authorizer: ConfigPeerAuthorizer(config: pinned))
        XCTAssertTrue(try TestClient(path: goodPath).hello().ok)
        XCTAssertTrue(logs.contains(.info, "pinned"))

        let wrong = HelperConfig(allowedUIDs: [uid], authMode: .pinned,
                                 pinnedCdhashes: [String(repeating: "ab", count: 20)])
        let (_, _, badPath) = try makeServer(authorizer: ConfigPeerAuthorizer(config: wrong))
        let intruder = try TestClient(path: badPath)
        try intruder.send(.hello(proto: 1, client: "t"))
        XCTAssertEqual(try intruder.connection.readReply(timeout: 3)?.err, .unauthorized)

        let empty = HelperConfig(allowedUIDs: [uid], authMode: .pinned, pinnedCdhashes: [])
        let (_, _, emptyPath) = try makeServer(authorizer: ConfigPeerAuthorizer(config: empty))
        let none = try TestClient(path: emptyPath)
        try none.send(.hello(proto: 1, client: "t"))
        XCTAssertEqual(try none.connection.readReply(timeout: 3)?.err, .unauthorized, "pinned with nothing pinned admits nobody")
    }

    func testPeerAuthorizerDecisions() throws {
        let (a, b) = try LineSocketConnection.makePair()
        defer { a.close(); b.close() }
        let me = UInt32(getuid())

        let allowed = ConfigPeerAuthorizer(config: HelperConfig(allowedUIDs: [me])).authorize(a)
        XCTAssertTrue(allowed.allowed)
        XCTAssertEqual(allowed.uid, me)
        XCTAssertEqual(allowed.pid, getpid())
        XCTAssertNotNil(ConfigPeerAuthorizer.processPath(pid: allowed.pid ?? 0))

        if me != 0 {
            let refused = ConfigPeerAuthorizer(config: HelperConfig(allowedUIDs: [me &+ 1])).authorize(a)
            XCTAssertFalse(refused.allowed)
            XCTAssertTrue(refused.reason.contains("allowedUIDs"))
        }
    }

    // MARK: Timers and shutdown

    func testIdleServerHasNoTimer() throws {
        let (server, _, path) = try makeServer()
        XCTAssertNil(server.maintenanceInterval, "nothing connected, nothing owned: no timer")

        let client = try TestClient(path: path)
        try client.hello()
        XCTAssertEqual(server.maintenanceInterval, 5)

        try client.call(.set(fan: 0, rpm: 3000, ttl: nil))
        XCTAssertEqual(server.maintenanceInterval, 1)

        try client.call(.auto(.all))
        XCTAssertEqual(server.maintenanceInterval, 5)

        client.connection.close()
        XCTAssertTrue(eventually { server.maintenanceInterval == nil }, "back to no timer after the last client leaves")
    }

    func testMaintenanceTimerActuallyRuns() throws {
        // Real time: the engine uses the fake clock, so only count the hot-set samples the tick takes.
        let hot = StubHotSet(45)
        let (_, _, path) = try makeServer(hot: hot)
        let client = try TestClient(path: path)
        try client.hello()
        try client.call(.set(fan: 0, rpm: 3000, ttl: nil))
        let before = hot.readCount
        XCTAssertTrue(eventually(timeout: 4) { hot.readCount > before }, "the 1 Hz tick samples the hot set")
    }

    func testShutdownReleasesFansClosesClientsAndRemovesTheSocket() throws {
        let (server, h, path) = try makeServer()
        let client = try TestClient(path: path)
        try client.hello()
        try client.call(.set(fan: 0, rpm: 3000, ttl: 15))

        server.shutdown(reason: "SIGTERM")

        XCTAssertEqual(h.smc.byte("F0md"), 0)
        XCTAssertTrue(client.waitForClose())
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "the socket file is removed")
        XCTAssertThrowsError(try TestClient(path: path))
        XCTAssertTrue(server.onCore { $0.isShuttingDown })
    }

    func testStartingTwiceOnTheSamePathIsRefused() throws {
        let (_, h, path) = try makeServer()
        let second = HelperServer(engine: h.engine, authorizer: AllowAllPeerAuthorizer(), socketPath: path)
        XCTAssertThrowsError(try second.start()) {
            XCTAssertEqual($0 as? LineSocketError, .addressInUse(path))
        }
        // The first server keeps working.
        XCTAssertTrue(try TestClient(path: path).hello().ok)
    }

    func testStaleSocketFileIsReplaced() throws {
        // A crashed daemon leaves its socket file behind; the next start must not trip over it.
        let path = "/tmp/fp-test-\(UUID().uuidString.prefix(8)).sock"
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: Array(path.utf8))
            raw[path.utf8.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        Darwin.close(fd)   // the file stays, nobody listens
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))

        let harness = EngineHarness()
        let server = HelperServer(engine: harness.engine, authorizer: AllowAllPeerAuthorizer(), socketPath: path)
        try server.start()
        servers.append(server)
        XCTAssertTrue(try TestClient(path: path).hello().ok)
    }

    func testARegularFileAtTheSocketPathIsNeverDeleted() throws {
        let path = "/tmp/fp-test-\(UUID().uuidString.prefix(8)).txt"
        FileManager.default.createFile(atPath: path, contents: Data("precious".utf8))
        defer { try? FileManager.default.removeItem(atPath: path) }

        let harness = EngineHarness()
        let server = HelperServer(engine: harness.engine, authorizer: AllowAllPeerAuthorizer(), socketPath: path)
        XCTAssertThrowsError(try server.start()) {
            XCTAssertEqual($0 as? LineSocketError, .notASocket(path))
        }
        XCTAssertEqual(try String(contentsOfFile: path), "precious", "the helper runs as root and must not unlink arbitrary files")
    }
}

final class TrustedConfigTests: XCTestCase {
    private var directory: String!

    override func setUpWithError() throws {
        directory = NSTemporaryDirectory() + "fp-config-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: directory)
    }

    private func write(_ json: String, mode: Int = 0o644) -> String {
        let path = directory + "/helper.json"
        FileManager.default.createFile(atPath: path, contents: Data(json.utf8), attributes: [.posixPermissions: mode])
        return path
    }

    func testLoadsAFileOwnedByTheTrustedUser() {
        let path = write(#"{"allowedUIDs":[501],"failsafeTempC":90,"leaseMaxSeconds":20}"#)
        let result = TrustedConfig.load(path: path, trustedUID: geteuid())
        XCTAssertNil(result.warning)
        XCTAssertEqual(result.config.allowedUIDs, [501])
        XCTAssertEqual(result.config.failsafeTempC, 90)
        XCTAssertEqual(result.config.leaseMaxSeconds, 20)
    }

    func testMissingFileMeansRootOnly() {
        let result = TrustedConfig.load(path: directory + "/nope.json", trustedUID: geteuid())
        XCTAssertNotNil(result.warning)
        XCTAssertEqual(result.config.allowedUIDs, [])
    }

    func testRefusesAFileThatOthersCanWrite() {
        let path = write(#"{"allowedUIDs":[501]}"#, mode: 0o666)
        chmod(path, 0o666)   // the umask may have trimmed the mode at creation
        let result = TrustedConfig.load(path: path, trustedUID: geteuid())
        XCTAssertNotNil(result.warning)
        XCTAssertEqual(result.config.allowedUIDs, [], "a tamperable config grants nothing")
    }

    func testRefusesAFileOwnedBySomeoneElse() {
        let path = write(#"{"allowedUIDs":[501]}"#)
        let result = TrustedConfig.load(path: path, trustedUID: geteuid() &+ 1)
        XCTAssertNotNil(result.warning)
        XCTAssertEqual(result.config.allowedUIDs, [])
    }

    func testRefusesAWritableDirectory() {
        let path = write(#"{"allowedUIDs":[501]}"#)
        chmod(directory, 0o777)
        let result = TrustedConfig.load(path: path, trustedUID: geteuid())
        XCTAssertNotNil(result.warning)
        XCTAssertEqual(result.config.allowedUIDs, [])
    }

    func testRefusesASymlink() throws {
        let real = write(#"{"allowedUIDs":[501]}"#)
        let link = directory + "/link.json"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
        let result = TrustedConfig.load(path: link, trustedUID: geteuid())
        XCTAssertNotNil(result.warning)
        XCTAssertEqual(result.config.allowedUIDs, [])
    }

    func testDamagedJSONFailsClosed() {
        let path = write("{ this is not json")
        let result = TrustedConfig.load(path: path, trustedUID: geteuid())
        XCTAssertEqual(result.config.allowedUIDs, [])
        XCTAssertEqual(result.config.authMode, .uid)
    }
}

final class HelperOptionsTests: XCTestCase {
    func testParse() throws {
        let o = try HelperOptions.parse(["--socket", "/tmp/x.sock", "--config", "/tmp/c.json", "--read-only", "-v"])
        XCTAssertEqual(o.socketPath, "/tmp/x.sock")
        XCTAssertEqual(o.configPath, "/tmp/c.json")
        XCTAssertTrue(o.readOnly)
        XCTAssertTrue(o.verbose)
        XCTAssertEqual(try HelperOptions.parse([]).configPath, Constants.helperConfigPath)
        XCTAssertFalse(try HelperOptions.parse([]).readOnly)
    }

    func testParseErrors() {
        XCTAssertThrowsError(try HelperOptions.parse(["--bogus"])) {
            XCTAssertEqual($0 as? HelperOptions.ParseError, .unknownOption("--bogus"))
        }
        XCTAssertThrowsError(try HelperOptions.parse(["--socket"])) {
            XCTAssertEqual($0 as? HelperOptions.ParseError, .missingValue("--socket"))
        }
    }
}

final class PowerEventsTests: XCTestCase {
    func testRegistersAndDeregistersCleanly() {
        let events = PowerEvents(onWillSleep: {}, onDidWake: {})
        XCTAssertTrue(events.start())
        XCTAssertTrue(events.start(), "idempotent")
        events.stop()
        events.stop()
    }
}

final class CodeSignatureTests: XCTestCase {
    /// The install script pins `codesign -dvvv` CDHash values; the helper compares what the Security
    /// framework reports. They must be the same number.
    func testCdhashOfAFileMatchesTheCodesignTool() throws {
        let executable = try XCTUnwrap(Bundle(for: CodeSignatureTests.self).executableURL)
        let ours = try XCTUnwrap(CodeSignature.cdhash(ofFileAt: executable), "the test bundle is not code signed")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-dvvv", executable.path]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = Pipe()
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        let line = try XCTUnwrap(output.split(separator: "\n").first { $0.hasPrefix("CDHash=") }, output)
        XCTAssertEqual(ours, String(line.dropFirst("CDHash=".count)))
    }

    func testCurrentProcessHasACdhash() {
        let hash = CodeSignature.cdhashOfCurrentProcess()
        XCTAssertNotNil(hash)
        XCTAssertEqual(hash?.count, 40, "a SHA-1/truncated SHA-256 cdhash is 20 bytes")
    }

    func testGarbageAuditTokensAreRejected() {
        XCTAssertNil(CodeSignature.cdhash(auditToken: Data(repeating: 0xFF, count: 32)))
        XCTAssertNil(CodeSignature.cdhash(auditToken: Data()))
    }
}
