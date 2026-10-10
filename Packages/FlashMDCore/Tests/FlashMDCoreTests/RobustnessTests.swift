import Foundation
import Testing
@testable import FlashMDCore

@Test func unstableSoleilTailDoesNotPreventVerifiedROMAndSaveBackup() throws {
    let device = MemoryDevice(), folder = try tempFolder()
    defer { try? FileManager.default.removeItem(at:folder) }
    device.rom = fixtureROM(bytes:0x200000,title:"SOLEIL") + Data(repeating:0xFF,count:0x200000)
    device.unstableROMFrom = 0x200000
    let originalROM = Data(device.rom.prefix(0x200000)), originalSave = device.sram
    let cartridge = try device.inspect(profile:.automatic)
    let analysis = try ROMContentAnalysis.read(device:device,cartridge:cartridge,progress:{_ in})
    #expect(analysis.suggestedBytes == 0x200000 && analysis.excludedROMStart == 0x200000)
    #expect(analysis.requestedScanBytes == 0x400000 && analysis.hasUncertainRange)
    #expect(throws:(any Error).self) {
        try BackupRequest(cartridge:cartridge,romBytes:0x400000,saveLayout:nil,verify:true,destination:folder,contentAnalysis:analysis)
    }
    let request = try BackupRequest(cartridge:cartridge,romBytes:analysis.suggestedBytes,saveLayout:cartridge.saveLayout,saveFormat:.packed,verify:true,destination:folder,contentAnalysis:analysis)
    let result = try OperationRunner.backup(device:device,request:request,progress:{_ in})
    #expect(result.manifest.artifacts.count == 2 && result.manifest.artifacts.allSatisfy(\.verified))
    let output = try #require(result.folder)
    #expect(try Data(contentsOf:output.appendingPathComponent(result.manifest.artifacts[0].filename)) == originalROM)
    #expect(try Data(contentsOf:output.appendingPathComponent(result.manifest.artifacts[1].filename)) == cartridge.saveLayout!.pack(originalSave.prefix(cartridge.saveLayout!.windowBytes)))
    #expect(device.erasures == 0 && device.programs == 0 && device.restores == 0)
}

@Test func instabilityInsideDeclaredROMNeverBecomesAShorterSuccessfulBackup() throws {
    let device = MemoryDevice()
    device.rom = fixtureROM(bytes:0x200000) + Data(repeating:0xFF,count:0x200000)
    device.unstableROMFrom = 0x100000
    let cartridge = try device.inspect(profile:.automatic)
    do {
        _ = try ROMContentAnalysis.read(device:device,cartridge:cartridge,progress:{_ in})
        Issue.record("Unstable ROM must stop the scan")
    } catch let error as ROMScanMismatch {
        #expect(error.differences.first?.offset == 0x100000)
        #expect(error.firstSHA256 != error.secondSHA256)
    }
    #expect(device.erasures == 0 && device.restores == 0)
}

@Test func unstableTailDoesNotDiscardVerifiedGameDataBeyondAnIncorrectHeader() throws {
    let device = MemoryDevice()
    device.rom = fixtureROM(bytes:0x200000,title:"BAILEY THE BRAVE") + Data(repeating:0xFF,count:0x200000)
    device.rom.replaceSubrange(0x1A4..<0x1A8,with:Data([0,0x0F,0xFF,0xFF]))
    device.unstableROMFrom = 0x200000
    let cartridge = try device.inspect(profile:.automatic)
    let analysis = try ROMContentAnalysis.read(device:device,cartridge:cartridge,progress:{_ in})
    #expect(analysis.headerBytes == 0x100000 && analysis.suggestedBytes == 0x200000)
    #expect(analysis.excludedROMStart == 0x200000)
    #expect(analysis.sha256 == hash(Data(device.rom.prefix(0x200000))))
}

