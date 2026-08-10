import Foundation
#if os(Linux)
import FoundationNetworking
import NIOHTTP1
import NIOPosix
import WebSocketKit
#endif

public struct CodexEndpoint: Equatable, Sendable {
    public let host: String
    public let port: Int
    public let token: String

    public init(host: String = "127.0.0.1", port: Int, token: String) {
        self.host = host
        self.port = port
        self.token = token
    }

    var url: URL? { URL(string: "ws://\(host):\(port)/") }
}

public enum CodexClientError: LocalizedError, Equatable, Sendable {
    case invalidEndpoint
    case disconnected
    case malformedResponse
    case server(code: Int, message: String)
    case transport(String)
    case timeout(String)

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "Codex app-server 地址无效"
        case .disconnected: return "Codex app-server 连接已断开"
        case .malformedResponse: return "Codex app-server 返回了无法识别的数据"
        case .server(_, let message): return message
        case .transport(let message): return "Codex 传输失败：\(message)"
        case .timeout(let method): return "Codex 请求超时：\(method)"
        }
    }
}

public struct CodexNotification: Equatable, Sendable {
    public let method: String
    public let params: JSONValue
}

public struct CodexTerminatedEvent: Equatable, Sendable {
    public let threadID: String
    public let turnID: String
    public let status: MonitoredThreadState
    public let detail: String?
}

public enum CodexServerEvent: Equatable, Sendable {
    case turnTerminated(CodexTerminatedEvent)
}

public enum CodexServerEventParser {
    public static func parse(_ message: JSONValue) -> CodexServerEvent? {
        guard message["method"]?.stringValue == "turn/completed",
              let params = message["params"],
              let threadID = params["threadId"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !threadID.isEmpty,
              let turn = params["turn"],
              let turnID = turn["id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !turnID.isEmpty,
              let rawStatus = turn["status"]?.stringValue else { return nil }
        let status = MonitoredThreadState(codexStatus: rawStatus)
        guard status.shouldNotify else { return nil }
        return .turnTerminated(
            CodexTerminatedEvent(
                threadID: threadID,
                turnID: turnID,
                status: status,
                detail: CompletionTerminalDetail.redacted(from: turn["error"])
            )
        )
    }
}

public enum CodexAutomaticServerRequestResponder {
    public static func response(for message: JSONValue) -> JSONValue? {
        guard let requestID = message["id"], let method = message["method"]?.stringValue else { return nil }
        switch method {
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
            return .object(["id": requestID, "result": .object(["decision": .string("accept")])])
        default:
            return nil
        }
    }
}

public actor CodexWebSocketClient {
    public static let maximumMessageSize = 32 * 1_024 * 1_024
    public static let clientVersion = "0.1.0-linux"

    private let endpoint: CodexEndpoint
    private let session: URLSession
#if os(Linux)
    private static let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var linuxSocket: WebSocket?
#endif
    private var socket: URLSessionWebSocketTask?
    private var listener: Task<Void, Never>?
    private var nextRequestID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var timeoutTasks: [Int: Task<Void, Never>] = [:]
    private var notificationContinuation: AsyncStream<CodexNotification>.Continuation?
    public nonisolated let notifications: AsyncStream<CodexNotification>

    public init(endpoint: CodexEndpoint, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
        var continuation: AsyncStream<CodexNotification>.Continuation!
        self.notifications = AsyncStream { continuation = $0 }
        self.notificationContinuation = continuation
    }

    deinit {
        listener?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
#if os(Linux)
        // Do not await the close handshake during deinitialization.  A local
        // app-server may have already gone away, in which case waiting for a
        // peer close frame can block process teardown indefinitely.
        linuxSocket?.close(code: .goingAway, promise: nil)
#endif
        timeoutTasks.values.forEach { $0.cancel() }
        notificationContinuation?.finish()
    }

    public func connect() async throws {
        guard let url = endpoint.url, (1...65_535).contains(endpoint.port), !endpoint.token.isEmpty else {
            throw CodexClientError.invalidEndpoint
        }
        if socket != nil { return }
#if os(Linux)
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(endpoint.token)")
        try await WebSocket.connect(to: url.absoluteString, headers: headers, on: Self.eventLoopGroup) { [weak self] socket in
            await self?.install(socket)
        }
        for _ in 0..<100 where linuxSocket == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard linuxSocket != nil else { throw CodexClientError.transport("WebSocket 升级后未建立连接") }
#else
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = Self.maximumMessageSize
        socket = task
        task.resume()
        listener = Task { await receiveLoop() }
#endif
        do {
            _ = try await call(
                method: "initialize",
                params: [
                    "clientInfo": .object([
                        "name": .string("codeanywhere-linux"),
                        "title": .string("CodeAnywhere Linux"),
                        "version": .string(Self.clientVersion)
                    ]),
                    "capabilities": .object(["experimentalApi": .bool(false)])
                ]
            )
            try await send(.object(["method": .string("initialized")]))
        } catch {
            await disconnect()
            throw error
        }
    }

    public func disconnect() async {
        listener?.cancel()
        listener = nil
#if os(Linux)
        // Initiate closure without waiting for the remote close handshake;
        // Codex can be terminated immediately afterwards by the supervisor.
        linuxSocket?.close(code: .goingAway, promise: nil)
        linuxSocket = nil
#endif
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        finishPending(with: CodexClientError.disconnected)
        notificationContinuation?.finish()
    }

    public func call(method: String, params: [String: JSONValue] = [:]) async throws -> JSONValue {
#if os(Linux)
        guard linuxSocket != nil else { throw CodexClientError.disconnected }
#else
        guard socket != nil else { throw CodexClientError.disconnected }
#endif
        let requestID = nextRequestID
        nextRequestID += 1
        let message = JSONValue.object([
            "id": .number(Double(requestID)),
            "method": .string(method),
            "params": .object(params)
        ])
        return try await withCheckedThrowingContinuation { continuation in
            pending[requestID] = continuation
            timeoutTasks[requestID] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(12))
                guard !Task.isCancelled else { return }
                await self?.timeout(requestID: requestID, method: method)
            }
            Task { [weak self] in
                do { try await self?.send(message) }
                catch { await self?.resume(requestID: requestID, with: .failure(error)) }
            }
        }
    }

