import Foundation
import XCTest
@testable import FanPilotKit

/// Thread-safe collector for callbacks that run on other queues.
private final class Collector<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func add(_ item: T) { lock.lock(); items.append(item); lock.unlock() }
    var all: [T] { lock.lock(); defer { lock.unlock() }; return items }
}

final class LineSocketTests: XCTestCase {
    private func temporarySocketPath() -> String {
        // Unix socket paths are limited to 104 bytes; NSTemporaryDirectory() is short enough.
        NSTemporaryDirectory() + "fp-\(UUID().uuidString.prefix(8)).sock"
    }

    func testPairExchangesLines() throws {
        let (a, b) = try LineSocketConnection.makePair()
        try a.writeLine(Data("hello".utf8))
        try a.writeLine(Data("world".utf8))
        XCTAssertEqual(try b.readLine(timeout: 2), Data("hello".utf8))
        XCTAssertEqual(try b.readLine(timeout: 2), Data("world".utf8))
    }

    func testCoalescedWritesAreSplitIntoLines() throws {
        let (a, b) = try LineSocketConnection.makePair()
        for i in 0..<200 { try a.writeLine(Data("line-\(i)".utf8)) }
        for i in 0..<200 { XCTAssertEqual(try b.readLine(timeout: 2), Data("line-\(i)".utf8)) }
    }

    func testEOFReturnsNilAfterPendingLines() throws {
        let (a, b) = try LineSocketConnection.makePair()
        try a.writeLine(Data("last".utf8))
        a.close()
        XCTAssertEqual(try b.readLine(timeout: 2), Data("last".utf8))
        XCTAssertNil(try b.readLine(timeout: 2))
        XCTAssertNil(try b.readLine(timeout: 2), "EOF is sticky")
    }

