import XCTest
@testable import Motif

/// Lock the HTTP head rewriting in TailscaleProxy. The proxy is a byte
/// pump otherwise, so this transform is the only place where a bug could
/// silently corrupt protocol traffic — and motifd will reject auth on the
/// next round-trip if we got the Authorization header wrong.
final class TailscaleProxyTests: XCTestCase {
    func testInjectsAuthorizationOnPlainGet() throws {
        let head = Data("""
        GET /api/things HTTP/1.1\r
        Host: dev.tail.ts.net\r
        User-Agent: Test\r
        \r

        """.replacingOccurrences(of: "\n", with: "").utf8) + Data("\r\n\r\n".utf8)

        // The fixture above is awkward to type; rebuild plainly:
        let plain = Data([
            "GET /api/things HTTP/1.1",
            "Host: dev.tail.ts.net",
            "User-Agent: Test",
            "", ""
        ].joined(separator: "\r\n").utf8)

        let out = try TailscaleProxy.injectAuthorization(into: plain, token: "tk-1234")
        let outString = String(data: out, encoding: .utf8)!
        XCTAssertTrue(outString.contains("Authorization: Bearer tk-1234"))
        XCTAssertTrue(outString.hasPrefix("GET /api/things HTTP/1.1"))
        XCTAssertTrue(outString.hasSuffix("\r\n\r\n"))
        // Ensure no duplicate Authorization headers.
        XCTAssertEqual(outString.components(separatedBy: "Authorization:").count, 2)
        _ = head // silence unused
    }

    func testReplacesExistingAuthorization() throws {
        let plain = Data([
            "GET /ws HTTP/1.1",
            "Host: dev.tail.ts.net",
            "Authorization: Bearer old-token",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "", ""
        ].joined(separator: "\r\n").utf8)

        let out = try TailscaleProxy.injectAuthorization(into: plain, token: "new-token")
        let outString = String(data: out, encoding: .utf8)!
        XCTAssertFalse(outString.contains("old-token"), "old token must be stripped")
        XCTAssertTrue(outString.contains("Authorization: Bearer new-token"))
        XCTAssertTrue(outString.contains("Upgrade: websocket"))
        XCTAssertEqual(outString.components(separatedBy: "Authorization:").count, 2)
    }

    func testPreservesBodyAfterHeaders() throws {
        let bodyBytes = Data([0x00, 0xFF, 0x42, 0x99])
        var pending = Data([
            "PUT /blob/abc HTTP/1.1",
            "Host: dev.tail.ts.net",
            "Content-Length: 4",
            "", ""
        ].joined(separator: "\r\n").utf8)
        pending.append(bodyBytes)

        let out = try TailscaleProxy.injectAuthorization(into: pending, token: "tk")
        // The trailing 4 bytes must survive verbatim.
        XCTAssertEqual(out.suffix(4), bodyBytes)
    }

    func testCaseInsensitiveStripsExistingHeader() throws {
        let plain = Data([
            "GET /ws HTTP/1.1",
            "Host: dev.tail.ts.net",
            "AUTHORIZATION: Basic abc",   // wrong case + wrong scheme
            "", ""
        ].joined(separator: "\r\n").utf8)

        let out = try TailscaleProxy.injectAuthorization(into: plain, token: "right")
        let outString = String(data: out, encoding: .utf8)!
        XCTAssertFalse(outString.contains("Basic abc"))
        XCTAssertTrue(outString.contains("Authorization: Bearer right"))
    }

    func testRejectsHeadWithoutTerminator() {
        let bad = Data("GET / HTTP/1.1\r\nHost: x".utf8) // no \r\n\r\n
        XCTAssertThrowsError(try TailscaleProxy.injectAuthorization(into: bad, token: "x"))
    }
}
