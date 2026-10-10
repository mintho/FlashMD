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
    #expect(result.scannedBytes == 0x400000)
    #expect(device.reads.reduce(0,+) == snapshot.romReadLimit * 2)
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

@Test func automaticScanAndBackupKeepROMBeyondPlaceholderSaveAddress() throws {
    let device = MemoryDevice(), destination = try tempFolder()
    defer { try? FileManager.default.removeItem(at:destination) }
    device.rom = fixtureROM(bytes:0x400000,title:"SAMPLE PROGRAM")
    // A stale SDK header claims 1 MiB ROM and SRAM at 2 MiB, despite a 4 MiB game.
    device.rom.replaceSubrange(0x1A4..<0x1A8,with:Data([0,0x0F,0xFF,0xFF]))
    let oldROM = device.rom, oldSave = device.sram
    let snapshot = try device.inspect(profile:.automatic)
    #expect(snapshot.romReadLimit == 0x400000)
    #expect(snapshot.romWriteLimit == 0x200000)
    let analysis = try ROMContentAnalysis.read(device:device,cartridge:snapshot,progress:{_ in})
    #expect(analysis.scannedBytes == 0x400000 && analysis.suggestedBytes == 0x400000)
    #expect(analysis.lastNonErasedByte == 0x3FFFFF)
    let request = try BackupRequest(cartridge:snapshot,romBytes:analysis.suggestedBytes,saveLayout:nil,verify:true,destination:destination,contentAnalysis:analysis)
    let result = try OperationRunner.backup(device:device,request:request,progress:{_ in})
    let artifact = try #require(result.manifest.artifacts.first)
    #expect(artifact.bytes == 0x400000 && artifact.verified)
    #expect(try Data(contentsOf:try #require(result.folder).appendingPathComponent(artifact.filename)) == oldROM)
    #expect(device.rom == oldROM && device.sram == oldSave)
    #expect(device.erasures == 0 && device.programs == 0 && device.restores == 0)
}

@Test func scanExpansionDoesNotExpandEraseOrProgramRange() throws {
    let device = MemoryDevice(), snapshot = try device.inspect(profile:.automatic)
    let image = try ROMImage(data:fixtureROM())
    let plan = try WritePlan(target:snapshot,image:image,romName:"game.bin",save:nil,saveName:nil,format:.packed,backupDestination:nil,clearUnusedROM:true)
    #expect(plan.requiredBytes == 0x200000)
    let larger = try ROMImage(data:fixtureROM(bytes:0x210000))
    #expect(throws:(any Error).self) {
        try WritePlan(target:snapshot,image:larger,romName:"large.bin",save:nil,saveName:nil,format:.packed,backupDestination:nil,clearUnusedROM:true)
    }
    let originalSave = device.sram
    _ = try testWrite(device:device,plan:plan,progress:{_ in})
    #expect(device.sram == originalSave)
    #expect(device.rom[0x200000...] == Data(repeating:0xFF,count:0x200000))
}

@Test func shorterExportRejectsChangedContentsBeyondItsEnd() throws {
    let device = MemoryDevice(), snapshot = try device.inspect(profile:.automatic), destination = try tempFolder()
    defer { try? FileManager.default.removeItem(at:destination) }
    let analysis = try ROMContentAnalysis.read(device:device,cartridge:snapshot,progress:{_ in})
    let request = try BackupRequest(cartridge:snapshot,romBytes:analysis.suggestedBytes,saveLayout:nil,verify:true,destination:destination,contentAnalysis:analysis)
    device.rom[0x3F8000] = 0x12
    #expect(throws:(any Error).self) { try OperationRunner.backup(device:device,request:request,progress:{_ in}) }
    #expect(try FileManager.default.contentsOfDirectory(atPath:destination.path).isEmpty)
}
