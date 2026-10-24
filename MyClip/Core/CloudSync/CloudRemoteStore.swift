import Foundation

struct CloudRemoteItem: Sendable {
    let id: String
    let url: String
    let key: String
    let name: String
}

protocol CloudRemoteStore: Sendable {
    func root(parent: String, existing: String?, libraryID: String) async throws -> CloudRemoteItem
    func list(root: String, libraryID: String) async throws -> [CloudRemoteItem]
    func create(_ document: CloudMemoryDocument, root: String, libraryID: String) async throws -> CloudRemoteItem
    func verify(_ item: CloudRemoteItem, document: CloudMemoryDocument) async throws
    func exists(_ item: CloudSyncItem) async throws -> Bool
    func update(_ document: CloudMemoryDocument, item: CloudSyncItem, markdown: String) async throws
    func remove(_ item: CloudSyncItem) async throws
}

struct GoogleDriveMemoryStore: CloudRemoteStore {
    let http: CloudHTTP
    let token: String
    private let documentType = "application/vnd.google-apps.document"

    static func folderID(_ input: String) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return "root" }
        let id: String
        if let url = URL(string: value), url.scheme != nil {
            guard url.scheme == "https", url.host == "drive.google.com", let index = url.pathComponents.firstIndex(of: "folders"), index + 1 < url.pathComponents.count else {
                throw CloudSyncError.message(String(localized: "请输入 Google Drive 文件夹链接或 ID。"))
            }
            id = url.pathComponents[index + 1]
        } else { id = value }
        guard !id.isEmpty, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            throw CloudSyncError.message(String(localized: "Google Drive 文件夹 ID 无效。"))
        }
        return id
    }

    func account(parent: String) async throws -> (id: String, name: String) {
        let about = try await get("about", query: ["fields": "user(emailAddress,permissionId),importFormats"])
        guard about["importFormats"]["text/markdown"].array.contains(where: { $0.string == documentType }) else {
            throw CloudSyncError.message(String(localized: "此 Google Drive 暂不支持将 Markdown 转换为 Google 文档。"))
        }
        if parent != "root" {
            let folder = try await get("files/" + parent, query: ["fields": "id,mimeType,trashed"])
            guard folder["mimeType"].string == "application/vnd.google-apps.folder", !folder["trashed"].bool else { throw CloudSyncError.http(404) }
        }
        let email = try about["user"].required("emailAddress")
        return (about["user"]["permissionId"].string ?? email, email)
    }

    func root(parent: String, existing: String?, libraryID: String) async throws -> CloudRemoteItem {
        if let existing {
            let file = try await get("files/" + existing, query: ["fields": "id,name,mimeType,trashed,appProperties"])
            guard !file["trashed"].bool, file["mimeType"].string == "application/vnd.google-apps.folder",
                  file["appProperties"]["myclip_library"].string == libraryID else { throw CloudSyncError.http(404) }
            return try remote(file, key: "root", folder: true)
        }
        let query = "trashed = false and '\(parent)' in parents and appProperties has { key='myclip_library' and value='\(libraryID)' } and appProperties has { key='myclip_id' and value='root' }"
        let found = try await files(query)
        guard found.count <= 1 else { throw CloudSyncError.message(String(localized: "发现重复的 MyClip 云端目录，请保留一份后重试。")) }
        if let file = found.first { return try remote(file, key: "root", folder: true) }
        let body: CloudJSON = .object(["name": .string("MyClip Memory · " + libraryID.prefix(8)), "mimeType": .string("application/vnd.google-apps.folder"),
                                       "parents": .array([.string(parent)]), "appProperties": properties(id: "root", libraryID: libraryID)])
        let request = try CloudHTTP.request(url("files", query: ["fields": "id,name"]), method: "POST", token: token, body: body)
        return try remote(await http.json(request), key: "root", folder: true)
    }

    func list(root: String, libraryID: String) async throws -> [CloudRemoteItem] {
        let query = "trashed = false and '\(root)' in parents and appProperties has { key='myclip_library' and value='\(libraryID)' }"
        return try await files(query).compactMap { file in
            guard let key = file["appProperties"]["myclip_id"].string, key != "root" else { return nil }
            return try remote(file, key: key)
        }
    }

    func create(_ document: CloudMemoryDocument, root: String, libraryID: String) async throws -> CloudRemoteItem {
        let body: CloudJSON = .object(["name": .string(document.path), "mimeType": .string(documentType), "parents": .array([.string(root)]),
                                       "appProperties": properties(id: document.id, libraryID: libraryID)])
        let request = try CloudHTTP.request(url("files", query: ["fields": "id,name"]), method: "POST", token: token, body: body)
        return try remote(await http.json(request), key: document.id)
    }
    func verify(_ item: CloudRemoteItem, document: CloudMemoryDocument) async throws {
        guard item.key == document.id else { throw CloudSyncError.message(String(localized: "云端文件归属不匹配，请检查目标目录。")) }
    }
    func exists(_ item: CloudSyncItem) async throws -> Bool {
        do { return try await !get("files/" + item.remoteID, query: ["fields": "id,trashed"])["trashed"].bool }
        catch CloudSyncError.http(404) { return false }
    }

    func update(_ document: CloudMemoryDocument, item: CloudSyncItem, markdown: String) async throws {
        guard markdown.utf8.count <= 4_000_000 else { throw CloudSyncError.message(String(localized: "记忆文件过大，请拆分后再同步：\(document.path)")) }
        let boundary = "myclip-" + UUID().uuidString
        let metadata = try JSONEncoder().encode(CloudJSON.object(["name": .string(document.path), "mimeType": .string(documentType)]))
        var body = Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8)
        body.append(metadata)
        body.append(Data("\r\n--\(boundary)\r\nContent-Type: text/markdown; charset=UTF-8\r\n\r\n\(markdown)\r\n--\(boundary)--\r\n".utf8))
        var request = try CloudHTTP.request(url("files/" + item.remoteID, query: ["uploadType": "multipart", "fields": "id"], upload: true), method: "PATCH", token: token)
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        _ = try await http.send(request)
    }

    func remove(_ item: CloudSyncItem) async throws {
        let request = try CloudHTTP.request(url("files/" + item.remoteID), method: "PATCH", token: token, body: .object(["trashed": .bool(true)]))
        do { _ = try await http.send(request) } catch CloudSyncError.http(404) { return }
    }

    private func properties(id: String, libraryID: String) -> CloudJSON {
        .object(["myclip_id": .string(id), "myclip_library": .string(libraryID)])
    }
    private func remote(_ file: CloudJSON, key: String, folder: Bool = false) throws -> CloudRemoteItem {
        let id = try file.required("id")
        return CloudRemoteItem(id: id, url: folder ? "https://drive.google.com/drive/folders/\(id)" : "https://docs.google.com/document/d/\(id)/edit", key: key, name: file["name"].string ?? "")
    }
    private func files(_ query: String) async throws -> [CloudJSON] {
        var result: [CloudJSON] = [], next: String?
        repeat {
            var params = ["q": query, "pageSize": "1000", "fields": "nextPageToken,incompleteSearch,files(id,name,mimeType,appProperties)"]
            if let next { params["pageToken"] = next }
            let page = try await get("files", query: params)
            guard case .array = page["files"], !page["incompleteSearch"].bool else {
                throw CloudSyncError.message(String(localized: "Google Drive 未返回完整的文件列表，请重试。"))
            }
            result += page["files"].array; next = page["nextPageToken"].string
        } while next != nil
        return result
    }
    private func get(_ path: String, query: [String: String] = [:]) async throws -> CloudJSON {
        try await http.json(CloudHTTP.request(url(path, query: query), token: token))
    }
    private func url(_ path: String, query: [String: String] = [:], upload: Bool = false) -> URL {
        var components = URLComponents(string: "https://www.googleapis.com/\(upload ? "upload/" : "")drive/v3/\(path)")!
        components.queryItems = query.sorted { $0.key < $1.key }.map(URLQueryItem.init)
        return components.url!
    }
}

