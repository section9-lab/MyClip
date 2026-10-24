import Foundation

public struct ACPModelOption: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let description: String?
    public let group: String?
    /// Nil means the Agent has not declared this model's image capability.
    public var supportsImages: Bool?

    public init(id: String, name: String, description: String? = nil, group: String? = nil, supportsImages: Bool? = nil) {
        self.id = id; self.name = name; self.description = description; self.group = group; self.supportsImages = supportsImages
    }
}

public struct ACPModelSelection: Sendable, Equatable {
    public var currentID: String?
    public var options: [ACPModelOption]
    public let configID: String?
    public let usesLegacyAPI: Bool
    public var canSelect: Bool { (configID != nil || usesLegacyAPI) && !options.isEmpty }
    public var current: ACPModelOption? { options.first { $0.id == currentID } }

    public init(currentID: String? = nil, options: [ACPModelOption] = [], configID: String? = nil, usesLegacyAPI: Bool = false) {
        self.currentID = currentID; self.options = options; self.configID = configID; self.usesLegacyAPI = usesLegacyAPI
    }

    public func annotatingImages(_ capabilities: [String: Bool]) -> Self {
        var copy = self
        copy.options = options.map { option in
            var option = option
            if let supported = capabilities[option.id] { option.supportsImages = supported }
            return option
        }
        return copy
    }
}

/// Enrich only exact IDs from OpenCode's own local catalog; never guess capabilities from a model's name.
public enum OpenCodeModelCatalog {
    private struct Provider: Decodable { let models: [String: Model]? }
    private struct Model: Decodable {
        let attachment: Bool?
        let modalities: Modalities?
        struct Modalities: Decodable { let input: [String]? }
    }

    public static func imageCapabilities(data: Data) throws -> [String: Bool] {
        let providers = try JSONDecoder().decode([String: Provider].self, from: data)
        var result: [String: Bool] = [:]
        for (provider, value) in providers {
            for (id, model) in value.models ?? [:] {
                if let input = model.modalities?.input { result[provider + "/" + id] = input.contains("image") }
                else if model.attachment == false { result[provider + "/" + id] = false }
            }
        }
        return result
    }

    public static func localImageCapabilities() -> [String: Bool] {
        let cache = ProcessInfo.processInfo.environment["XDG_CACHE_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache")
        let url = cache.appendingPathComponent("opencode/models.json")
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 16_000_000,
              let data = try? Data(contentsOf: url) else { return [:] }
        return (try? imageCapabilities(data: data)) ?? [:]
    }
}
