import Foundation
import XCTest
@testable import CodeAnywhereMac

final class BarkContractTests: XCTestCase {
    func testOfficialJSONPayloadIncludesNotificationFormatAndStyle() throws {
        let notification = BarkNotification(
            title: "Codex 已完成",
            subtitle: "CodeAnyWhere",
            body: "修复登录流程\n耗时 3 分钟",
            level: .timeSensitive,
            volume: 7,
            sound: "minuet",
            icon: "https://example.com/codex.png",
            group: "Codex",
            url: "codeanywhere://thread/thread-1",
            id: "turn-1",
            usesMarkdown: true
        )

        let data = try BarkPushPayload.encodedData(
            notification: notification,
            deviceKey: "device-key"
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["device_key"] as? String, "device-key")
        XCTAssertEqual(json["title"] as? String, "Codex 已完成")
        XCTAssertEqual(json["subtitle"] as? String, "CodeAnyWhere")
        XCTAssertNil(json["body"])
        XCTAssertEqual(json["markdown"] as? String, "修复登录流程\n耗时 3 分钟")
        XCTAssertEqual(json["level"] as? String, "timeSensitive")
        XCTAssertEqual(json["volume"] as? Int, 7)
        XCTAssertEqual(json["sound"] as? String, "minuet")
        XCTAssertEqual(json["icon"] as? String, "https://example.com/codex.png")
        XCTAssertEqual(json["group"] as? String, "Codex")
        XCTAssertEqual(json["url"] as? String, "codeanywhere://thread/thread-1")
        XCTAssertEqual(json["id"] as? String, "turn-1")
    }

    func testNotificationStyleRendersDocumentedTemplateTokens() {
        let style = BarkNotificationStyle(
            titleTemplate: "{status}",
            subtitleTemplate: "{thread}",
            bodyTemplate: "{thread} · {time}",
            group: "Codex Tasks",
            level: .passive,
            criticalVolume: 5,
            sound: "",
            icon: "",
            usesMarkdown: false
        )
        let date = Date(timeIntervalSince1970: 1_786_000_000)

        let notification = style.notification(
            threadTitle: "设置页重构",
            statusTitle: "Codex 已完成",
            terminalAt: date,
            url: "codeanywhere://thread/1",
            id: "turn-1"
        )

        XCTAssertEqual(notification.title, "Codex 已完成")
        XCTAssertEqual(notification.subtitle, "设置页重构")
        XCTAssertTrue(notification.body.hasPrefix("设置页重构 · "))
        XCTAssertEqual(notification.group, "Codex Tasks")
        XCTAssertEqual(notification.level, .passive)
        XCTAssertNil(notification.volume)
        XCTAssertNil(notification.sound)
        XCTAssertNil(notification.icon)
    }

    func testNotificationStyleAppendsTerminalDetailWhenTemplateOmitsIt() {
        let style = BarkNotificationStyle(
            titleTemplate: "{status}",
            subtitleTemplate: "{thread}",
            bodyTemplate: "{status} · {time}",
            group: "Codex Tasks",
            level: .active,
            criticalVolume: 5,
            sound: "",
            icon: "",
            usesMarkdown: false
        )

        let notification = style.notification(
            threadTitle: "代理认证",
            statusTitle: "Codex 执行失败",
            detail: "503 auth_unavailable",
            terminalAt: Date(timeIntervalSince1970: 1_786_000_000),
            url: "codeanywhere://thread/1",
            id: "turn-1"
        )

        XCTAssertEqual(notification.title, "Codex 执行失败")
        XCTAssertTrue(notification.body.contains("503 auth_unavailable"))
    }

    func testNotificationIdentifierFitsAPNsCollapseIDLimit() {
        let oversized = "codeanywhere-" + String(repeating: "a", count: 64)
        let normalized = BarkNotificationIdentifier.normalized(oversized)

        XCTAssertEqual(normalized.utf8.count, 64)
        XCTAssertEqual(normalized, BarkNotificationIdentifier.normalized(oversized))
        XCTAssertNotEqual(normalized, BarkNotificationIdentifier.normalized(oversized + "b"))
    }

    func testShortNotificationIdentifierIsPreserved() {
        XCTAssertEqual(
            BarkNotificationIdentifier.normalized("codeanywhere-test-short"),
            "codeanywhere-test-short"
        )
    }

    func testBlankSavedServerURLFallsBackToDefault() {
        XCTAssertEqual(
            BarkServerConfiguration.resolvedURL(from: "  \n"),
            BarkServerConfiguration.defaultURL
        )
    }

    func testInvalidSavedServerURLFallsBackToDefault() {
        XCTAssertEqual(
            BarkServerConfiguration.resolvedURL(from: "not a url"),
            BarkServerConfiguration.defaultURL
        )
    }

    func testValidSavedServerURLIsTrimmedAndPreserved() {
        XCTAssertEqual(
            BarkServerConfiguration.resolvedURL(from: "  https://bark.example/base/  "),
            "https://bark.example/base/"
        )
    }

    func testKeychainAccountMatchesCurrentMacOSUsername() {
        XCTAssertEqual(KeychainAccount.currentUsername(), NSUserName())
        XCTAssertFalse(KeychainAccount.currentUsername().isEmpty)
        XCTAssertEqual(KeychainDeviceKeyStore().account, NSUserName())
    }

    func testEndpointAppendsPushPath() throws {
        XCTAssertEqual(
            try BarkEndpoint.pushURL(from: "http://192.168.1.10:8888/").absoluteString,
            "http://192.168.1.10:8888/push"
        )
        XCTAssertEqual(
            try BarkEndpoint.pushURL(from: "https://bark.example/base").absoluteString,
            "https://bark.example/base/push"
        )
    }

    func testEndpointRejectsCredentialsAndQuery() {
        XCTAssertThrowsError(try BarkEndpoint.pushURL(from: "https://key@bark.example"))
        XCTAssertThrowsError(try BarkEndpoint.pushURL(from: "https://bark.example?device_key=secret"))
    }

    func testResponseRequiresHTTPAndBusinessSuccess() throws {
        try BarkResponseEvaluator.validate(statusCode: 200, data: Data(#"{"code":200,"message":"success"}"#.utf8))

        XCTAssertThrowsError(
            try BarkResponseEvaluator.validate(statusCode: 503, data: Data(#"{"code":200}"#.utf8))
        ) { error in
            XCTAssertEqual(error as? BarkDeliveryError, .httpStatus(503))
        }
        XCTAssertThrowsError(
            try BarkResponseEvaluator.validate(statusCode: 200, data: Data(#"{"code":500}"#.utf8))
        ) { error in
            XCTAssertEqual(error as? BarkDeliveryError, .rejected(code: 500))
        }
    }

    func testMalformedResponseIsNotAccepted() {
        XCTAssertThrowsError(try BarkResponseEvaluator.validate(statusCode: 200, data: Data("ok".utf8))) { error in
            XCTAssertEqual(error as? BarkDeliveryError, .malformedResponse)
        }
    }
}
