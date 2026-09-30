import Foundation
import Testing
@testable import FlashMDCore

@Test func backupNamesAreVisibleSafeAndBounded() {
    #expect(OperationRunner.backupName(for:"  ../SONIC: THE HEDGEHOG/  ") == "SONIC THE HEDGEHOG")
    #expect(OperationRunner.backupName(for:"... / : \u{0}\n") == "Untitled Cartridge")
    #expect(OperationRunner.backupName(for:"Pokémon   —  日本") == "Pokémon — 日本")
    #expect(OperationRunner.backupName(for:String(repeating:"日本",count:100)).utf8.count <= 120)
}

@Test func repeatedBackupsHaveSeparateFoldersAndPreserveContents() throws {
    let device = MemoryDevice(), destination = try tempFolder()
    defer { try? FileManager.default.removeItem(at:destination) }
    let target = try device.inspect(profile:.automatic)
    let request = try BackupRequest(cartridge:target,romBytes:65536,saveLayout:nil,verify:false,destination:destination)
    let first = try OperationRunner.backup(device:device,request:request,progress:{_ in})
    let second = try OperationRunner.backup(device:device,request:request,progress:{_ in})
    #expect(first.folder != second.folder)
    for result in [first,second] {
        let folder = try #require(result.folder), artifact = try #require(result.manifest.artifacts.first)
        #expect(try Data(contentsOf:folder.appendingPathComponent(artifact.filename)) == Data(device.rom.prefix(65536)))
        #expect(try FileManager.default.contentsOfDirectory(atPath:folder.path).sorted() == ["TEST GAME.bin","manifest.json"])
    }
}

