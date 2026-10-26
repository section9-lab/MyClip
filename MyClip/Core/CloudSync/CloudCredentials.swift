import Foundation
import Security
import CryptoKit

public struct GoogleDesktopClient: Codable, Sendable {
    public let clientID: String
    public let clientSecret: String?
    public init(clientID: String, clientSecret: String? = nil) { self.clientID = clientID; self.clientSecret = clientSecret }
    public static func decode(_ data: Data) throws -> Self {
        let json = try JSONDecoder().decode(CloudJSON.self, from: data)
        let installed = json["installed"]
        guard let id = installed["client_id"].string, id.hasSuffix(".apps.googleusercontent.com") else {
            throw CloudSyncError.message(String(localized: "请选择 Google Cloud 下载的“桌面应用”OAuth 客户端 JSON 文件。"))
        }
        return Self(clientID: id, clientSecret: installed["client_secret"].string)
    }
}

public struct CloudCredential: Codable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?
    public var googleClient: GoogleDesktopClient?
    public init(accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil, googleClient: GoogleDesktopClient? = nil) {
        self.accessToken = accessToken; self.refreshToken = refreshToken; self.expiresAt = expiresAt; self.googleClient = googleClient
    }
}

public protocol CloudCredentialStorage: Sendable {
    func read(_ provider: CloudSyncProvider) async throws -> CloudCredential?
    func save(_ credential: CloudCredential, for provider: CloudSyncProvider) async throws
    func remove(_ provider: CloudSyncProvider) async throws
}

public actor CloudKeychain: CloudCredentialStorage {
    private let secrets: KeychainDataStore
    public init(libraryRoot: URL) {
        secrets = KeychainDataStore(service: "cc.vibevibe.myclip.cloud." + CloudMemoryDocument.hash(libraryRoot.standardizedFileURL.path))
    }
    public func read(_ provider: CloudSyncProvider) throws -> CloudCredential? {
        try secrets.read(provider.rawValue).map { try JSONDecoder().decode(CloudCredential.self, from: $0) }
    }
    public func save(_ credential: CloudCredential, for provider: CloudSyncProvider) throws {
        try secrets.save(JSONEncoder().encode(credential), for: provider.rawValue)
    }
    public func remove(_ provider: CloudSyncProvider) throws { try secrets.remove(provider.rawValue) }
}

public struct KeychainDataStore: Sendable {
    private let service: String
    public init(service: String) { self.service = service }
    public func read(_ account: String, allowInteraction: Bool = true) throws -> Data? {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        if !allowInteraction { query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw keychainError(status) }
        return data
    }
    public func save(_ data: Data, for account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = SecItemAdd(item as CFDictionary, nil)
            guard status == errSecSuccess else { throw keychainError(status) }
        } else if update != errSecSuccess { throw keychainError(update) }
    }
    public func remove(_ account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw keychainError(status) }
    }
    private func keychainError(_ status: OSStatus) -> CloudSyncError {
        .message(String(localized: "系统钥匙串不可用（\(status)）。请解锁钥匙串后重试。"))
    }
}

public enum GoogleCloudAuthorization {
    public static let scope = "https://www.googleapis.com/auth/drive.file"
    public static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    public static func url(client: GoogleDesktopClient, redirect: URL, state: String, verifier: String) -> URL {
        var url = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        url.queryItems = ["client_id": client.clientID, "redirect_uri": redirect.absoluteString, "response_type": "code", "scope": scope,
                          "state": state, "code_challenge": challenge(for: verifier), "code_challenge_method": "S256", "access_type": "offline", "prompt": "consent"].map(URLQueryItem.init)
        return url.url!
    }
    public static func exchange(code: String, client: GoogleDesktopClient, redirect: URL, verifier: String,
                                transport: any CloudHTTPTransport = CloudURLSessionTransport()) async throws -> CloudCredential {
        var fields = ["code": code, "client_id": client.clientID, "redirect_uri": redirect.absoluteString, "code_verifier": verifier, "grant_type": "authorization_code"]
        if let secret = client.clientSecret { fields["client_secret"] = secret }
        return try await token(fields: fields, client: client, transport: transport)
    }
    static func token(fields: [String: String], client: GoogleDesktopClient, previousRefresh: String? = nil, transport: any CloudHTTPTransport) async throws -> CloudCredential {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = CloudHTTP.form(fields)
        let response = try await CloudHTTP(transport: transport).json(request)
        return CloudCredential(accessToken: try response.required("access_token"), refreshToken: response["refresh_token"].string ?? previousRefresh,
                               expiresAt: Date().addingTimeInterval(response["expires_in"].number ?? 3600), googleClient: client)
    }
}
