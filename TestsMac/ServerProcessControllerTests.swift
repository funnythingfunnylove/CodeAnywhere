import Darwin
import XCTest
@testable import CodeAnywhereMac

final class ServerProcessControllerTests: XCTestCase {
    @MainActor
    func testRealCodexProcessStartsAndStopsOnUnusedPort() throws {
        guard CodexExecutableLocator.locate() != nil else {
            throw XCTSkip("此 Mac 未安装 Codex CLI")
        }

        let port = try Self.unusedLoopbackPort()
        let controller = ServerProcessController()
        try controller.start(port: port)
        defer { _ = controller.stop(waitUntilExit: true) }

        XCTAssertTrue(
            Self.waitUntil(timeout: 5) { Self.canConnect(to: port) },
            "测试创建的 Codex app-server 未在限定时间内开始监听"
        )
        guard case .running(let pid) = controller.state else {
            return XCTFail("进程控制器没有进入运行状态")
        }
        XCTAssertGreaterThan(pid, 0)

        XCTAssertTrue(controller.stop(waitUntilExit: true))
        XCTAssertTrue(
            Self.waitUntil(timeout: 3) { !Self.canConnect(to: port) },
            "停止后测试端口仍可连接"
        )
        XCTAssertEqual(controller.state, .stopped)
    }

    private static func unusedLoopbackPort() throws -> Int {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.ENOTSOCK) }
        defer { Darwin.close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EADDRINUSE) }

        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(descriptor, $0, &length)
            }
        }
        guard nameResult == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL) }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private static func canConnect(to port: Int) -> Bool {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    private static func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return condition()
    }
}