@Test func stableROMMasqueradingAsSRAMIsUnconfirmedAndCannotBeWritten() throws {
    let device = MemoryDevice()
    device.rom = fixtureROM(bytes:0x400000,title:"SAMPLE PROGRAM")
    device.rom.replaceSubrange(0x1A4..<0x1A8,with:Data([0,0x0F,0xFF,0xFF]))
    device.saveReadsROM = true
    let layout = try #require(ROMMetadata.parse(device.rom).saveLayout)
    device.saveStatus = try SaveMemoryProbe.qualify(device,layout:layout)
    let cartridge = try device.inspect(profile:.automatic)
    #expect(cartridge.saveStatus == .unconfirmed && !cartridge.canBackupSave && !cartridge.canRestoreSave)
    let analysis = try ROMContentAnalysis.read(device:device,cartridge:cartridge,progress:{_ in})
    #expect(analysis.suggestedBytes == 0x400000)
    #expect(throws:(any Error).self) { try WritePlan(target:cartridge,image:nil,romName:nil,save:Data(count:layout.activeBytes),saveName:"save.srm",format:.packed,backupDestination:nil) }
    let manual = cartridge.applying(try .init(romCapacity:0x400000,saveLayout:layout))
    #expect(manual.canBackupSave && !manual.canRestoreSave && manual.saveStatus == .manual)
    #expect(device.erasures == 0 && device.programs == 0 && device.restores == 0)
}

@Test func readOnlySRAMQualificationDoesNotInventCertaintyForIdenticalBlankMemory() throws {
    let device = MemoryDevice(), layout = try #require(ROMMetadata.parse(device.rom).saveLayout)
    device.sram = Data(repeating:0xFF,count:65536)
    #expect(try SaveMemoryProbe.qualify(device,layout:layout) == .unconfirmed)
    device.sram[1] = 0x37
    #expect(try SaveMemoryProbe.qualify(device,layout:layout) == .confirmed)
    #expect(device.erasures == 0 && device.restores == 0)
}

@Test func blankSelectedMemoryDoesNotProveThatSRAMExistsEvenWhenROMDiffers() throws {
    let device = MemoryDevice()
    device.rom = fixtureROM(bytes:0x400000)
    let layout = try #require(ROMMetadata.parse(device.rom).saveLayout)
    for value in [UInt8(0),0xFF] {
        device.sram = Data(repeating:value,count:65536)
        #expect(try SaveMemoryProbe.qualify(device,layout:layout) == .unconfirmed)
    }
    #expect(device.erasures == 0 && device.restores == 0)
}

@Test func preservedSavesRemainRecoverableAfterAnInterruptedROMWrite() throws {
    let device = MemoryDevice(), directory = try tempFolder()
    defer { try? FileManager.default.removeItem(at:directory) }
    let target = try device.inspect(profile:.automatic), originalSave = device.sram
    let plan = try WritePlan(target:target,image:ROMImage(data:fixtureROM(title:"NEW GAME")),romName:"new.bin",save:nil,saveName:nil,format:.packed,backupDestination:nil)
    device.failProgram = true
    do {
        _ = try OperationRunner.write(device:device,plan:plan,progress:{_ in},recoveryDirectory:directory)
        Issue.record("Expected interrupted write")
    } catch let failure as OperationFailure {
        let recovery = URL(fileURLWithPath:try #require(failure.result.manifest.recoveryJournal))
        #expect(SaveRecoveryJournal.pendingFolders(in:directory).map { $0.resolvingSymlinksInPath().path } == [recovery.resolvingSymlinksInPath().path])
        #expect(try Data(contentsOf:recovery.appendingPathComponent("Preserved Saves.srm")) == target.saveLayout!.pack(originalSave.prefix(target.saveLayout!.windowBytes)))
        let record = try JSONDecoderWithDates().decode(SaveRecoveryJournal.Record.self,from:Data(contentsOf:recovery.appendingPathComponent("recovery.json")))
        #expect(record.saveSHA256 == hash(try target.saveLayout!.pack(originalSave.prefix(target.saveLayout!.windowBytes))))
        #expect(record.fingerprint == target.fingerprint && record.layout == target.saveLayout)
    }
}

private func JSONDecoderWithDates() -> JSONDecoder { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder }

@Test func SRAMWriteCheckRestoresOriginalAfterPartialWriteFailure() throws {
    let original = Data(repeating:0xA5,count:128)
    var memory = original, writes = 0
    #expect(throws:(any Error).self) {
        try SRAMWriteProbe.check(original:original,read:{ memory },writePrefix:{ bytes in
            writes += 1
            if writes == 1 {
                memory.replaceSubrange(0..<8,with:bytes.prefix(8))
                throw FlashMDError.timeout
            }
            memory.replaceSubrange(0..<32,with:bytes)
        },verifyROM:{})
    }
    #expect(memory == original && writes == 2)
}

