import Foundation

public struct HistoryRecord: Codable, Identifiable, Sendable {
    public let id: UUID
    public let date: Date
    public let title: String
    public let detail: String
    public let demo: Bool
    public let outcome: String
    public let artifactFolder: URL?
    public let manifest: OperationManifest?
    public init(title: String, detail: String, demo: Bool = false, outcome: String = "completed", result: OperationResult? = nil, id: UUID = UUID(), date: Date = Date()) {
        self.id = id; self.date = date; self.title = title; self.detail = detail; self.demo = demo; self.outcome = outcome
        self.artifactFolder = result?.folder; self.manifest = result?.manifest
    }
}
public struct HistoryStore: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }
    private struct Archive: Codable { let version: Int; let records: [HistoryRecord] }
    public func load() -> [HistoryRecord] {
        guard let data = try? Data(contentsOf: url), let archive = try? JSONDecoder().decode(Archive.self,from:data), archive.version == 1 else { return [] }
        return archive.records
    }
    public func save(_ records: [HistoryRecord]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),withIntermediateDirectories:true)
        if FileManager.default.fileExists(atPath:url.path), let old = try? Data(contentsOf:url), (try? JSONDecoder().decode(Archive.self,from:old))?.version != 1 {
            try FileManager.default.moveItem(at:url,to:url.appendingPathExtension("corrupt-\(UUID().uuidString)"))
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        try encoder.encode(Archive(version:1,records:Array(records.prefix(250)))).write(to:url,options:.atomic)
    }
    public func clear() throws { try save([]) }
}
