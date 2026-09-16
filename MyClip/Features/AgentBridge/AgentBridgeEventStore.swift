import Foundation

actor AgentBridgeEventStore {
    private let directory: URL
    private let eventLogURL: URL
    private let metaURL: URL
    private let startConfigURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var seqCounter: Int

    init(directory: URL = AgentBridgeEventStore.defaultDirectory()) {
        self.directory = directory
        eventLogURL = directory.appendingPathComponent("event-log.ndjson")
        metaURL = directory.appendingPathComponent("bridge-meta.json")
        startConfigURL = directory.appendingPathComponent("start-config.json")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        seqCounter = AgentBridgeEventStore.readLastSequence(from: eventLogURL)
    }

    func append(
        _ kind: AgentBridgeEventKind,
        turnID: UUID?,
        message: String,
        payload: [String: String] = [:]
    ) async -> AgentBridgeEvent {
        seqCounter += 1
        let event = AgentBridgeEvent(
            seq: seqCounter,
            turnID: turnID,
            kind: kind,
            message: message,
            payload: payload
        )
        writeEvent(event)
        return event
    }

    func replay(after sequence: Int) async -> [AgentBridgeEvent] {
        loadEvents().filter { $0.seq > sequence }
    }

    func recent(limit: Int) async -> [AgentBridgeEvent] {
        Array(loadEvents().suffix(limit))
    }

    func writeMeta(state: AgentBridgeState, activeTurnID: UUID?) async {
        let meta = AgentBridgeMeta(
            state: state,
            activeTurnID: activeTurnID,
            lastSeq: seqCounter,
            updatedAt: Date()
        )
        writeJSON(meta, to: metaURL)
    }

    func writeStartConfig(_ config: AgentBridgeStartConfig) async {
        writeJSON(config, to: startConfigURL)
    }

    private func writeEvent(_ event: AgentBridgeEvent) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try encoder.encode(event)
            var line = data
            line.append(Data("\n".utf8))

            if FileManager.default.fileExists(atPath: eventLogURL.path) {
                let handle = try FileHandle(forWritingTo: eventLogURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
                try handle.close()
            } else {
                try line.write(to: eventLogURL)
            }
        } catch {
            print("[Kara] AgentBridge event write failed: \(error.localizedDescription)")
        }
    }

    private func loadEvents() -> [AgentBridgeEvent] {
        guard let text = try? String(contentsOf: eventLogURL, encoding: .utf8) else {
            return []
        }

        return text
            .split(separator: "\n")
            .compactMap { line in
                guard let data = String(line).data(using: .utf8) else { return nil }
                return try? decoder.decode(AgentBridgeEvent.self, from: data)
            }
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try encoder.encode(value)
            try data.write(to: url, options: .atomic)
        } catch {
            print("[Kara] AgentBridge metadata write failed: \(error.localizedDescription)")
        }
    }

    private static func defaultDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Kara/Bridge", isDirectory: true)
    }

    private static func readLastSequence(from url: URL) -> Int {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return 0
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text
            .split(separator: "\n")
            .compactMap { line -> Int? in
                guard let data = String(line).data(using: .utf8),
                      let event = try? decoder.decode(AgentBridgeEvent.self, from: data)
                else {
                    return nil
                }
                return event.seq
            }
            .max() ?? 0
    }
}