    func testReadTimeout() throws {
        let (a, b) = try LineSocketConnection.makePair()   // keep `a` alive: dropping it would close the peer
        defer { a.close() }
        let start = Date()
        XCTAssertThrowsError(try b.readLine(timeout: 0.15)) { XCTAssertEqual($0 as? LineSocketError, .timeout) }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.1)
    }

    func testOverlongLineFailsTheConnection() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let reader = LineSocketConnection(fd: fds[1], maxLineBytes: 64)
        let writer = LineSocketConnection(fd: fds[0], maxLineBytes: 1_000_000)
        try writer.writeLine(Data(repeating: 0x41, count: 500))
        XCTAssertThrowsError(try reader.readLine(timeout: 2)) {
            XCTAssertEqual($0 as? LineSocketError, .lineTooLong(limit: 64))
        }
    }

    func testWriteRejectsEmbeddedNewlineAndOversize() throws {
        let (a, b) = try LineSocketConnection.makePair()
        defer { b.close() }
        XCTAssertThrowsError(try a.writeLine(Data("a\nb".utf8))) { XCTAssertEqual($0 as? LineSocketError, .invalidLine) }
        XCTAssertThrowsError(try a.writeLine(Data(repeating: 0x41, count: Constants.maxLineBytes + 1)))
    }

    func testWriteToClosedPeerThrowsInsteadOfRaisingSIGPIPE() throws {
        let (a, b) = try LineSocketConnection.makePair()
        b.close()
        var thrown = false
        for _ in 0..<50 {
            do { try a.writeLine(Data("x".utf8)) } catch { thrown = true; break }
        }
        XCTAssertTrue(thrown)   // reaching this line at all means SIGPIPE did not kill the process
    }

    func testPeerCredentialsIdentifyThisProcess() throws {
        let (a, b) = try LineSocketConnection.makePair()
        defer { b.close() }
        let creds = try XCTUnwrap(a.peerCredentials())
        XCTAssertEqual(creds.uid, getuid())
        XCTAssertEqual(creds.pid, getpid())
    }

    func testShutdownUnblocksAReader() throws {
        let (a, b) = try LineSocketConnection.makePair()
        let done = expectation(description: "reader returned")
        DispatchQueue.global().async {
            let line = try? b.readLine()
            XCTAssertNil(line ?? nil)
            done.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.1)
        b.shutdown()
        wait(for: [done], timeout: 2)
        _ = a
    }

    func testStartReadingDeliversLinesThenCloses() throws {
        let (a, b) = try LineSocketConnection.makePair()
        let received = Collector<String>()
        let closed = expectation(description: "closed")
        b.startReading(onLine: { line in
            received.add(String(decoding: line, as: UTF8.self))
        }, onClose: { error in
            XCTAssertNil(error)
            closed.fulfill()
        })
        try a.writeLine(Data("one".utf8))
        try a.writeLine(Data("two".utf8))
        a.close()
        wait(for: [closed], timeout: 2)
        XCTAssertEqual(received.all, ["one", "two"])
    }

    // MARK: Server

    func testServerClientRoundTripOfWireMessages() throws {
        let path = temporarySocketPath()
        let server = LineSocketServer(path: path)
        try server.start()
        defer { server.stop() }

        var info = stat()
        XCTAssertEqual(stat(path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o666)

        let client = try LineSocketConnection.connect(path: path)
        let peer = try XCTUnwrap(try server.accept(timeout: 2))

        try client.sendRequest(WireRequest(id: 1, command: .hello(proto: 1, client: "test")))
        let request = try XCTUnwrap(try peer.readRequest(timeout: 2))
        XCTAssertEqual(request, WireRequest(id: 1, command: .hello(proto: 1, client: "test")))
        XCTAssertEqual(peer.peerCredentials()?.uid, getuid())

        try peer.sendReply(.success(id: 1, body: .heartbeat(owned: [0, 1])))
        let reply = try XCTUnwrap(try client.readReply(timeout: 2))
        XCTAssertEqual(reply.body, .heartbeat(owned: [0, 1]))
    }

    func testAcceptTimesOutWithoutClients() throws {
        let path = temporarySocketPath()
        let server = LineSocketServer(path: path)
        try server.start()
        defer { server.stop() }
        XCTAssertNil(try server.accept(timeout: 0.1))
    }

    func testGCDAcceptDeliversConnections() throws {
        let path = temporarySocketPath()
        let server = LineSocketServer(path: path)
        try server.start()
        defer { server.stop() }

        let accepted = expectation(description: "accepted")
        accepted.expectedFulfillmentCount = 3
        server.startAccepting(on: DispatchQueue(label: "test.accept")) { connection in
            connection.close()
            accepted.fulfill()
        }
        let clients = try (0..<3).map { _ in try LineSocketConnection.connect(path: path) }
        wait(for: [accepted], timeout: 3)
        clients.forEach { $0.close() }
    }

    func testStopRemovesSocketFile() throws {
        let path = temporarySocketPath()
        let server = LineSocketServer(path: path)
        try server.start()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertThrowsError(try LineSocketConnection.connect(path: path))
    }

    /// Leaves behind a socket file that nothing listens on, like a crashed daemon would.
    private func makeStaleSocketFile(at path: String) {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: Array(path.utf8))
            raw[path.utf8.count] = 0
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(result, 0)
        Darwin.close(fd)      // the file stays; no listener
    }

    func testStartReplacesStaleSocketButNotLiveOnesOrRegularFiles() throws {
        let stalePath = temporarySocketPath()
        makeStaleSocketFile(at: stalePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stalePath))
        XCTAssertThrowsError(try LineSocketConnection.connect(path: stalePath))

        let live = LineSocketServer(path: stalePath)
        XCTAssertNoThrow(try live.start(), "a stale socket file is replaced")
        defer { live.stop() }
        XCTAssertNoThrow(try LineSocketConnection.connect(path: stalePath))

        // A second server must not steal the path from a live one.
        XCTAssertThrowsError(try LineSocketServer(path: stalePath).start()) {
            XCTAssertEqual($0 as? LineSocketError, .addressInUse(stalePath))
        }
        XCTAssertNoThrow(try LineSocketConnection.connect(path: stalePath), "the live server is still reachable")

        // A regular file is never deleted (the helper runs as root).
        let filePath = temporarySocketPath()
        FileManager.default.createFile(atPath: filePath, contents: Data("precious".utf8))
        defer { try? FileManager.default.removeItem(atPath: filePath) }
        XCTAssertThrowsError(try LineSocketServer(path: filePath).start()) {
            XCTAssertEqual($0 as? LineSocketError, .notASocket(filePath))
        }
        XCTAssertEqual(try String(contentsOfFile: filePath, encoding: .utf8), "precious")
    }

    func testOverlongPathIsRejected() {
        let path = "/tmp/" + String(repeating: "a", count: 200)
        XCTAssertThrowsError(try LineSocketConnection.connect(path: path)) {
            XCTAssertEqual($0 as? LineSocketError, .pathTooLong(path))
        }
    }

    func testConnectToMissingSocketFails() {
        let path = temporarySocketPath()
        XCTAssertThrowsError(try LineSocketConnection.connect(path: path)) {
            guard case .connectFailed(let p, _)? = $0 as? LineSocketError else { return XCTFail("\($0)") }
            XCTAssertEqual(p, path)
        }
    }
}
