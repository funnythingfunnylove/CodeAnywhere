import XCTest
@testable import CodeAnywhereMac

final class ProcessLogRedactorTests: XCTestCase {
    func testRedactsCapabilityBearerAndDeviceKey() {
        let raw = """
        token=codeanywhere-lan-v1
        Authorization: Bearer abc.def.ghi
        {"device_key":"private-device-key","title":"safe"}
        """

        let value = ProcessLogRedactor.redact(raw)

        XCTAssertFalse(value.contains("codeanywhere-lan-v1"))
        XCTAssertFalse(value.contains("abc.def.ghi"))
        XCTAssertFalse(value.contains("private-device-key"))
        XCTAssertTrue(value.contains("<redacted>"))
        XCTAssertTrue(value.contains("safe"))
    }

    func testRedactsAdditionalSecret() {
        XCTAssertEqual(
            ProcessLogRedactor.redact("prefix hidden suffix", additionalSecrets: ["hidden"]),
            "prefix <redacted> suffix"
        )
    }
}
