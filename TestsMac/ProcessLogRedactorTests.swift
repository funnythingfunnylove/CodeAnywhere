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

    func testOmitsExpectedClientDisconnectWarnings() {
        let reset = #"{"timestamp":"2026-08-05T07:17:45Z","level":"WARN","fields":{"message":"websocket receive error: WebSocket protocol error: Connection reset without closing handshake"},"target":"codex_app_server_transport::transport::websocket"}"#
        let disconnected = #"{"timestamp":"2026-08-05T08:14:08Z","level":"WARN","fields":{"message":"dropping message for disconnected connection: ConnectionId(15)"},"target":"codex_app_server::transport"}"#

        XCTAssertFalse(ProcessLogPolicy.shouldDisplay(reset))
        XCTAssertFalse(ProcessLogPolicy.shouldDisplay(disconnected))
    }

    func testKeepsOtherWarningsErrorsAndPlainText() {
        let pluginWarning = #"{"level":"WARN","fields":{"message":"ignoring interface.defaultPrompt: maximum of 3 prompts is supported"},"target":"codex_core_plugins::manifest"}"#
        let transportError = #"{"level":"ERROR","fields":{"message":"websocket receive error: Connection reset without closing handshake"},"target":"codex_app_server_transport::transport::websocket"}"#

        XCTAssertTrue(ProcessLogPolicy.shouldDisplay(pluginWarning))
        XCTAssertTrue(ProcessLogPolicy.shouldDisplay(transportError))
        XCTAssertTrue(ProcessLogPolicy.shouldDisplay("Codex app-server 已启动"))
    }
}
