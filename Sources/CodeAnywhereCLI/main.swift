import CodeAnywhereCore
import Foundation

#if os(Linux)
import Glibc
#endif

@main
struct CodeAnywhereCLI {
    static func main() async {
        do { try await run(arguments: Array(CommandLine.arguments.dropFirst())) }
        catch {
            let message = Data("codeanywhere: \(error.localizedDescription)\n".utf8)
            try? FileHandle.standardError.write(contentsOf: message)
            exit(1)
        }
    }

    private static func run(arguments: [String]) async throws {
        let command = arguments.first ?? "help"
        let configURL = try option(arguments, name: "--config").map { URL(fileURLWithPath: $0) }
            ?? CodeAnywhereConfiguration.defaultURL()
        if command == "help" || command == "--help" {
            print("""
            用法：codeanywhere <check|probe|serve> [--config PATH] [--duration SECONDS]

              check   检查配置和 Codex CLI，不启动服务
              probe   启动由本 CLI 持有的 app-server，验证 initialize/model-list/thread-list 后退出
              serve   启动 app-server 并持续监控完成/失败 Turn

              --duration 仅对 serve 生效：运行指定秒数后自动退出（用于自动化测试）
            """)
            return
        }

        let configuration: CodeAnywhereConfiguration
        if FileManager.default.fileExists(atPath: configURL.path) {
            configuration = try CodeAnywhereConfiguration.load(from: configURL)
        } else if command == "check" {
            configuration = .default
            print("[INFO] 配置文件不存在，使用默认配置：\(configURL.path)")
        } else {
            throw NSError(domain: "CodeAnywhereCLI", code: 2, userInfo: [NSLocalizedDescriptionKey: "找不到配置文件：\(configURL.path)"])
        }

        switch command {
        case "check":
            try check(configuration)
        case "probe":
            let daemon = CodeAnywhereDaemon(configuration: configuration)
            try await daemon.start()
            do {
                let result = try await daemon.probe()
                print("[PASS] app-server initialize 已完成")
                print("[PASS] model/list 返回：\(result.version ?? "无模型")")
                print("[PASS] thread/list 返回：\(result.threadCount) 条")
            } catch {
                await daemon.stop()
                throw error
            }
            await daemon.stop()
            print("[PASS] app-server 子进程已终止，capability-token 已删除")
        case "serve":
            let daemon = CodeAnywhereDaemon(configuration: configuration)
            // Install handlers before start(): a SIGTERM/SIGINT arriving while
            // the app-server is still booting must still terminate it.
            installSignalHandlers {
                Task {
                    await daemon.stop()
                    exit(0)
                }
            }
            try await daemon.start()
            if let duration = try option(arguments, name: "--duration").flatMap(Double.init) {
                guard duration > 0 else {
                    throw NSError(domain: "CodeAnywhereCLI", code: 2, userInfo: [NSLocalizedDescriptionKey: "--duration 必须大于 0"])
                }
                print("[INFO] 测试模式：\(Int(duration)) 秒后自动退出")
                Task {
                    try? await Task.sleep(for: .seconds(duration))
                    await daemon.stop()
                    exit(0)
                }
            }
            print("[INFO] CodeAnywhere Linux daemon 已启动，局域网端口：\(configuration.server.port)")
            print("[INFO] 使用 Ctrl-C 停止；Bark Device Key 只从环境变量读取")
            await daemon.run()
            await daemon.stop()
        default:
            throw NSError(domain: "CodeAnywhereCLI", code: 2, userInfo: [NSLocalizedDescriptionKey: "未知命令：\(command)"])
        }
    }

    private static func check(_ configuration: CodeAnywhereConfiguration) throws {
        _ = try configuration.validated()
        guard let executable = CodexExecutableLocator.locate(configuration.server.executable) else {
            throw CodexProcessError.executableNotFound(configuration.server.executable)
        }
        print("[PASS] 配置有效")
        print("[PASS] Codex CLI：\(executable.path)")
        print("[INFO] app-server：ws://\(configuration.server.bind):\(configuration.server.port)")
        print("[INFO] Bark：\(configuration.bark.enabled ? "启用" : "停用")")
    }

    private static func option(_ arguments: [String], name: String) throws -> String? {
        guard let index = arguments.firstIndex(of: name) else { return nil }
        guard arguments.indices.contains(index + 1) else {
            throw NSError(domain: "CodeAnywhereCLI", code: 2, userInfo: [NSLocalizedDescriptionKey: "选项缺少值：\(name)"])
        }
        return arguments[index + 1]
    }

    private static func installSignalHandlers(_ handler: @escaping @Sendable () -> Void) {
#if os(Linux)
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global(qos: .userInitiated))
        source.setEventHandler(handler: handler)
        source.resume()
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global(qos: .userInitiated))
        term.setEventHandler(handler: handler)
        term.resume()
        signalRegistry.sources = [source, term]
#endif
    }

#if os(Linux)
    private static let signalRegistry = SignalRegistry()
#endif
}

#if os(Linux)
private final class SignalRegistry: @unchecked Sendable {
    var sources: [DispatchSourceSignal] = []
}
#endif
