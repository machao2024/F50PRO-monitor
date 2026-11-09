import Foundation
import XCTest
@testable import F50Core

final class F50NetworkModeTests: XCTestCase {
    func testB28ModesMatchDeviceConfiguration() {
        let modes: [(String, F50NetworkMode)] = [
            ("WL_AND_5G", .automatic), ("Only_LTE", .lteOnly),
            ("Only_5G", .sa), ("LTE_AND_5G", .nsa),
            ("WCDMA_AND_LTE", .lteAnd3G), ("Only_WCDMA", .wcdmaOnly)
        ]
        for (value, mode) in modes {
            XCTAssertEqual(F50ResponseParser.parseNetworkMode(["network_net_select": value]), mode)
            XCTAssertEqual(F50ResponseParser.buildNetworkModeRequestBody(mode: mode, ad: "AD1"),
                           "isTest=false&goformId=SET_BEARER_PREFERENCE&BearerPreference=\(value)&AD=AD1")
        }
        XCTAssertEqual(F50NetworkMode(rawValue: "Only_5G")?.title, "5G SA")
    }

    func testConfiguredModeIsIndependentOfActualNetwork() {
        XCTAssertEqual(F50ResponseParser.parseNetworkMode([
            "network_net_select": "WL_AND_5G", "network_type": "4G"
        ]), .automatic)
        XCTAssertNil(F50ResponseParser.parseNetworkMode(["network_type": "5G"]))
        XCTAssertNil(F50ResponseParser.parseNetworkMode(["network_net_select": "unsupported"]))
        XCTAssertNil(F50ResponseParser.parseNetworkMode(["network_net_select": NSNull()]))
        XCTAssertEqual(F50ResponseParser.parseNetworkMode([
            "network_net_select": "", "net_select": "Only_LTE"
        ]), .lteOnly)
    }
}
