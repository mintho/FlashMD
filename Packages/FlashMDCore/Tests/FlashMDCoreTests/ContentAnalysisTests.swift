import Foundation
import Testing
@testable import FlashMDCore

@Test func erasedTailSuggestsHeaderSizeWithoutChangingData() throws {
    let data = fixtureROM() + Data(repeating:0xFF,count:0x200000-65536)
    let analysis = try ROMContentAnalysis.analyze(data,headerBytes:65536)
    #expect(analysis.suggestedBytes == 65536)
    #expect(analysis.nonErasedBytesBeyondHeader == 0)
    #expect(analysis.trailingErasedBytes == data.count-65536)
    #expect(analysis.sha256 == hash(data))
}

@Test func underreportedHeaderKeepsAdditionalDataAndRoundsUp() throws {
    var data = fixtureROM(bytes:0x100000) + Data(repeating:0xFF,count:0x100000)
    data[0x1A0030] = 0x12
    let analysis = try ROMContentAnalysis.analyze(data,headerBytes:0x100000)
    #expect(analysis.suggestedBytes == 0x1C0000)
    #expect(analysis.nonErasedBytesBeyondHeader == 1)
    #expect(analysis.explanation.contains("earlier flash"))
}

@Test func zeroTailAndRepeatedBlocksAreNotSilentlyDiscarded() throws {
    let game = fixtureROM(bytes:0x100000)
    let zeroTail = try ROMContentAnalysis.analyze(game + Data(count:0x100000),headerBytes:0x100000)
    #expect(zeroTail.suggestedBytes == 0x200000)
    let mirrored = try ROMContentAnalysis.analyze(game+game,headerBytes:0x100000)
    #expect(mirrored.possibleMirrorBytes == 0x100000)
    #expect(mirrored.suggestedBytes == 0x200000)
}

@Test func blankAndOversizedHeaderCannotCreateInvalidSuggestion() throws {
    let blank = try ROMContentAnalysis.analyze(Data(repeating:0xFF,count:0x100000),headerBytes:0x100000)
    #expect(blank.suggestedBytes == nil)
    let invalidHeader = try ROMContentAnalysis.analyze(fixtureROM(bytes:0x100000),headerBytes:0x800000)
    #expect(invalidHeader.suggestedBytes == 0x100000)
}

@Test func scanReadsOnlyConfiguredROMRangeAndDoesNotWrite() throws {
    let device = MemoryDevice(), snapshot = try device.inspect(profile:.automatic)
    let result = try ROMContentAnalysis.read(device:device,cartridge:snapshot,progress:{_ in})
    #expect(result.scannedBytes == 0x200000)
    #expect(device.reads.reduce(0,+) == snapshot.romReadLimit)
    #expect(device.erasures == 0 && device.programs == 0 && device.restores == 0)
    device.shortRead = true
    #expect(throws:(any Error).self) { try ROMContentAnalysis.read(device:device,cartridge:snapshot,progress:{_ in}) }
}

@Test func analysisStopsOnCancellationBeforeReading() async throws {
    let device = MemoryDevice(), snapshot = try device.inspect(profile:.automatic)
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try ROMContentAnalysis.read(device:device,cartridge:snapshot,progress:{_ in})
    }
    do { _ = try await task.value; Issue.record("Expected cancellation") } catch {}
    #expect(device.reads.isEmpty)
}

@Test func shorterExportRejectsChangedContentsBeyondItsEnd() throws {
    let device = MemoryDevice(), snapshot = try device.inspect(profile:.automatic), destination = try tempFolder()
    defer { try? FileManager.default.removeItem(at:destination) }
    let analysis = try ROMContentAnalysis.read(device:device,cartridge:snapshot,progress:{_ in})
    let request = try BackupRequest(cartridge:snapshot,romBytes:analysis.suggestedBytes,saveLayout:nil,verify:true,destination:destination,contentAnalysis:analysis)
    device.rom[0x180000] = 0x12
    #expect(throws:(any Error).self) { try OperationRunner.backup(device:device,request:request,progress:{_ in}) }
    #expect(try FileManager.default.contentsOfDirectory(atPath:destination.path).isEmpty)
}
