import Foundation

/// Small typed JSON value for the two REST APIs, without an untyped response dictionary.
enum CloudJSON: Codable, Sendable {
    case object([String: CloudJSON]), array([CloudJSON]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode([String: CloudJSON].self) { self = .object(value) }
        else { self = .array(try container.decode([CloudJSON].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
    subscript(_ key: String) -> CloudJSON { if case .object(let value) = self { value[key] ?? .null } else { .null } }
    var string: String? { if case .string(let value) = self { value } else { nil } }
    var array: [CloudJSON] { if case .array(let value) = self { value } else { [] } }
    var bool: Bool { if case .bool(let value) = self { value } else { false } }
    var number: Double? { if case .number(let value) = self { value } else { nil } }
    func required(_ key: String) throws -> String {
        guard let value = self[key].string, !value.isEmpty else { throw CloudSyncError.message(String(localized: "云端返回了不完整的数据，请重试。")) }
        return value
    }
}

public struct CloudHTTPResponse: Sendable {
    public let data: Data
    public let status: Int
    public let retryAfter: TimeInterval?
    public init(data: Data, status: Int, retryAfter: TimeInterval? = nil) { self.data = data; self.status = status; self.retryAfter = retryAfter }
}

public protocol CloudHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> CloudHTTPResponse
}

private final class CloudRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // REST/auth endpoints are fixed. Never forward credentials to a redirect destination.
        completionHandler(nil)
    }
}

public struct CloudURLSessionTransport: CloudHTTPTransport {
    private let session: URLSession
    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 90
        session = URLSession(configuration: config, delegate: CloudRedirectPolicy(), delegateQueue: nil)
    }
    public func send(_ request: URLRequest) async throws -> CloudHTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw CloudSyncError.message(String(localized: "无法读取云端响应。")) }
        return CloudHTTPResponse(data: data, status: response.statusCode, retryAfter: response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init))
    }
}

struct CloudHTTP: Sendable {
    let transport: any CloudHTTPTransport
    var notionDelay: Duration = .milliseconds(350)
    func send(_ request: URLRequest) async throws -> Data {
        for attempt in 0..<3 {
            try Task.checkCancellation()
            if request.url?.host == "api.notion.com" { try await Task.sleep(for: notionDelay) }
            let response = try await transport.send(request)
            if (200..<300).contains(response.status) { return response.data }
            // A POST with an uncertain result is reconciled on the next sync, never blindly replayed.
            let retryable = response.status == 429 || (response.status >= 500 && request.httpMethod != "POST")
            if retryable && attempt < 2 {
                try await Task.sleep(for: .seconds(min(max(response.retryAfter ?? pow(2, Double(attempt)), 1), 30)))
                continue
            }
            throw CloudSyncError.http(response.status)
        }
        throw CloudSyncError.http(503)
    }
    func json(_ request: URLRequest) async throws -> CloudJSON {
        let data = try await send(request)
        return data.isEmpty ? .null : try JSONDecoder().decode(CloudJSON.self, from: data)
    }
    static func request(_ url: URL, method: String = "GET", token: String? = nil, body: CloudJSON? = nil, notion: Bool = false) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if notion { request.setValue("2026-03-11", forHTTPHeaderField: "Notion-Version") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        return request
    }
    static func form(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return Data(fields.sorted { $0.key < $1.key }.map { key, value in
            (key.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") + "=" + (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        }.joined(separator: "&").utf8)
    }
}