struct NotionMemoryStore: CloudRemoteStore {
    let http: CloudHTTP
    let token: String

    static func pageID(_ input: String) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = UUID(uuidString: value) { return id.uuidString.lowercased() }
        let candidate: String
        if let url = URL(string: value), url.scheme != nil {
            guard url.scheme == "https", let host = url.host, host == "notion.so" || host.hasSuffix(".notion.so") || host == "notion.site" || host.hasSuffix(".notion.site") else {
                throw CloudSyncError.message(String(localized: "请输入 Notion 页面链接或 ID。"))
            }
            candidate = url.lastPathComponent.replacingOccurrences(of: "-", with: "")
        } else { candidate = value.replacingOccurrences(of: "-", with: "") }
        let suffix = String(candidate.suffix(32))
        guard suffix.count == 32, suffix.allSatisfy(\.isHexDigit) else { throw CloudSyncError.message(String(localized: "Notion 页面 ID 无效。")) }
        let offsets = [0, 8, 12, 16, 20, 32]
        let parts = zip(offsets, offsets.dropFirst()).map { start, end in String(suffix.dropFirst(start).prefix(end - start)) }
        guard let id = UUID(uuidString: parts.joined(separator: "-")) else { throw CloudSyncError.message(String(localized: "Notion 页面 ID 无效。")) }
        return id.uuidString.lowercased()
    }
    func account(parent: String) async throws -> (id: String, name: String) {
        let user = try await api("users/me")
        let page = try await api("pages/" + parent)
        guard !page["in_trash"].bool, !page["archived"].bool else { throw CloudSyncError.http(404) }
        return (try user.required("id"), user["bot"]["workspace_name"].string ?? user["name"].string ?? "Notion")
    }
    func root(parent: String, existing: String?, libraryID: String) async throws -> CloudRemoteItem {
        if let existing {
            let page = try await api("pages/" + existing)
            guard !page["in_trash"].bool, !page["archived"].bool else { throw CloudSyncError.http(404) }
            try await verifyRoot(existing, libraryID: libraryID)
            return try remote(page, key: "root")
        }
        let name = "MyClip Memory · " + libraryID.prefix(8)
        let matches = try await children(parent).filter { $0.name == name }
        guard matches.count <= 1 else { throw CloudSyncError.message(String(localized: "发现重复的 MyClip 云端目录，请保留一份后重试。")) }
        if let item = matches.first { try await verifyRoot(item.id, libraryID: libraryID); return item }
        return try await createPage(parent: parent, title: name, key: "root", marker: "MyClip library ID: " + libraryID)
    }
    func list(root: String, libraryID: String) async throws -> [CloudRemoteItem] { try await children(root) }
    func create(_ document: CloudMemoryDocument, root: String, libraryID: String) async throws -> CloudRemoteItem {
        try await createPage(parent: root, title: document.path, key: document.id, marker: "MyClip memory ID: " + document.id)
    }
    func verify(_ item: CloudRemoteItem, document: CloudMemoryDocument) async throws {
        let content = try await api("pages/" + item.id + "/markdown")
        guard content["markdown"].string?.hasPrefix("MyClip memory ID: " + document.id) == true else {
            throw CloudSyncError.message(String(localized: "云端存在同名页面，但无法确认由 MyClip 创建，未覆盖：\(document.path)"))
        }
    }
    func exists(_ item: CloudSyncItem) async throws -> Bool {
        do {
            let page = try await api("pages/" + item.remoteID)
            return !page["in_trash"].bool && !page["archived"].bool
        } catch CloudSyncError.http(404) { return false }
    }
    func update(_ document: CloudMemoryDocument, item: CloudSyncItem, markdown: String) async throws {
        guard markdown.utf8.count <= 400_000 else { throw CloudSyncError.message(String(localized: "记忆文件超过 Notion 单次写入限制，请拆分后再同步：\(document.path)")) }
        if item.path != document.path {
            _ = try await api("pages/" + item.remoteID, method: "PATCH", body: .object(["properties": title(document.path)]))
        }
        let payload: CloudJSON = .object([
            "type": .string("replace_content"), "replace_content": .object(["new_str": .string(markdown)]), "allow_async": .bool(false)
        ])
        guard try JSONEncoder().encode(payload).count <= 450_000 else {
            throw CloudSyncError.message(String(localized: "记忆文件超过 Notion 单次写入限制，请拆分后再同步：\(document.path)"))
        }
        let result = try await api("pages/" + item.remoteID + "/markdown", method: "PATCH", body: payload)
        guard result["warnings"].array.isEmpty else {
            throw CloudSyncError.message(String(localized: "Notion 未完整保留文档格式或内容，请检查云端副本：\(document.path)"))
        }
    }
    func remove(_ item: CloudSyncItem) async throws {
        do { _ = try await api("pages/" + item.remoteID, method: "PATCH", body: .object(["in_trash": .bool(true)])) }
        catch CloudSyncError.http(404) { return }
    }
    private func verifyRoot(_ id: String, libraryID: String) async throws {
        let content = try await api("pages/" + id + "/markdown")
        guard content["markdown"].string?.hasPrefix("MyClip library ID: " + libraryID) == true else {
            throw CloudSyncError.message(String(localized: "云端目录缺少 MyClip 归属标识，未修改其内容，请检查目标位置。"))
        }
    }
    private func createPage(parent: String, title text: String, key: String, marker: String) async throws -> CloudRemoteItem {
        let page = try await api("pages", method: "POST", body: .object(["parent": .object(["type": .string("page_id"), "page_id": .string(parent)]),
            "properties": title(text), "markdown": .string(marker)]))
        return try remote(page, key: key)
    }
    private func title(_ value: String) -> CloudJSON {
        .object(["title": .object(["type": .string("title"), "title": .array([.object(["type": .string("text"), "text": .object(["content": .string(value)])])])])])
    }
    private func remote(_ page: CloudJSON, key: String) throws -> CloudRemoteItem {
        let id = try page.required("id")
        return CloudRemoteItem(id: id, url: "https://www.notion.so/" + id.replacingOccurrences(of: "-", with: ""), key: key, name: "")
    }
    private func children(_ root: String) async throws -> [CloudRemoteItem] {
        var result: [CloudRemoteItem] = [], next: String?
        repeat {
            var components = URLComponents(string: "https://api.notion.com/v1/blocks/\(root)/children")!
            components.queryItems = [URLQueryItem(name: "page_size", value: "100")] + (next.map { [URLQueryItem(name: "start_cursor", value: $0)] } ?? [])
            let page = try await http.json(CloudHTTP.request(components.url!, token: token, notion: true))
            guard case .array = page["results"], case .bool = page["has_more"] else {
                throw CloudSyncError.message(String(localized: "Notion 分页响应不完整，请重试。"))
            }
            for block in page["results"].array where block["type"].string == "child_page" {
                let id = try block.required("id")
                result.append(CloudRemoteItem(id: id, url: "https://www.notion.so/" + id.replacingOccurrences(of: "-", with: ""), key: "", name: try block["child_page"].required("title")))
            }
            next = page["has_more"].bool ? page["next_cursor"].string : nil
            if page["has_more"].bool && next == nil { throw CloudSyncError.message(String(localized: "Notion 分页响应不完整，请重试。")) }
        } while next != nil
        return result
    }
    private func api(_ path: String, method: String = "GET", body: CloudJSON? = nil) async throws -> CloudJSON {
        try await http.json(CloudHTTP.request(URL(string: "https://api.notion.com/v1/" + path)!, method: method, token: token, body: body, notion: true))
    }
}