@Test func backupExactSizeAndAtomicArtifacts() throws {
    let device = MemoryDevice(), destination = try tempFolder()
    defer { try? FileManager.default.removeItem(at:destination) }
    let target = try device.inspect(profile:.krikzz4M)
    let request = try BackupRequest(cartridge:target,romBytes:65537,saveLayout:target.saveLayout,verify:true,destination:destination)
    let result = try OperationRunner.backup(device:device,request:request,progress:{_ in})
    let folder = try #require(result.folder)
    let rom = try #require(result.manifest.artifacts.first(where: { $0.isROM }))
    let file = try Data(contentsOf:folder.appendingPathComponent(rom.filename))
    #expect(folder.lastPathComponent.hasPrefix("TEST GAME — "))
    #expect(result.manifest.artifacts.map(\.filename) == ["TEST GAME.bin","TEST GAME.srm"])
    for artifact in result.manifest.artifacts {
        let url = folder.appendingPathComponent(artifact.filename)
        #expect(try url.resourceValues(forKeys:[.isHiddenKey]).isHidden == false)
    }
    #expect(file.count == 65537); #expect(device.reads.contains(1)); #expect(result.manifest.artifacts.count == 2)
    #expect(result.manifest.artifacts.allSatisfy { $0.verified }); #expect(result.manifest.artifacts[0].sha256 == hash(file))
    #expect(FileManager.default.fileExists(atPath:result.folder!.appendingPathComponent("manifest.json").path))
}
@Test func partialBackupRetainsSuccessfulROM() throws {
    let device = MemoryDevice(), destination = try tempFolder(); defer { try? FileManager.default.removeItem(at:destination) }
    let target = try device.inspect(profile:.krikzz4M); device.failSaveRead = true
    do {
        _ = try OperationRunner.backup(device:device,request:BackupRequest(cartridge:target,romBytes:65536,saveLayout:target.saveLayout,verify:false,destination:destination),progress:{_ in})
        Issue.record("Expected SRAM failure")
    } catch let failure as OperationFailure {
        #expect(failure.result.manifest.outcome == "partial"); #expect(failure.result.manifest.artifacts.count == 1)
        let artifact = try #require(failure.result.manifest.artifacts.first)
        #expect(FileManager.default.fileExists(atPath:failure.result.folder!.appendingPathComponent(artifact.filename).path))
    }
}
@Test func backupFailurePreventsDestructiveWrite() throws {
    let device = MemoryDevice(), destination = try tempFolder(); defer { try? FileManager.default.removeItem(at:destination) }
    let target = try device.inspect(profile:.krikzz4M), image = try ROMImage(data:fixtureROM(title:"NEW GAME"))
    let plan = try WritePlan(target:target,image:image,romName:"new.bin",save:Data(count:65536),saveName:"save.srm",format:.raw,backupDestination:destination)
    device.failSaveRead = true
    #expect(throws:(any Error).self) { try OperationRunner.write(device:device,plan:plan,progress:{_ in}) }
    #expect(device.erasures == 0); #expect(device.programs == 0)
}
@Test func combinedWriteVerifiesAndPreservesInactiveSaveBytes() throws {
    let device = MemoryDevice(), target = try device.inspect(profile:.krikzz4M)
    let image = try ROMImage(data:fixtureROM(bytes:65538,title:"NEW GAME")), packed = Data(repeating:0x77,count:8192)
    let plan = try WritePlan(target:target,image:image,romName:"new.bin",save:packed,saveName:"save.srm",format:.packed,backupDestination:nil)
    #expect(plan.requiredBytes == 131072)
    let result = try OperationRunner.write(device:device,plan:plan,progress:{_ in})
    #expect(result.manifest.outcome == "completed"); #expect(result.manifest.phases.contains("SRAM verified"))
    #expect(Data(device.rom.prefix(image.data.count)) == image.data)
    #expect(device.rom[image.data.count..<plan.requiredBytes].allSatisfy { $0 == 0xFF })
    #expect(device.sram[0] == 0xA5); #expect(device.sram[1] == 0x77)
}
@Test func romOnlyPreservesEntireSave() throws {
    let device = MemoryDevice(), oldSave = device.sram, target = try device.inspect(profile:.krikzz4M)
    let plan = try WritePlan(target:target,image:ROMImage(data:fixtureROM(title:"NEW GAME")),romName:"new.bin",save:nil,saveName:nil,format:.raw,backupDestination:nil)
    _ = try OperationRunner.write(device:device,plan:plan,progress:{_ in})
    #expect(device.sram == oldSave); #expect(device.restores == 0)
}
@Test func sramOnlyNeverErasesROM() throws {
    let device = MemoryDevice(), oldROM = device.rom, target = try device.inspect(profile:.krikzz4M)
    let plan = try WritePlan(target:target,image:nil,romName:nil,save:Data(repeating:0x66,count:65536),saveName:"save.srm",format:.raw,backupDestination:nil)
    _ = try OperationRunner.write(device:device,plan:plan,progress:{_ in})
    #expect(device.erasures == 0); #expect(device.rom == oldROM); #expect(device.sram[1] == 0x66)
}
@Test func writeMismatchNeverReportsSuccess() throws {
    let device = MemoryDevice(), target = try device.inspect(profile:.krikzz4M)
    let plan = try WritePlan(target:target,image:ROMImage(data:fixtureROM()),romName:"new.bin",save:nil,saveName:nil,format:.raw,backupDestination:nil)
    device.corruptProgram = true
    do { _ = try OperationRunner.write(device:device,plan:plan,progress:{_ in}); Issue.record("Expected verification failure") }
    catch let failure as OperationFailure { #expect(failure.result.manifest.outcome == "failed"); #expect(failure.message.contains("incomplete")) }
}
@Test func staleTargetsCannotBeWritten() throws {
    let device = MemoryDevice(), target = try device.inspect(profile:.krikzz4M)
    let plan = try WritePlan(target:target,image:ROMImage(data:fixtureROM()),romName:"new.bin",save:nil,saveName:nil,format:.raw,backupDestination:nil)
    device.changedIdentity = true
    #expect(throws:(any Error).self) { try OperationRunner.write(device:device,plan:plan,progress:{_ in}) }; #expect(device.erasures == 0)
}
@Test func preflightRejectsMismatchedLengthsAndAllowsAutomaticConfiguration() throws {
    let device = MemoryDevice(), target = try device.inspect(profile:.krikzz4M)
    #expect(throws:(any Error).self) { try WritePlan(target:target,image:nil,romName:nil,save:Data(count:3),saveName:"bad.srm",format:.raw,backupDestination:nil) }
    let unqualified = try device.inspect(profile:.automatic)
    _ = try WritePlan(target:unqualified,image:ROMImage(data:fixtureROM()),romName:"new.bin",save:nil,saveName:nil,format:.raw,backupDestination:nil)
    var inconsistent = fixtureROM(); inconsistent[0x1A7] = 0
    #expect(throws:(any Error).self) { try WritePlan(target:target,image:ROMImage(data:inconsistent),romName:"bad.bin",save:nil,saveName:nil,format:.raw,backupDestination:nil) }
}
@Test func shortBackupReadsFail() throws {
    let device = MemoryDevice(), target = try device.inspect(profile:.krikzz4M), destination = try tempFolder()
    defer { try? FileManager.default.removeItem(at:destination) }; device.shortRead = true
    #expect(throws:(any Error).self) { try OperationRunner.backup(device:device,request:BackupRequest(cartridge:target,romBytes:65536,saveLayout:nil,verify:false,destination:destination),progress:{_ in}) }
}
@Test func cancelledOperationDoesNotErase() async throws {
    let device = MemoryDevice(), target = try device.inspect(profile:.krikzz4M)
    let plan = try WritePlan(target:target,image:ROMImage(data:fixtureROM()),romName:"new.bin",save:nil,saveName:nil,format:.raw,backupDestination:nil)
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try OperationRunner.write(device:device,plan:plan,progress:{_ in})
    }
    do { _ = try await task.value; Issue.record("Expected cancellation") } catch {}
    #expect(device.erasures == 0)
}

