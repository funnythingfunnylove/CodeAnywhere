import Foundation
import XCTest
@testable import CodeAnywhereMac

final class BarkContractTests: XCTestCase {
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
