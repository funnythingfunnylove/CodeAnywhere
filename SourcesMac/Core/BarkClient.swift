import Foundation

enum BarkDeliveryError: LocalizedError, Equatable {
    case invalidServerURL
    case transport(String)
    case httpStatus(Int)
    case malformedResponse
    case rejected(code: Int)

    var errorDescription: String? {
        switch self {
        case .invalidServerURL: return "Bark Server URL 无效；只支持不含凭据的 HTTP 或 HTTPS 地址"
        case .transport(let message): return "无法连接 Bark Server：\(message)"
        case .httpStatus(let status): return "Bark Server 返回 HTTP \(status)"
        case .malformedResponse: return "Bark Server 返回了无法识别的数据"
        case .rejected(let code): return "Bark Server 拒绝了请求（code \(code)）"
        }
    }
}

struct BarkNotification: Equatable, Sendable {
    let title: String
    let body: String
    let group: String
    let url: String
    let id: String
}

enum BarkEndpoint {
    static func pushURL(from rawValue: String) throws -> URL {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw BarkDeliveryError.invalidServerURL
        }
        var path = components.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        if !path.hasSuffix("/push") {
            path = path == "/" || path.isEmpty ? "/push" : path + "/push"
        }
        components.path = path
        guard let url = components.url else { throw BarkDeliveryError.invalidServerURL }
        return url
    }
}

enum BarkResponseEvaluator {
    private struct BusinessResponse: Decodable {
        let code: Int
    }

    static func validate(statusCode: Int, data: Data) throws {
        guard (200...299).contains(statusCode) else {
            throw BarkDeliveryError.httpStatus(statusCode)
        }
        guard let response = try? JSONDecoder().decode(BusinessResponse.self, from: data) else {
            throw BarkDeliveryError.malformedResponse
        }
        guard response.code == 200 else {
            throw BarkDeliveryError.rejected(code: response.code)
        }
    }
}

protocol BarkSending: Sendable {
    func send(
        _ notification: BarkNotification,
        deviceKey: String,
        serverURL: String
    ) async throws
}

struct BarkClient: BarkSending, Sendable {
    private struct Payload: Encodable {
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

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func send(
        _ notification: BarkNotification,
        deviceKey: String,
        serverURL: String
    ) async throws {
        let url = try BarkEndpoint.pushURL(from: serverURL)
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            Payload(
                deviceKey: deviceKey,
                title: notification.title,
                body: notification.body,
                group: notification.group,
                url: notification.url,
                id: notification.id
            )
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw BarkDeliveryError.transport(error.localizedDescription)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BarkDeliveryError.malformedResponse
        }
        try BarkResponseEvaluator.validate(statusCode: httpResponse.statusCode, data: data)
    }
}
