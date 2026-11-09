import Foundation
import XCTest
@testable import F50Core

private final class RouterFixture {
    let lock = NSLock()
    var mode = "WL_AND_5G"
    var rejectLogin = false
    var rejectStatus = false
    var delayLockReply = false
    private var forms: [[String: String]] = []
    private var lockReads = 0

    var postedForms: [[String: String]] {
        lock.lock(); defer { lock.unlock() }
        return forms
    }
    var lockReadCount: Int {
        lock.lock(); defer { lock.unlock() }
        return lockReads
    }

    func reply(to request: URLRequest) -> (Int, [String: String], [String: Any], Double) {
        lock.lock(); defer { lock.unlock() }
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let command = query.first { $0.name == "cmd" }?.value ?? ""
        if request.httpMethod == "POST" {
            var data = request.httpBody ?? Data()
            if data.isEmpty, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count > 0 else { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
            }
            let body = String(data: data, encoding: .utf8) ?? ""
            let items = URLComponents(string: "http://fixture.test/?\(body)")?.queryItems ?? []
            let form = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
            forms.append(form)
            switch form["goformId"] {
            case "LOGIN":
                return (200, ["Set-Cookie": "stok=fixture-session; Path=/"], ["result": rejectLogin ? "3" : "0"], 0)
            case "SET_BEARER_PREFERENCE":
                guard request.value(forHTTPHeaderField: "Cookie")?.contains("stok=fixture-session") == true else {
                    return (200, [:], ["result": "failure"], 0)
                }
                mode = form["BearerPreference"] ?? mode
                return (200, [:], ["result": "success"], 0)
            default: return (200, [:], ["result": "failure"], 0)
            }
        }
        if command.contains("psw_fail_num_str") {
            lockReads += 1
            return (200, [:], ["psw_fail_num_str": "5", "login_lock_time": "0"], delayLockReply ? 0.1 : 0)
        }
        if command == "LD" { return (200, [:], ["LD": "fixture-ld"], 0) }
        if command == "RD" { return (200, [:], ["RD": "fixture-rd"], 0) }
        if command.contains("sms_data_total") { return (200, [:], ["messages": []], 0) }
        if rejectStatus { return (401, [:], ["Error": "none secure connection"], 0) }
        return (200, [:], [
            "network_net_select": mode, "network_type": "4G", "ppp_status": "ipv4_ipv6_connected",
            "wa_inner_version": "F50ProV1.0.0B28", "cr_version": "MU3356V1.0.0B28",
            "cpu_utility": "10", "mem_utility": "20", "cpu_temperature": "40"
        ], 0)
    }
}

private final class RouterURLProtocol: URLProtocol {
    // Tests use an ephemeral session with this protocol; no requests reach a real device.
    static var fixture: RouterFixture!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, headers, payload, delay) = Self.fixture.reply(to: request)
        let respond = { [self] in
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: payload))
            client?.urlProtocolDidFinishLoading(self)
        }
        if delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: respond)
        } else {
            respond()
        }
    }
    override func stopLoading() {}
}

@MainActor
final class F50NetworkModeFetcherTests: XCTestCase {
    private func makeFetcher(_ fixture: RouterFixture, automaticallyRefresh: Bool = false,
                             load: @escaping () -> String = { "saved-password" },
                             save: @escaping (String) -> Void = { _ in }) -> F50Fetcher {
        RouterURLProtocol.fixture = fixture
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RouterURLProtocol.self]
        return F50Fetcher(session: URLSession(configuration: config), automaticallyRefresh: automaticallyRefresh,
                          loadPassword: load, savePassword: save)
    }

    func testStartupLoadsSavedPasswordAndUsesItForAutomaticLogin() async {
        let fixture = RouterFixture()
        fixture.rejectStatus = true
        var loads = 0
        let fetcher = makeFetcher(fixture, automaticallyRefresh: true, load: { loads += 1; return "saved" })
        await fetcher.fetchDataAsync()
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(fetcher.password, "saved")
        XCTAssertEqual(fixture.postedForms.compactMap { $0["goformId"] }, ["LOGIN"])
    }

    func testLoadingSavedPasswordPreservesModeAndTrafficWithoutSavingAgain() async {
        let fixture = RouterFixture()
        var loads = 0
        var saves = 0
        let fetcher = makeFetcher(fixture, load: { loads += 1; return "saved" }, save: { _ in saves += 1 })
        await fetcher.fetchDataAsync()
        fetcher.status.monthlyRx = 12345
        XCTAssertEqual(fetcher.password, "saved")
        XCTAssertEqual(fetcher.networkMode, .automatic)
        XCTAssertEqual(fetcher.status.monthlyRx, 12345)
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(saves, 0)
        XCTAssertTrue(fixture.postedForms.isEmpty)
    }

    func testLoginThenSwitchConfirmsConfigurationAndReusesSession() async throws {
        let fixture = RouterFixture()
        let fetcher = makeFetcher(fixture)
        await fetcher.fetchDataAsync()
        try await fetcher.setNetworkMode(.lteOnly)
        XCTAssertEqual(fetcher.networkMode, .lteOnly)
        XCTAssertEqual(fixture.postedForms.compactMap { $0["goformId"] }, ["LOGIN", "SET_BEARER_PREFERENCE"])
        XCTAssertEqual(fixture.postedForms.last?["BearerPreference"], "Only_LTE")
        XCTAssertFalse(fetcher.isSwitchingNetworkMode)
    }

    func testRejectedPasswordIsNotRetriedByPollingOrSwitchAttempts() async {
        let fixture = RouterFixture()
        fixture.rejectLogin = true
        let fetcher = makeFetcher(fixture)
        await fetcher.fetchDataAsync()
        for _ in 0..<2 {
            do {
                try await fetcher.setNetworkMode(.lteOnly)
                XCTFail("Expected login failure")
            } catch F50MobileDataError.loginFailed {
                // Expected: the second submission must not consume another login attempt.
            } catch { XCTFail("Unexpected error: \(error)") }
            await fetcher.fetchDataAsync()
        }
        XCTAssertEqual(fixture.postedForms.compactMap { $0["goformId"] }, ["LOGIN"])
    }

    func testChangedPasswordCancelsSwitchLoginAndBlocksConcurrentDataToggle() async throws {
        let fixture = RouterFixture()
        let fetcher = makeFetcher(fixture)
        fetcher.password = "first-password"
        await fetcher.fetchDataAsync()
        fixture.delayLockReply = true
        let switching = Task { try await fetcher.setNetworkMode(.lteOnly) }
        for _ in 0..<100 where fixture.lockReadCount == 0 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(fetcher.isSwitchingNetworkMode)
        do {
            try await fetcher.setMobileData(enabled: false)
            XCTFail("Expected busy error")
        } catch F50NetworkModeError.busy {} catch { XCTFail("Unexpected error: \(error)") }
        fetcher.password = "changed-password"
        do {
            try await switching.value
            XCTFail("Expected cancellation after configuration change")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(fixture.postedForms.isEmpty)
        XCTAssertFalse(fetcher.isSwitchingNetworkMode)
    }
}