@Test func cancellationStopsAfterCurrentEraseBeforeProgramming() async throws {
    let device = MemoryDevice(), target = try device.inspect(profile:.krikzz4M)
    let plan = try WritePlan(target:target,image:ROMImage(data:fixtureROM()),romName:"new.bin",save:nil,saveName:nil,format:.raw,backupDestination:nil)
    let task = Task {
        try OperationRunner.write(device:device,plan:plan,progress:{ value in
            if value.phase == .erasing { withUnsafeCurrentTask { $0?.cancel() } }
        })
    }
    do { _ = try await task.value; Issue.record("Expected cancellation") }
    catch let failure as OperationFailure { #expect(failure.result.manifest.outcome == "cancelled") }
    #expect(device.erasures == 1); #expect(device.programs == 0)
}

@Test(arguments: ["erase", "program", "restore", "save verification"])
func phaseFailuresRetainAccurateResults(phase:String) throws {
    let device = MemoryDevice(), target = try device.inspect(profile:.krikzz4M)
    let plan = try WritePlan(target:target,image:ROMImage(data:fixtureROM(title:"NEW GAME")),romName:"new.bin",save:Data(count:65536),saveName:"save.srm",format:.raw,backupDestination:nil)
    device.failErase = phase == "erase"; device.failProgram = phase == "program"
    device.failRestore = phase == "restore"; device.corruptRestore = phase == "save verification"
    do { _ = try OperationRunner.write(device:device,plan:plan,progress:{_ in}); Issue.record("Expected phase failure") }
    catch let failure as OperationFailure {
        #expect(failure.result.manifest.outcome == "failed")
        #expect(!failure.result.manifest.phases.contains("SRAM verified"))
        if phase == "restore" || phase == "save verification" { #expect(failure.result.manifest.phases.contains("ROM verified")) }
    }
}
@Test func failedReadComparisonNeverPublishesROM() throws {
    let device = MemoryDevice(), target = try device.inspect(profile:.krikzz4M), destination = try tempFolder()
    defer { try? FileManager.default.removeItem(at:destination) }; device.mismatchSecondRead = true
    do {
        _ = try OperationRunner.backup(device:device,request:BackupRequest(cartridge:target,romBytes:65536,saveLayout:nil,verify:true,destination:destination),progress:{_ in})
        Issue.record("Expected read mismatch")
    } catch let failure as OperationFailure {
        #expect(failure.result.manifest.artifacts.isEmpty)
        let files = try FileManager.default.contentsOfDirectory(atPath:failure.result.folder!.path)
        #expect(files == ["manifest.json"])
    }
}
@Test func backupRejectsUnwritableDestinationAndKeepsExistingFiles() throws {
    let device = MemoryDevice(), target = try device.inspect(profile:.krikzz4M), destination = try tempFolder()
    defer { try? FileManager.default.removeItem(at:destination) }
    let sentinel = destination.appendingPathComponent("game.bin")
    try Data([0xAA]).write(to:sentinel)
    let request = try BackupRequest(cartridge:target,romBytes:65536,saveLayout:nil,verify:false,destination:destination)
    _ = try OperationRunner.backup(device:device,request:request,progress:{_ in})
    #expect(try Data(contentsOf:sentinel) == Data([0xAA]))
    let badRequest = try BackupRequest(cartridge:target,romBytes:65536,saveLayout:nil,verify:false,destination:sentinel)
    #expect(throws:(any Error).self) { try OperationRunner.backup(device:device,request:badRequest,progress:{_ in}) }
}
@Test func capacityAndPackedWindowRoundTrip() throws {
    let device = MemoryDevice(), target = try device.inspect(profile:.krikzz4M)
    #expect(throws:(any Error).self) { try BackupRequest(cartridge:target,romBytes:0x400001,saveLayout:nil,verify:false,destination:URL(fileURLWithPath:"/tmp")) }
    let layout = try #require(target.saveLayout), packed = try layout.pack(device.sram)
    let plan = try WritePlan(target:target,image:nil,romName:nil,save:packed,saveName:"save.srm",format:.packed,backupDestination:nil)
    #expect(plan.saveLayout == layout)
    #expect(plan.inputs.first?.sha256 == hash(packed))
    _ = try OperationRunner.write(device:device,plan:plan,progress:{_ in})
    #expect(try layout.pack(device.sram) == packed)
}
@Test func cancellationRemovesUnfinishedBackup() async throws {
    let device = MemoryDevice(), target = try device.inspect(profile:.krikzz4M), destination = try tempFolder()
    defer { try? FileManager.default.removeItem(at:destination) }
    let request = try BackupRequest(cartridge:target,romBytes:65536,saveLayout:nil,verify:true,destination:destination)
    let task = Task {
        try OperationRunner.backup(device:device,request:request,progress:{ value in
            if value.phase == .readingROM { withUnsafeCurrentTask { $0?.cancel() } }
        })
    }
    do { _ = try await task.value; Issue.record("Expected cancellation") }
    catch let failure as OperationFailure {
        #expect(failure.result.manifest.outcome == "cancelled")
        #expect(failure.result.manifest.artifacts.isEmpty)
        let files = try FileManager.default.contentsOfDirectory(atPath:failure.result.folder!.path)
        #expect(files == ["manifest.json"])
    }
}

@Test func allFFBackupNeverPublishesAGame() throws {
    let device = MemoryDevice(), destination = try tempFolder()
    defer { try? FileManager.default.removeItem(at:destination) }
    device.rom = Data(repeating:0xFF,count:0x400000)
    let target = try device.inspect(profile:.krikzz4M)
    let request = try BackupRequest(cartridge:target,romBytes:65536,saveLayout:nil,verify:false,destination:destination)
    do { _ = try OperationRunner.backup(device:device,request:request,progress:{_ in}); Issue.record("Expected invalid dump") }
    catch let failure as OperationFailure {
        #expect(failure.result.manifest.outcome == "failed")
        #expect(failure.result.manifest.artifacts.isEmpty)
    }
}

@Test func romOnlyProfileCannotRestoreSRAM() throws {
    let device = MemoryDevice(), target = try device.inspect(profile:.linearROMOnly)
    #expect(target.canWrite); #expect(target.saveLayout == nil)
    _ = try WritePlan(target:target,image:ROMImage(data:fixtureROM()),romName:"test.bin",save:nil,saveName:nil,format:.raw,backupDestination:nil)
    #expect(throws:(any Error).self) { try WritePlan(target:target,image:nil,romName:nil,save:Data(count:65536),saveName:"test.srm",format:.raw,backupDestination:nil) }
}

@Test func sramMapperCapsROMBeforeSaveAddresses() throws {
    let device = MemoryDevice(), target = try device.inspect(profile:.krikzz4M)
    #expect(target.flashCapacity?.bytes == 0x200000)
    #expect(target.flashCapacity?.source == .profile)
    #expect(throws:(any Error).self) { try BackupRequest(cartridge:target,romBytes:0x200001,saveLayout:nil,verify:false,destination:URL(fileURLWithPath:"/tmp")) }
    let oversized = try ROMImage(data:fixtureROM(bytes:0x210000))
    #expect(throws:(any Error).self) { try WritePlan(target:target,image:oversized,romName:"too-large.bin",save:nil,saveName:nil,format:.raw,backupDestination:nil) }
    let romOnly = try device.inspect(profile:.linearROMOnly)
    #expect(romOnly.flashCapacity?.bytes == 0x400000)
    let unqualified = try device.inspect(profile:.automatic)
    #expect(unqualified.flashCapacity?.bytes == 0x200000)
    #expect(unqualified.flashCapacity?.source == .estimated)
    #expect(throws:(any Error).self) { try BackupRequest(cartridge:unqualified,romBytes:0x200001,saveLayout:nil,verify:false,destination:URL(fileURLWithPath:"/tmp")) }
}
