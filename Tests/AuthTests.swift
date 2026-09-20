import XCTest
@testable import CodexUsageCore
final class AuthTests: XCTestCase {
    func testDeviceCodeAcceptsStringIntervalAndAlias() throws {
        let code = try JSONDecoder().decode(DeviceCode.self, from: Data(#"{"device_auth_id":"test","usercode":"ABCD","interval":"5"}"#.utf8))
        XCTAssertEqual(code.userCode, "ABCD")
        XCTAssertEqual(code.interval, 5)
    }
}
