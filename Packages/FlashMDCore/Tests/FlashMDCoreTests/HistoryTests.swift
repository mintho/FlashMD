import Testing
import Foundation
@testable import FlashMDCore
@Test func historyPersistenceAndClearKeepArtifacts() throws {
    let folder = try tempFolder(); defer { try? FileManager.default.removeItem(at:folder) }
    let artifact = folder.appendingPathComponent("save.srm"); try Data([1,2]).write(to:artifact)
    let store = HistoryStore(url:folder.appendingPathComponent("history.json"))
    try store.save([.init(title:"Demo inspection",detail:"Sample",demo:true)])
    #expect(store.load().first?.demo == true)
    try store.clear(); #expect(store.load().isEmpty); #expect(FileManager.default.fileExists(atPath:artifact.path))
}
@Test func corruptHistoryIsPreservedOnRecovery() throws {
    let folder = try tempFolder(); defer { try? FileManager.default.removeItem(at:folder) }
    let url = folder.appendingPathComponent("history.json"), store = HistoryStore(url:url)
    try Data("not-json".utf8).write(to:url); #expect(store.load().isEmpty)
    try store.save([.init(title:"Inspection",detail:"Test")])
    #expect(store.load().count == 1); #expect(try FileManager.default.contentsOfDirectory(atPath:folder.path).contains { $0.contains("corrupt-") })
}

@Test func unknownHistorySchemaIsPreserved() throws {
    let folder = try tempFolder(); defer { try? FileManager.default.removeItem(at:folder) }
    let store = HistoryStore(url:folder.appendingPathComponent("history.json"))
    try Data("{\"version\":99,\"records\":[]}".utf8).write(to:store.url)
    #expect(store.load().isEmpty)
    try store.save([.init(title:"New event",detail:"Recovered")])
    let files = try FileManager.default.contentsOfDirectory(atPath:folder.path)
    #expect(files.count == 2); #expect(store.load().count == 1)
}
