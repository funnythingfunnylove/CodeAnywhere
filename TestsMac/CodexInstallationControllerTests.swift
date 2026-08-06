import Foundation
import XCTest
@testable import CodeAnywhereMac

final class CodexInstallationControllerTests: XCTestCase {
    func testPreferredLANAddressUsesPrimaryEthernetAndSkipsLoopback() {
        let result = LocalNetworkAddressResolver.preferredIPv4Address(from: [
            LocalNetworkInterfaceAddress(name: "lo0", address: "127.0.0.1"),
            LocalNetworkInterfaceAddress(name: "bridge100", address: "172.16.0.1"),
            LocalNetworkInterfaceAddress(name: "en1", address: "192.168.1.50"),
            LocalNetworkInterfaceAddress(name: "en0", address: "10.0.0.8")
        ])

        XCTAssertEqual(result, "10.0.0.8")
        XCTAssertNil(
            LocalNetworkAddressResolver.preferredIPv4Address(from: [
                LocalNetworkInterfaceAddress(name: "lo0", address: "127.0.0.1"),
                LocalNetworkInterfaceAddress(name: "en0", address: "169.254.1.2")
            ])
        )
    }

    func testVersionParserNormalizesCodexCLIOutput() {
        XCTAssertEqual(
            CodexCLIOutputParser.version(from: "codex-cli 0.146.1\n"),
            "0.146.1"
        )
        XCTAssertEqual(
            CodexCLIOutputParser.version(from: "codex 1.2.3-beta.1"),
            "1.2.3-beta.1"
        )
        XCTAssertNil(CodexCLIOutputParser.version(from: "  \n"))
    }

    @MainActor
    func testUpdateRunsOfficialCodexUpdateCommandAndRefreshesVersion() async throws {
        let executable = URL(fileURLWithPath: "/tmp/codex")
        let runner = RecordingCodexCommandRunner(results: [
            CodexCommandResult(exitCode: 0, output: "codex-cli 0.146.1"),
            CodexCommandResult(exitCode: 0, output: "Updated successfully"),
            CodexCommandResult(exitCode: 0, output: "codex-cli 0.147.0")
        ])
        let controller = CodexInstallationController(
            executableLocator: { executable },
            runner: runner
        )

        await controller.refresh()
        await controller.updateCodex()

        XCTAssertEqual(controller.version, "0.147.0")
        XCTAssertEqual(controller.executablePath, executable.path)
        XCTAssertEqual(controller.updateState, .succeeded("Codex 已更新至 0.147.0"))
        let invocations = await runner.invocations
        XCTAssertEqual(invocations.map(\.arguments), [["--version"], ["update"], ["--version"]])
        XCTAssertEqual(controller.lastCommandOutput, "Updated successfully")
    }

    @MainActor
    func testUpdateFailureDoesNotClaimSuccess() async {
        let runner = RecordingCodexCommandRunner(results: [
            CodexCommandResult(exitCode: 7, output: "network unavailable")
        ])
        let controller = CodexInstallationController(
            executableLocator: { URL(fileURLWithPath: "/tmp/codex") },
            runner: runner
        )

        await controller.updateCodex()

        guard case .failed(let message) = controller.updateState else {
            return XCTFail("更新失败时状态不应为成功")
        }
        XCTAssertTrue(message.contains("network unavailable"))
    }
}

private actor RecordingCodexCommandRunner: CodexCommandRunning {
    struct Invocation: Equatable {
        let executable: URL
        let arguments: [String]
    }

    private var results: [CodexCommandResult]
    private(set) var invocations: [Invocation] = []

    init(results: [CodexCommandResult]) {
        self.results = results
    }

    func run(executable: URL, arguments: [String]) async throws -> CodexCommandResult {
        invocations.append(Invocation(executable: executable, arguments: arguments))
        return results.removeFirst()
    }
}