@Test func SRAMWriteCheckRejectsReadOnlyMemoryAndChecksTheEntireSave() throws {
    let original = Data(repeating:0xA5,count:128)
    #expect(throws:(any Error).self) {
        try SRAMWriteProbe.check(original:original,read:{ original },writePrefix:{_ in},verifyROM:{})
    }
    var memory = original, writes = 0
    #expect(throws:(any Error).self) {
        try SRAMWriteProbe.check(original:original,read:{ memory },writePrefix:{ bytes in
            writes += 1; memory.replaceSubrange(0..<32,with:bytes)
            if writes == 1 { memory[100] ^= 1 }
        },verifyROM:{})
    }
    #expect(writes == 2 && Data(memory.prefix(32)) == Data(original.prefix(32)))
    #expect(memory != original) // Collateral change must never be accepted as restored.
}

@Test func SRAMWriteCheckRejectsStaleOriginalBeforeTouchingMemory() throws {
    var writes = 0
    #expect(throws:(any Error).self) {
        try SRAMWriteProbe.check(original:Data(repeating:1,count:128),read:{ Data(repeating:2,count:128) },writePrefix:{_ in writes += 1},verifyROM:{})
    }
    #expect(writes == 0)
}

@Test func cancelledSRAMWriteCheckStillRestoresItsTestBytes() throws {
    let original = Data(repeating:0x55,count:128)
    var memory = original, writes = 0
    #expect(throws:CancellationError.self) {
        try SRAMWriteProbe.check(original:original,read:{ memory },writePrefix:{ bytes in
            writes += 1; memory.replaceSubrange(0..<32,with:bytes)
            if writes == 1 { throw CancellationError() }
        },verifyROM:{})
    }
    #expect(memory == original && writes == 2)
}

@Test func permanentSRAMIsCheckedOnlyDuringWritingAfterItsJournalIsDurable() throws {
    let device = MemoryDevice(), directory = try tempFolder()
    defer { try? FileManager.default.removeItem(at:directory) }
    device.saveStatus = .readOnly
    let target = try device.inspect(profile:.automatic), original = device.sram
    #expect(!target.canRestoreSave && target.canCheckSaveWriting)
    let plan = try WritePlan(target:target,image:ROMImage(data:fixtureROM(title:"NEW GAME")),romName:"new.bin",save:nil,saveName:nil,format:.packed,backupDestination:nil)
    let result = try OperationRunner.write(device:device,plan:plan,progress:{ value in
        if value.detail == "Checking SRAM write access" {
            let recovery = SaveRecoveryJournal.pendingFolders(in:directory)
            #expect(recovery.count == 1)
            #expect((try? Data(contentsOf:recovery[0].appendingPathComponent("Preserved Saves.srm"))) == (try? target.saveLayout!.pack(original.prefix(target.saveLayout!.windowBytes))))
        }
    },recoveryDirectory:directory)
    #expect(device.writeChecks == 1 && device.sram == original && device.erasures > 0)
    #expect(result.manifest.phases.contains("SRAM write access checked; original saves restored"))
    #expect(SaveRecoveryJournal.pendingFolders(in:directory).isEmpty)
}

@Test func failedPermanentSRAMWriteCheckStopsROMErasureAndKeepsRecovery() throws {
    let device = MemoryDevice(), directory = try tempFolder()
    defer { try? FileManager.default.removeItem(at:directory) }
    device.saveStatus = .readOnly; device.failWriteCheck = true
    let target = try device.inspect(profile:.automatic)
    let plan = try WritePlan(target:target,image:ROMImage(data:fixtureROM()),romName:"game.bin",save:nil,saveName:nil,format:.packed,backupDestination:nil)
    #expect(throws:(any Error).self) { try OperationRunner.write(device:device,plan:plan,progress:{_ in},recoveryDirectory:directory) }
    #expect(device.writeChecks == 1 && device.erasures == 0 && device.programs == 0)
    #expect(SaveRecoveryJournal.pendingFolders(in:directory).count == 1)
}

@Test func permanentSRAMJournalFailureStopsBeforeTheActiveCheck() throws {
    let device = MemoryDevice(), directory = try tempFolder()
    defer { try? FileManager.default.removeItem(at:directory) }
    device.saveStatus = .readOnly
    let blocked = directory.appendingPathComponent("file"); try Data([1]).write(to:blocked)
    let plan = try WritePlan(target:device.inspect(profile:.automatic),image:nil,romName:nil,save:Data(repeating:0x55,count:8192),saveName:"save.srm",format:.packed,backupDestination:nil)
    #expect(throws:(any Error).self) { try OperationRunner.write(device:device,plan:plan,progress:{_ in},recoveryDirectory:blocked) }
    #expect(device.writeChecks == 0 && device.erasures == 0 && device.restores == 0)
}

