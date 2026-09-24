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

public extension TokenUsageSummary {
    mutating func add(_ usage: TokenUsage?) {
        calls += 1
        guard let usage else { return }
        reportedCalls += 1
        totalTokens = (totalTokens ?? 0) + usage.totalTokens
        inputTokens = (inputTokens ?? 0) + usage.inputTokens
        outputTokens = (outputTokens ?? 0) + usage.outputTokens
        if let read = usage.cachedReadTokens { cachedReadTokens = (cachedReadTokens ?? 0) + read }
        if let write = usage.cachedWriteTokens { cachedWriteTokens = (cachedWriteTokens ?? 0) + write }
    }

    mutating func add(_ other: TokenUsageSummary) {
        calls += other.calls
        reportedCalls += other.reportedCalls
        func merge(_ lhs: inout Int?, _ rhs: Int?) { if let rhs { lhs = (lhs ?? 0) + rhs } }
        merge(&totalTokens, other.totalTokens)
        merge(&inputTokens, other.inputTokens)
        merge(&outputTokens, other.outputTokens)
        merge(&cachedReadTokens, other.cachedReadTokens)
        merge(&cachedWriteTokens, other.cachedWriteTokens)
    }

    /// Share of prompt tokens the provider served from cache. Nil until something has been reported.
    var cacheHitRate: Double? {
        guard let input = inputTokens else { return nil }
        let read = cachedReadTokens ?? 0
        let prompt = input + read + (cachedWriteTokens ?? 0)
        return prompt > 0 ? Double(read) / Double(prompt) : nil
    }
}

/// One local calendar day of recorded usage, split by Agent.
public struct TokenUsageDay: Sendable, Identifiable {
    public let day: Date
    public var agents: [ClipAgent: TokenUsageSummary] = [:]
    public var total = TokenUsageSummary()
    public var id: Date { day }
    public init(day: Date) { self.day = day }
}

public struct TokenUsageStatistics: Sendable {
    public static let historyDays = 90
    public var total = TokenUsageSummary()
    public var agents: [ClipAgent: TokenUsageSummary] = [:]
    public var jobs: [UUID: TokenUsageSummary] = [:]
    /// Days with at least one request in the last `historyDays`, oldest first.
    public var history: [TokenUsageDay] = []
    public init() {}

    /// Usage over the trailing `days` (nil for everything recorded), summed from the daily history.
    public func summary(days: Int?, calendar: Calendar = .current, now: Date = Date()) -> TokenUsageSummary {
        guard let days else { return total }
        return period(days: days, endingAt: now, calendar: calendar)
    }

    /// The same window one period earlier, for a like-for-like change.
    public func previousSummary(days: Int, calendar: Calendar = .current, now: Date = Date()) -> TokenUsageSummary {
        period(days: days, endingAt: calendar.date(byAdding: .day, value: -days, to: now) ?? now, calendar: calendar)
    }

    private func period(days: Int, endingAt end: Date, calendar: Calendar) -> TokenUsageSummary {
        let endDay = calendar.startOfDay(for: end)
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: endDay) ?? endDay
        var result = TokenUsageSummary()
        for day in history where day.day >= start && day.day <= endDay { result.add(day.total) }
        return result
    }
}

extension LibraryStore {
    public func recordTokenUsage(id: UUID = UUID(), agent: ClipAgent, jobID: UUID? = nil, usage: TokenUsage?) throws {
        try database.run("INSERT INTO token_usage VALUES(?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO NOTHING", [
            id.uuidString, agent.rawValue, jobID?.uuidString, String(Date().timeIntervalSince1970),
            usage.map { String($0.totalTokens) }, usage.map { String($0.inputTokens) }, usage.map { String($0.outputTokens) },
            usage?.cachedReadTokens.map(String.init), usage?.cachedWriteTokens.map(String.init), usage?.thoughtTokens.map(String.init)
        ])
    }

    public func tokenUsageStatistics(calendar: Calendar = .current, now: Date = Date()) throws -> TokenUsageStatistics {
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
        result.history = try tokenUsageHistory(calendar: calendar, now: now)
        return result
    }

    func tokenUsageHistory(calendar: Calendar, now: Date) throws -> [TokenUsageDay] {
        let start = calendar.date(byAdding: .day, value: -(TokenUsageStatistics.historyDays - 1), to: calendar.startOfDay(for: now)) ?? .distantPast
        var days: [Date: TokenUsageDay] = [:]
        for row in try database.run("SELECT agent,recorded_at,total_tokens,input_tokens,output_tokens,cached_read_tokens,cached_write_tokens FROM token_usage WHERE recorded_at>=?",
                                    [String(start.timeIntervalSince1970)]) {
            guard let agent = row["agent"].flatMap(ClipAgent.init(rawValue:)), let recorded = row["recorded_at"].flatMap(Double.init) else { continue }
            var usage: TokenUsage?
            if let total = row["total_tokens"].flatMap(Int.init), let input = row["input_tokens"].flatMap(Int.init), let output = row["output_tokens"].flatMap(Int.init) {
                usage = TokenUsage(totalTokens: total, inputTokens: input, outputTokens: output,
                    cachedReadTokens: row["cached_read_tokens"].flatMap(Int.init), cachedWriteTokens: row["cached_write_tokens"].flatMap(Int.init))
            }
            let day = calendar.startOfDay(for: Date(timeIntervalSince1970: recorded))
            var bucket = days[day] ?? TokenUsageDay(day: day)
            bucket.total.add(usage)
            bucket.agents[agent, default: TokenUsageSummary()].add(usage)
            days[day] = bucket
        }
        return days.values.sorted { $0.day < $1.day }
    }
}
