import Foundation
import Crypto
#if os(Linux)
import FoundationNetworking
#endif

public struct BarkNotification: Equatable, Sendable {
    public let title: String
    public let body: String
    public let group: String
    public let url: String
    public let id: String

    public init(title: String, body: String, group: String, url: String, id: String) {
        self.title = title
        self.body = body
        self.group = group
        self.url = url
        self.id = id
    }
}

public enum BarkDeliveryError: LocalizedError, Equatable, Sendable {
    case invalidServerURL
    case transport(String)
    case httpStatus(Int)
    case malformedResponse
    case rejected(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidServerURL: return "Bark Server URL 无效"
        case .transport(let message): return "无法连接 Bark Server：\(message)"
        case .httpStatus(let status): return "Bark Server 返回 HTTP \(status)"
        case .malformedResponse: return "Bark Server 返回了无法识别的数据"
        case .rejected(let code): return "Bark Server 拒绝了请求（code \(code)）"
        }
    }
}

public enum StableIdentifier {
    public static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public struct BarkClient: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func send(_ notification: BarkNotification, deviceKey: String, serverURL: String) async throws {
        guard var components = URLComponents(string: serverURL),
              let scheme = components.scheme?.lowercased(), (scheme == "http" || scheme == "https"),
              components.host?.isEmpty == false, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw BarkDeliveryError.invalidServerURL
        }
        var path = components.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        if !path.hasSuffix("/push") { path = path == "/" || path.isEmpty ? "/push" : path + "/push" }
        components.path = path
        guard let url = components.url else { throw BarkDeliveryError.invalidServerURL }

        struct Payload: Encodable {
            let deviceKey: String
            let title: String
            let body: String
            let group: String
            let url: String
            let id: String
            enum CodingKeys: String, CodingKey {
                case deviceKey = "device_key"
                case title, body, group, url, id
            }
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Payload(
            deviceKey: deviceKey,
            title: notification.title,
            body: notification.body,
            group: notification.group,
            url: notification.url,
            id: notification.id
        ))
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw BarkDeliveryError.transport(error.localizedDescription) }
        guard let http = response as? HTTPURLResponse else { throw BarkDeliveryError.malformedResponse }
        guard (200...299).contains(http.statusCode) else { throw BarkDeliveryError.httpStatus(http.statusCode) }
        guard let result = try? JSONDecoder().decode(BarkResponse.self, from: data) else {
            throw BarkDeliveryError.malformedResponse
        }
        guard result.code == 200 else { throw BarkDeliveryError.rejected(result.code) }
    }

    private struct BarkResponse: Decodable { let code: Int }
}