@Test func successfulROMWriteRemovesTemporarySaveRecoveryOnlyAfterVerification() throws {
    let device = MemoryDevice(), directory = try tempFolder()
    defer { try? FileManager.default.removeItem(at:directory) }
    let target = try device.inspect(profile:.automatic)
    let plan = try WritePlan(target:target,image:ROMImage(data:fixtureROM(title:"NEW GAME")),romName:"new.bin",save:nil,saveName:nil,format:.packed,backupDestination:nil)
    let result = try OperationRunner.write(device:device,plan:plan,progress:{_ in},recoveryDirectory:directory)
    #expect(SaveRecoveryJournal.pendingFolders(in:directory).isEmpty)
    #expect(result.manifest.recoveryJournal == nil && result.manifest.preservedSaveSHA256 != nil)
}

@Test func recoveryStorageFailureStopsBeforeErasing() throws {
    let device = MemoryDevice(), directory = try tempFolder()
    defer { try? FileManager.default.removeItem(at:directory) }
    let blocked = directory.appendingPathComponent("file")
    try Data([1]).write(to:blocked)
    let target = try device.inspect(profile:.automatic)
    let plan = try WritePlan(target:target,image:ROMImage(data:fixtureROM()),romName:"game.bin",save:nil,saveName:nil,format:.packed,backupDestination:nil)
    #expect(throws:(any Error).self) { try OperationRunner.write(device:device,plan:plan,progress:{_ in},recoveryDirectory:blocked) }
    #expect(device.erasures == 0 && device.programs == 0)
}

@Test func unsupportedSaveTypePreventsROMErasureEvenWithManualCapacity() throws {
    let device = MemoryDevice()
    device.rom[0x1B3] |= 0x40
    let target = try device.inspect(profile:.automatic).applying(.init(romCapacity:0x400000,saveLayout:nil))
    #expect(target.metadata?.saveWarning != nil)
    #expect(throws:(any Error).self) { try WritePlan(target:target,image:ROMImage(data:fixtureROM(save:false)),romName:"game.bin",save:nil,saveName:nil,format:.packed,backupDestination:nil,clearUnusedROM:true) }
    #expect(device.erasures == 0)
}

@Test func manualSRAMLayoutCanBeQualifiedWhenTheHeaderDeclaresNoSaveMemory() throws {
    let device = MemoryDevice()
    device.rom = fixtureROM(save:false) + Data(repeating:0xFF,count:0x400000-65536)
    let layout = try SRAMLayout(start:0x200001,end:0x203FFF,lane:1)
    let configuration = try CartridgeConfiguration(romCapacity:0x200000,saveLayout:layout)
    let cartridge = try device.inspectConfigured(profile:.automatic,override:configuration,mapper:.automatic)
    #expect(cartridge.saveStatus == .confirmed && cartridge.canBackupSave && cartridge.canRestoreSave)
    let plan = try WritePlan(target:cartridge,image:nil,romName:nil,save:Data(repeating:0x39,count:layout.activeBytes),saveName:"save.srm",format:.packed,backupDestination:nil)
    _ = try testWrite(device:device,plan:plan,progress:{_ in})
    #expect(device.sram[1] == 0x39 && device.erasures == 0 && device.programs == 0)
}

@Test func saveHeaderCannotBeDisabledToExpandTheWritableROMRange() throws {
    let device = MemoryDevice(), detected = try device.inspect(profile:.automatic)
    let manual = detected.applying(try .init(romCapacity:0x400000,saveLayout:nil))
    #expect(manual.romReadLimit == 0x400000 && manual.romWriteLimit == 0x200000)
    let image = try ROMImage(data:fixtureROM(bytes:0x300000,save:false))
    #expect(throws:(any Error).self) { try WritePlan(target:manual,image:image,romName:"game.bin",save:nil,saveName:nil,format:.packed,backupDestination:nil,clearUnusedROM:true) }
}

@Test func manualSRAMSettingsCannotInvokeSRAMCommandsForDeclaredEEPROM() throws {
    let device = MemoryDevice()
    device.rom[0x1B3] |= 0x40
    let layout = try SRAMLayout(start:0x200001,end:0x203FFF,lane:1)
    let configuration = try CartridgeConfiguration(romCapacity:0x200000,saveLayout:layout)
    let target = try device.inspectConfigured(profile:.automatic,override:configuration,mapper:.automatic)
    #expect(target.saveStatus == .unsupported && !target.canBackupSave && !target.canRestoreSave)
    #expect(device.saveReadCount == 0)
}