    private func send(_ message: JSONValue) async throws {
        let data = try JSONEncoder().encode(message)
        guard let text = String(data: data, encoding: .utf8) else { throw CodexClientError.malformedResponse }
#if os(Linux)
        guard let linuxSocket else { throw CodexClientError.disconnected }
        do { try await linuxSocket.send(text) }
        catch { throw CodexClientError.transport(error.localizedDescription) }
#else
        guard let socket else { throw CodexClientError.disconnected }
        do { try await socket.send(.string(text)) }
        catch { throw CodexClientError.transport(error.localizedDescription) }
#endif
    }

#if !os(Linux)
    private func receiveLoop() async {
        while !Task.isCancelled, let socket {
            do {
                let message = try await socket.receive()
                let data: Data
                switch message {
                case .string(let value): data = Data(value.utf8)
                case .data(let value): data = value
                @unknown default: continue
                }
                await handle(data: data)
            } catch {
                if !Task.isCancelled {
                    finishPending(with: CodexClientError.transport(error.localizedDescription))
                    self.socket = nil
                }
                return
            }
        }
    }
#endif

#if os(Linux)
    private func install(_ socket: WebSocket) {
        linuxSocket = socket
        socket.onText { [weak self] _, text in
            await self?.handle(data: Data(text.utf8))
        }
        socket.onBinary { [weak self] _, buffer in
            await self?.handle(data: Data(buffer.readableBytesView))
        }
        socket.onClose.whenComplete { [weak self] _ in
            Task { await self?.linuxSocketClosed() }
        }
    }

    private func linuxSocketClosed() {
        linuxSocket = nil
        finishPending(with: CodexClientError.disconnected)
    }
#endif

    private func handle(data: Data) async {
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: data) else { return }
        if let id = message["id"]?.intValue, message["method"] == nil {
            if let error = message["error"] {
                resume(requestID: id, with: .failure(CodexClientError.server(
                    code: error["code"]?.intValue ?? -1,
                    message: error["message"]?.stringValue ?? "Codex 请求失败"
                )))
            } else if let result = message["result"] {
                resume(requestID: id, with: .success(result))
            }
            return
        }
        if let response = CodexAutomaticServerRequestResponder.response(for: message) {
            try? await send(response)
            return
        }
        guard let method = message["method"]?.stringValue else { return }
        notificationContinuation?.yield(CodexNotification(method: method, params: message["params"] ?? .null))
    }

    private func resume(requestID: Int, with result: Result<JSONValue, Error>) {
        guard let continuation = pending.removeValue(forKey: requestID) else { return }
        timeoutTasks.removeValue(forKey: requestID)?.cancel()
        continuation.resume(with: result)
    }

    private func finishPending(with error: Error) {
        let continuations = pending.values
        pending.removeAll()
        timeoutTasks.values.forEach { $0.cancel() }
        timeoutTasks.removeAll()
        continuations.forEach { $0.resume(throwing: error) }
    }

    private func timeout(requestID: Int, method: String) {
        resume(requestID: requestID, with: .failure(CodexClientError.timeout(method)))
    }
}
