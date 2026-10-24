import AppKit
import Network
import MyClipCore

/// Installed-app OAuth with PKCE and an ephemeral IPv4 loopback listener. No app secret server is required.
@MainActor
final class GoogleCloudOAuth {
    private var listener: NWListener?
    private var continuation: CheckedContinuation<String, Error>?
    private var timeout: Task<Void, Never>?
    private var redirect: URL?
    private var state = ""
    private var verifier = ""
    private var connections: [UUID: NWConnection] = [:]
    private let openBrowser: @MainActor (URL) -> Bool
    private let transport: any CloudHTTPTransport

    init(openBrowser: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) },
         transport: any CloudHTTPTransport = CloudURLSessionTransport()) {
        self.openBrowser = openBrowser; self.transport = transport
    }

    func authorize(_ client: GoogleDesktopClient) async throws -> CloudCredential {
        guard listener == nil else { throw CloudSyncError.message(String(localized: "Google 授权已在进行中。")) }
        state = UUID().uuidString + UUID().uuidString
        verifier = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "")
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener
        defer { close() }
        let code: String = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                listener.stateUpdateHandler = { [weak self] status in
                    Task { @MainActor in
                        guard let self else { return }
                        switch status {
                        case .ready:
                            guard let port = listener.port else { self.finish(.failure(CloudSyncError.message(String(localized: "无法创建本地授权回调。")))); return }
                            let redirect = URL(string: "http://127.0.0.1:\(port.rawValue)/oauth/callback")!
                            self.redirect = redirect
                            let url = GoogleCloudAuthorization.url(client: client, redirect: redirect, state: self.state, verifier: self.verifier)
                            if !self.openBrowser(url) { self.finish(.failure(CloudSyncError.message(String(localized: "无法打开浏览器，请检查默认浏览器设置。")))) }
                        case .failed:
                            self.finish(.failure(CloudSyncError.message(String(localized: "无法启动本地授权回调，请重试。"))))
                        default: break
                        }
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    Task { @MainActor in self?.receive(connection) }
                }
                listener.start(queue: .main)
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(180)) } catch { return }
                    self?.finish(.failure(CloudSyncError.message(String(localized: "Google 授权已超时，请重试。"))))
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel() } }
        try Task.checkCancellation()
        guard let redirect else { throw CloudSyncError.message(String(localized: "授权回调缺失，请重试。")) }
        return try await GoogleCloudAuthorization.exchange(code: code, client: client, redirect: redirect, verifier: verifier, transport: transport)
    }

    func cancel() { finish(.failure(CancellationError())) }

    private func receive(_ connection: NWConnection) {
        let id = UUID()
        connections[id] = connection
        connection.start(queue: .main)
        read(connection, id: id, accumulated: Data())
    }
    private func read(_ connection: NWConnection, id: UUID, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                var buffer = accumulated
                if let data { buffer.append(data) }
                guard error == nil, buffer.count <= 16384 else { self.end(connection, id: id, accepted: false); return }
                guard let request = String(data: buffer, encoding: .utf8), request.contains("\r\n\r\n") else {
                    if complete { self.end(connection, id: id, accepted: false) }
                    else { self.read(connection, id: id, accumulated: buffer) }
                    return
                }
                let words = request.components(separatedBy: "\r\n")[0].split(separator: " ")
                guard words.count == 3, words[0] == "GET", let redirect = self.redirect,
                      let url = URL(string: String(words[1]), relativeTo: redirect), url.host == "127.0.0.1", url.port == redirect.port,
                      url.path == "/oauth/callback", let parts = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
                    self.end(connection, id: id, accepted: false); return
                }
                let values = parts.queryItems ?? []
                guard values.filter({ $0.name == "state" }).count == 1, values.first(where: { $0.name == "state" })?.value == self.state else {
                    self.end(connection, id: id, accepted: false); return
                }
                if values.contains(where: { $0.name == "error" }) {
                    self.end(connection, id: id, accepted: false)
                    self.finish(.failure(CloudSyncError.message(String(localized: "Google 授权未完成，你可以重新连接。"))))
                } else if let code = values.first(where: { $0.name == "code" })?.value, !code.isEmpty {
                    self.end(connection, id: id, accepted: true)
                    self.finish(.success(code))
                } else { self.end(connection, id: id, accepted: false) }
            }
        }
    }
    private func end(_ connection: NWConnection, id: UUID, accepted: Bool) {
        let message = accepted ? String(localized: "授权已收到，请返回 MyClip 完成连接。") : String(localized: "此授权回调无效，请返回 MyClip 重试。")
        let body = Data("<!doctype html><html lang=\"zh\"><meta charset=\"utf-8\"><title>MyClip</title><p>\(message)</p></html>".utf8)
        var response = Data("HTTP/1.1 \(accepted ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        // The send owns this connection until the response is flushed, independently from the listener lifetime.
        connections.removeValue(forKey: id)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
    private func finish(_ result: Result<String, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel(); timeout = nil
        listener?.cancel(); listener = nil
        continuation.resume(with: result)
    }
    private func close() {
        timeout?.cancel(); timeout = nil
        listener?.cancel(); listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
    }
}
