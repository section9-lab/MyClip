import Foundation

public struct TokenUsage: Sendable, Equatable {
    public let totalTokens: Int
    public let inputTokens: Int
    public let outputTokens: Int
    public let cachedReadTokens: Int?
    public let cachedWriteTokens: Int?
    public let thoughtTokens: Int?

    public init(totalTokens: Int, inputTokens: Int, outputTokens: Int, cachedReadTokens: Int? = nil,
                cachedWriteTokens: Int? = nil, thoughtTokens: Int? = nil) {
        self.totalTokens = totalTokens
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedReadTokens = cachedReadTokens
        self.cachedWriteTokens = cachedWriteTokens
        self.thoughtTokens = thoughtTokens
    }
}

public struct TokenUsageSummary: Sendable {
    public var calls = 0
    public var reportedCalls = 0
    public var totalTokens: Int?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cachedReadTokens: Int?
    public var cachedWriteTokens: Int?
    public init() {}
}

public struct TokenUsageStatistics: Sendable {
    public var total = TokenUsageSummary()
    public var agents: [ClipAgent: TokenUsageSummary] = [:]
    public var jobs: [UUID: TokenUsageSummary] = [:]
    public init() {}
}

extension LibraryStore {
    public func recordTokenUsage(id: UUID = UUID(), agent: ClipAgent, jobID: UUID? = nil, usage: TokenUsage?) throws {
        try database.run("INSERT INTO token_usage VALUES(?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO NOTHING", [
            id.uuidString, agent.rawValue, jobID?.uuidString, String(Date().timeIntervalSince1970),
            usage.map { String($0.totalTokens) }, usage.map { String($0.inputTokens) }, usage.map { String($0.outputTokens) },
            usage?.cachedReadTokens.map(String.init), usage?.cachedWriteTokens.map(String.init), usage?.thoughtTokens.map(String.init)
        ])
    }

    public func tokenUsageStatistics() throws -> TokenUsageStatistics {
        let columns = """
            count(*) calls,count(total_tokens) reported_calls,sum(total_tokens) total_tokens,
            sum(input_tokens) input_tokens,sum(output_tokens) output_tokens,
            sum(cached_read_tokens) cached_read_tokens,sum(cached_write_tokens) cached_write_tokens
            """
        func summary(_ row: [String: String]) -> TokenUsageSummary {
            var value = TokenUsageSummary()
            value.calls = Int(row["calls"] ?? "0") ?? 0
            value.reportedCalls = Int(row["reported_calls"] ?? "0") ?? 0
            value.totalTokens = row["total_tokens"].flatMap(Int.init)
            value.inputTokens = row["input_tokens"].flatMap(Int.init)
            value.outputTokens = row["output_tokens"].flatMap(Int.init)
            value.cachedReadTokens = row["cached_read_tokens"].flatMap(Int.init)
            value.cachedWriteTokens = row["cached_write_tokens"].flatMap(Int.init)
            return value
        }
        var result = TokenUsageStatistics()
        result.total = summary(try database.run("SELECT \(columns) FROM token_usage").first ?? [:])
        for row in try database.run("SELECT agent,\(columns) FROM token_usage GROUP BY agent") {
            if let agent = row["agent"].flatMap(ClipAgent.init(rawValue:)) { result.agents[agent] = summary(row) }
        }
        for row in try database.run("SELECT job_id,\(columns) FROM token_usage WHERE job_id IS NOT NULL GROUP BY job_id") {
            if let id = row["job_id"].flatMap(UUID.init(uuidString:)) { result.jobs[id] = summary(row) }
        }
        return result
    }
}
