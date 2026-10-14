import XCTest
@testable import FanPilotKit

final class WireTests: XCTestCase {
    private func roundTrip(_ request: WireRequest, file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try WireCodec.encode(request)
        XCTAssertFalse(data.contains(0x0A), "a line must not contain a raw newline", file: file, line: line)
        XCTAssertEqual(try WireCodec.decodeRequest(data), request, file: file, line: line)
    }

    private func json(_ value: some Encodable) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: try WireCodec.encode(value)) as! [String: Any]
    }

    // MARK: Requests

    func testEveryRequestRoundTrips() throws {
        try roundTrip(WireRequest(id: 1, command: .hello(proto: 1, client: "FanPilot")))
        try roundTrip(WireRequest(id: 2, command: .status))
        try roundTrip(WireRequest(id: 3, command: .set(fan: 0, rpm: 3000, ttl: 15)))
        try roundTrip(WireRequest(id: 4, command: .set(fan: 1, rpm: 2500.5, ttl: nil)))
        try roundTrip(WireRequest(id: 5, command: .setAll(rpms: [3000, nil], ttl: 10)))
        try roundTrip(WireRequest(id: 6, command: .auto(.all)))
        try roundTrip(WireRequest(id: 7, command: .auto(.fan(1))))
        try roundTrip(WireRequest(id: 8, command: .heartbeat(ttl: 15)))
        try roundTrip(WireRequest(id: 9, command: .heartbeat(ttl: nil)))
        try roundTrip(WireRequest(id: 10, command: .bye))
    }

    func testRequestJSONShapeMatchesSpec() throws {
        let set = try json(WireRequest(id: 7, command: .set(fan: 0, rpm: 3000, ttl: 15)))
        XCTAssertEqual(set["id"] as? Int, 7)
        XCTAssertEqual(set["op"] as? String, "set")
        XCTAssertEqual(set["fan"] as? Int, 0)
        XCTAssertEqual(set["rpm"] as? Double, 3000)
        XCTAssertEqual(set["ttl"] as? Double, 15)

        let auto = try json(WireRequest(id: 8, command: .auto(.all)))
        XCTAssertEqual(auto["fan"] as? String, "all")
        let autoOne = try json(WireRequest(id: 9, command: .auto(.fan(1))))
        XCTAssertEqual(autoOne["fan"] as? Int, 1)

        let setAll = try json(WireRequest(id: 1, command: .setAll(rpms: [2000, nil], ttl: nil)))
        XCTAssertEqual(setAll["op"] as? String, "setAll")
        XCTAssertEqual((setAll["rpms"] as? [Any])?.count, 2)
        XCTAssertTrue((setAll["rpms"] as? [Any])?[1] is NSNull)
    }

    func testHandWrittenRequestsDecode() throws {
        // What someone would type into `nc -U`.
        XCTAssertEqual(try WireCodec.decodeRequest(Data(#"{"id":1,"op":"hello","proto":1,"client":"nc"}"#.utf8)),
                       WireRequest(id: 1, command: .hello(proto: 1, client: "nc")))
        XCTAssertEqual(try WireCodec.decodeRequest(Data(#"{"op":"auto","id":4}"#.utf8) ),
                       WireRequest(id: 4, command: .auto(.all)), "auto without fan means all")
        XCTAssertEqual(try WireCodec.decodeRequest(Data("{\"id\":2,\"op\":\"set\",\"fan\":1,\"rpm\":3000}\r\n".utf8)),
                       WireRequest(id: 2, command: .set(fan: 1, rpm: 3000, ttl: nil)))
        // Unknown extra keys are ignored.
        XCTAssertEqual(try WireCodec.decodeRequest(Data(#"{"id":3,"op":"status","future":true}"#.utf8)),
                       WireRequest(id: 3, command: .status))
    }

    func testMalformedRequestsAreRejected() {
        let bad = [
            "", "   ", "not json", "[]", "{}",
            #"{"id":1}"#,
            #"{"id":1,"op":"explode"}"#,
            #"{"id":1,"op":"set","fan":0}"#,                    // rpm missing
            #"{"id":1,"op":"set","fan":"0","rpm":1}"#,          // wrong type
            #"{"id":1,"op":"set","fan":0,"rpm":"fast"}"#,
            #"{"id":"x","op":"status"}"#,
            #"{"id":1,"op":"auto","fan":"left"}"#,
            #"{"id":1,"op":"hello"}"#,                           // proto missing
        ]
        for text in bad {
            XCTAssertThrowsError(try WireCodec.decodeRequest(Data(text.utf8)), "should reject: \(text)")
        }
    }

    func testPeekIDRecoversIDFromBrokenRequests() {
        XCTAssertEqual(WireCodec.peekID(Data(#"{"id":42,"op":"explode"}"#.utf8)), 42)
        XCTAssertNil(WireCodec.peekID(Data("garbage".utf8)))
        XCTAssertNil(WireCodec.peekID(Data(#"{"op":"status"}"#.utf8)))
    }

    func testValidationRejectsNonsenseNumbers() throws {
        func invalid(_ command: WireCommand, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertThrowsError(try WireRequest(id: 1, command: command).validate(), file: file, line: line) {
                XCTAssertTrue($0 is WireError, file: file, line: line)
            }
        }
        try WireRequest(id: 1, command: .set(fan: 0, rpm: 3000, ttl: 15)).validate()
        try WireRequest(id: 1, command: .set(fan: 9, rpm: 0, ttl: nil)).validate()
        try WireRequest(id: 1, command: .setAll(rpms: [nil, 2000], ttl: nil)).validate()
        try WireRequest(id: 1, command: .auto(.fan(1))).validate()

        invalid(.set(fan: -1, rpm: 3000, ttl: nil))
        invalid(.set(fan: 10, rpm: 3000, ttl: nil))
        invalid(.set(fan: 0, rpm: -1, ttl: nil))
        invalid(.set(fan: 0, rpm: .nan, ttl: nil))
        invalid(.set(fan: 0, rpm: .infinity, ttl: nil))
        invalid(.set(fan: 0, rpm: 1e9, ttl: nil))
        invalid(.set(fan: 0, rpm: 3000, ttl: 0))
        invalid(.set(fan: 0, rpm: 3000, ttl: -5))
        invalid(.set(fan: 0, rpm: 3000, ttl: .nan))
        invalid(.set(fan: 0, rpm: 3000, ttl: 1e6))
        invalid(.setAll(rpms: [], ttl: nil))
        invalid(.setAll(rpms: [Double?](repeating: 1000, count: 11), ttl: nil))
        invalid(.setAll(rpms: [.nan], ttl: nil))
        invalid(.auto(.fan(12)))
        invalid(.heartbeat(ttl: 0))
        invalid(.hello(proto: 0, client: "x"))
    }

    // MARK: Replies

    private let sampleFans = [
        FanInfo(index: 0, name: "Left Side", minRPM: 1350, maxRPM: 5349, backend: .appleSiliconMd(modeKey: "F0md")),
        FanInfo(index: 1, name: "Right Side", minRPM: 1350, maxRPM: 5777, backend: .appleSiliconMd(modeKey: "F1md"), hasFtst: true),
    ]

    func testEveryReplyRoundTrips() throws {
        let replies: [WireReply] = [
            .success(id: 1, body: .hello(HelloReply(fans: sampleFans, failsafeTempC: 95, leaseMaxS: 30,
                                                    monitorOnly: false))),
            .success(id: 1, body: .hello(HelloReply(fans: [], failsafeTempC: 95, leaseMaxS: 30,
                                                    monitorOnly: true, monitorReason: "no usable fan backend"))),
            .success(id: 2, body: .status(StatusReply(
                fans: [FanStatus(index: 0, actualRPM: 2400, targetRPM: 2500, mode: 1, minRPM: 1350,
                                 maxRPM: 5349, owned: true, leaseRemainS: 12.5)],
                failsafe: FailsafeStatus(active: true, reason: "hot_sensor", tempC: 96.5),
                lastError: "mode_rejected", dict: 0))),
            .success(id: 3, body: .set(SetReply(applied: 5349, clamped: true))),
            .success(id: 4, body: .setAll([SetReply(applied: 2000, clamped: false), nil])),
            .success(id: 5, body: .auto(released: [0, 1])),
            .success(id: 6, body: .heartbeat(owned: [1])),
            .success(id: 7, body: .bye),
            .failure(id: 8, op: .set, code: .failsafeActive, message: "failsafe", forcedRPM: 5349),
            .failure(id: 0, op: nil, code: .badRequest, message: "unparseable"),
        ]
        for reply in replies {
            let data = try WireCodec.encode(reply)
            XCTAssertEqual(try WireCodec.decodeReply(data), reply, String(decoding: data, as: UTF8.self))
        }
    }

    func testHelloReplyJSONShapeMatchesSpec() throws {
        let reply = WireReply.success(id: 1, body: .hello(HelloReply(fans: sampleFans, failsafeTempC: 95,
                                                                     leaseMaxS: 30, monitorOnly: false)))
        let object = try json(reply)
        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertEqual(object["id"] as? Int, 1)
        XCTAssertEqual(object["failsafeTempC"] as? Double, 95)
        XCTAssertEqual(object["leaseMaxS"] as? Double, 30)
        XCTAssertEqual(object["monitorOnly"] as? Bool, false)
        let fan = (object["fans"] as? [[String: Any]])?.first
        XCTAssertEqual(fan?["index"] as? Int, 0)
        XCTAssertEqual(fan?["name"] as? String, "Left Side")
        XCTAssertEqual(fan?["minRPM"] as? Double, 1350)
        XCTAssertEqual(fan?["maxRPM"] as? Double, 5349)
        XCTAssertEqual(fan?["backend"] as? String, "appleSiliconMd")
        XCTAssertEqual(fan?["modeKey"] as? String, "F0md")
        XCTAssertEqual(fan?["hasFtst"] as? Bool, false)
    }

    func testErrorReplyJSONShapeMatchesSpec() throws {
        let object = try json(WireReply.failure(id: 5, op: .set, code: .noSuchFan, message: "no fan 7"))
        XCTAssertEqual(object["ok"] as? Bool, false)
        XCTAssertEqual(object["err"] as? String, "no_such_fan")
        XCTAssertEqual(object["msg"] as? String, "no fan 7")
        XCTAssertEqual(object["id"] as? Int, 5)
    }

    func testAllErrorCodesUseSpecNames() {
        XCTAssertEqual(Set(WireErrorCode.allCases.filter { $0 != .unknown }.map(\.rawValue)),
                       ["bad_request", "unauthorized", "no_such_fan", "monitor_only",
                        "mode_rejected", "target_rejected", "failsafe_active", "io_error"])
    }

    func testUnknownErrorCodeAndUnknownKeysDecodeTolerantly() throws {
        let reply = try WireCodec.decodeReply(Data(#"{"id":3,"ok":false,"err":"from_the_future","msg":"hm","extra":1}"#.utf8))
        XCTAssertEqual(reply.err, .unknown)
        XCTAssertEqual(reply.msg, "hm")
        XCTAssertFalse(reply.ok)
    }

    func testOkReplyWithoutOpHasEmptyBody() throws {
        let reply = try WireCodec.decodeReply(Data(#"{"id":3,"ok":true}"#.utf8))
        XCTAssertEqual(reply.body, .none)
    }

    // MARK: Lines

    func testEncodeLineAppendsExactlyOneNewline() throws {
        let line = try WireCodec.encodeLine(WireRequest(id: 1, command: .status))
        XCTAssertEqual(line.last, 0x0A)
        XCTAssertEqual(line.filter { $0 == 0x0A }.count, 1)
    }

    func testStringsWithNewlinesAreEscaped() throws {
        let line = try WireCodec.encodeLine(WireReply.failure(id: 1, op: nil, code: .badRequest, message: "a\nb\r\nc"))
        XCTAssertEqual(line.filter { $0 == 0x0A }.count, 1)
        let back = try WireCodec.decodeReply(line)
        XCTAssertEqual(back.msg, "a\nb\r\nc")
    }

    func testLineCapIsEnforcedOnEncodeAndDecode() throws {
        let huge = String(repeating: "x", count: Constants.maxLineBytes)
        XCTAssertThrowsError(try WireCodec.encode(WireReply.failure(id: 1, op: nil, code: .ioError, message: huge))) {
            XCTAssertEqual($0 as? WireError, .lineTooLong(limit: Constants.maxLineBytes))
        }
        let fits = String(repeating: "x", count: 1000)
        XCTAssertNoThrow(try WireCodec.encode(WireReply.failure(id: 1, op: nil, code: .ioError, message: fits)))
        XCTAssertThrowsError(try WireCodec.decodeReply(Data(repeating: 0x20, count: 10) + Data(huge.utf8) + Data(huge.utf8)))
    }

    func testFramerSplitsAndReassembles() throws {
        var framer = LineFramer()
        XCTAssertEqual(try framer.append(Data("{\"a\":".utf8)), [])
        XCTAssertEqual(framer.pendingBytes, 5)
        let lines = try framer.append(Data("1}\n{\"b\":2}\r\n\n{\"c\"".utf8))
        XCTAssertEqual(lines.map { String(decoding: $0, as: UTF8.self) }, ["{\"a\":1}", "{\"b\":2}"])
        XCTAssertEqual(try framer.append(Data(":3}\n".utf8)).map { String(decoding: $0, as: UTF8.self) }, ["{\"c\":3}"])
        XCTAssertEqual(framer.pendingBytes, 0)
    }

    func testFramerHandlesByteAtATime() throws {
        var framer = LineFramer()
        var got: [String] = []
        for byte in Array("one\ntwo\n".utf8) {
            got += try framer.append(Data([byte])).map { String(decoding: $0, as: UTF8.self) }
        }
        XCTAssertEqual(got, ["one", "two"])
    }

    func testFramerRejectsOverlongLines() {
        var framer = LineFramer(maxLineBytes: 16)
        XCTAssertNoThrow(try framer.append(Data("0123456789abcdef\n".utf8)))      // exactly 16 is fine
        XCTAssertThrowsError(try framer.append(Data("0123456789abcdefg\n".utf8))) {      // complete but 17
            XCTAssertEqual($0 as? WireError, .lineTooLong(limit: 16))
        }
        var streaming = LineFramer(maxLineBytes: 16)
        XCTAssertNoThrow(try streaming.append(Data("0123456789".utf8)))
        XCTAssertThrowsError(try streaming.append(Data("0123456789".utf8)), "no newline yet and already over the cap")
    }
}
