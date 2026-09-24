import Foundation

public struct ExecutionCost: Codable, Sendable, Equatable {
    public let amount: Decimal
    public let currency: String
}

public struct ACPToolLocation: Codable, Sendable, Equatable {
    public let path: String
    public let line: Int?
}

public struct ACPToolContent: Codable, Sendable, Equatable {
    public let type: String
    public var text: String?
    public var path: String?
    public var oldText: String?
    public var newText: String?
}

public struct ACPToolCall: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public var title: String
    public var name: String?
    public var kind = "other"
    public var status = "pending"
    public var rawInput: String?
    public var rawOutput: String?
    public var locations: [ACPToolLocation] = []
    public var content: [ACPToolContent] = []
    public let startedAt: Date
    public var updatedAt: Date
}

public enum ACPExecutionUpdate: Sendable {
    case tool(ACPToolCall)
    case cost(ExecutionCost?)
}

public struct ExecutionRecord: Sendable, Identifiable {
    public let id: UUID
    public let sessionID: String
    public let startedAt: Date
    public let finishedAt: Date?
    public let stopReason: String?
    public let error: String?
    public let response: String?
    public let usage: TokenUsage?
    public let cost: ExecutionCost?
    public let tools: [ACPToolCall]
}

extension LibraryStore {
    public func executePrompt(_ client: ACPClient, agent: ClipAgent, sessionID: String, text: String,
                              images: [Data], jobID: UUID? = nil, maximumDuration: Duration? = nil) async throws -> ACPCompletion {
        let id = UUID()
        try database.run("INSERT INTO execution_records(id,job_id,session_id,started_at) VALUES(?,?,?,?)",
            [id.uuidString, jobID?.uuidString, sessionID, String(Date().timeIntervalSince1970)])
        let result: ACPCompletion
        do {
            result = try await client.prompt(sessionID: sessionID, text: text, images: images, maximumDuration: maximumDuration) { update in
                try await self.recordExecutionUpdate(update, id: id)
            }
        } catch {
            try database.transaction {
                try database.run("UPDATE execution_records SET finished_at=?,error=? WHERE id=?",
                    [String(Date().timeIntervalSince1970), error.localizedDescription, id.uuidString])
                try recordTokenUsage(id: id, agent: agent, jobID: jobID, usage: nil)
            }
            throw error
        }
        // Persist even cancelled results before the caller checks stopReason or parses the response.
        try database.transaction {
            try database.run("UPDATE execution_records SET finished_at=?,stop_reason=?,response=? WHERE id=?",
                [String(Date().timeIntervalSince1970), result.stopReason, result.text, id.uuidString])
            try recordTokenUsage(id: id, agent: agent, jobID: jobID, usage: result.usage)
        }
        return result
    }

    private func recordExecutionUpdate(_ update: ACPExecutionUpdate, id: UUID) throws {
        switch update {
        case .tool(let tool):
            let payload = String(decoding: try JSONEncoder().encode(tool), as: UTF8.self)
            try database.run("""
                INSERT INTO execution_tools(execution_id,tool_id,payload) VALUES(?,?,?)
                ON CONFLICT(execution_id,tool_id) DO UPDATE SET payload=excluded.payload
                """, [id.uuidString, tool.id, payload])
        case .cost(let cost):
            try database.run("UPDATE execution_records SET cost_amount=?,cost_currency=? WHERE id=?",
                [cost.map { NSDecimalNumber(decimal: $0.amount).stringValue }, cost?.currency, id.uuidString])
        }
    }

    public func executionRecords(jobID: UUID) throws -> [ExecutionRecord] {
        let rows = try database.run("""
            SELECT e.*,u.total_tokens,u.input_tokens,u.output_tokens,u.cached_read_tokens,u.cached_write_tokens,u.thought_tokens
            FROM execution_records e LEFT JOIN token_usage u ON u.id=e.id WHERE e.job_id=? ORDER BY e.started_at,e.rowid
            """, [jobID.uuidString])
        return try rows.compactMap { row in
            guard let id = row["id"].flatMap(UUID.init(uuidString:)), let session = row["session_id"],
                  let started = row["started_at"].flatMap(Double.init) else { return nil }
            var usage: TokenUsage?
            if let total = row["total_tokens"].flatMap(Int.init), let input = row["input_tokens"].flatMap(Int.init),
               let output = row["output_tokens"].flatMap(Int.init) {
                usage = TokenUsage(totalTokens: total, inputTokens: input, outputTokens: output,
                    cachedReadTokens: row["cached_read_tokens"].flatMap(Int.init),
                    cachedWriteTokens: row["cached_write_tokens"].flatMap(Int.init), thoughtTokens: row["thought_tokens"].flatMap(Int.init))
            }
            var cost: ExecutionCost?
            if let amount = row["cost_amount"].flatMap({ Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) }),
               let currency = row["cost_currency"] { cost = ExecutionCost(amount: amount, currency: currency) }
            let tools = try database.run("SELECT payload FROM execution_tools WHERE execution_id=? ORDER BY rowid", [id.uuidString])
                .compactMap { $0["payload"] }.map { try JSONDecoder().decode(ACPToolCall.self, from: Data($0.utf8)) }
            return ExecutionRecord(id: id, sessionID: session, startedAt: Date(timeIntervalSince1970: started),
                finishedAt: row["finished_at"].flatMap(Double.init).map(Date.init(timeIntervalSince1970:)),
                stopReason: row["stop_reason"], error: row["error"], response: row["response"], usage: usage, cost: cost, tools: tools)
        }
    }
}
