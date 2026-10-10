import Foundation
import Testing
@testable import FlashMDCore

@Test func automaticConfigurationRespectsHeaderSaveMappingAndChipCapacity() throws {
    let geometry = try FlashGeometry(cfi:fixtureCFI(eightMB:true),manufacturer:1,deviceID:0x227E,extendedID:0x2210,bootID:0x2201)
    let metadata = try ROMMetadata.parse(fixtureROM())
    #expect(CartridgeConfiguration.inferredCapacity(geometry:geometry,saveLayout:metadata.saveLayout).bytes == 0x200000)
    #expect(CartridgeConfiguration.inferredCapacity(geometry:geometry,saveLayout:nil).bytes == 0x400000)
    var small = fixtureCFI(); small[0x27] = 16; small[0x2C] = 1; small[0x2D] = 0; small[0x2F] = 0; small[0x30] = 1
    let smallGeometry = try FlashGeometry(cfi:small,manufacturer:0x20,deviceID:0x2257)
    #expect(CartridgeConfiguration.inferredCapacity(geometry:smallGeometry,saveLayout:nil).bytes == 65536)
}

@Test func automaticWriteAndCustomCapacityAreRevalidated() throws {
    let device = MemoryDevice(), target = try device.inspect(profile:.automatic)
    #expect(target.canWrite); #expect(target.saveLayout?.activeBytes == 8192)
    let override = try CartridgeConfiguration(romCapacity:65536,saveLayout:target.saveLayout)
    let customized = target.applying(override)
    let plan = try WritePlan(target:customized,image:ROMImage(data:fixtureROM()),romName:"game.bin",save:nil,saveName:nil,format:.raw,backupDestination:nil)
    let result = try testWrite(device:device,plan:plan,progress:{_ in})
    #expect(result.manifest.outcome == "completed")
    #expect(result.manifest.configurationOverride == override)
    #expect(throws:(any Error).self) { try BackupRequest(cartridge:customized,romBytes:65537,saveLayout:nil,verify:false,destination:URL(fileURLWithPath:"/tmp")) }
    #expect(throws:(any Error).self) { try WritePlan(target:customized,image:ROMImage(data:fixtureROM(bytes:131072)),romName:"large.bin",save:nil,saveName:nil,format:.raw,backupDestination:nil) }
}

@Test func overrideDoesNotEnableUnsupportedFlashAlgorithmOrEvenLaneWrites() throws {
    let geometry = try FlashGeometry(cfi:fixtureCFI(),manufacturer:0xC2,deviceID:0x2257)
    let original = CartridgeSnapshot(title:"Unknown chip",regions:[],romSize:nil,flashCapacity:nil,rawSaveWindow:nil,geometry:geometry)
    let configured = original.applying(try .init(romCapacity:0x400000,saveLayout:nil))
    #expect(!configured.canWrite)
    #expect(throws:(any Error).self) { try WritePlan(target:configured,image:ROMImage(data:fixtureROM()),romName:"game.bin",save:nil,saveName:nil,format:.raw,backupDestination:nil) }
    let even = try SRAMLayout(start:0x200000,end:0x203FFE,lane:0)
    #expect(!original.applying(try .init(romCapacity:0x200000,saveLayout:even)).canRestoreSave)
    #expect(throws:(any Error).self) { try CartridgeConfiguration(romCapacity:0x800000,saveLayout:nil) }
}

@Test func saveOnlyRestoreWorksWithoutRewritableROM() throws {
    let metadata = try ROMMetadata.parse(fixtureROM())
    let target = CartridgeSnapshot(title:metadata.title,regions:metadata.regions,romSize:nil,flashCapacity:nil,rawSaveWindow:nil,metadata:metadata,saveLayout:metadata.saveLayout,saveStatus:.confirmed)
    #expect(!target.canWrite); #expect(target.canRestoreSave)
    let plan = try WritePlan(target:target,image:nil,romName:nil,save:Data(repeating:0x5A,count:8192),saveName:"save.srm",format:.packed,backupDestination:nil)
    #expect(plan.rom == nil); #expect(plan.saveLayout?.activeBytes == 8192)
}

@Test func disablingSaveMemoryOverridesTheHeaderDeclaration() throws {
    let metadata = try ROMMetadata.parse(fixtureROM())
    let target = CartridgeSnapshot(title:metadata.title,regions:metadata.regions,romSize:nil,
        flashCapacity:nil,rawSaveWindow:nil,metadata:metadata,saveLayout:metadata.saveLayout,saveStatus:.confirmed)
    let configured = target.applying(try .init(romCapacity:0x200000,saveLayout:nil))
    #expect(configured.metadata?.saveLayout != nil)
    #expect(configured.saveLayout == nil)
    #expect(configured.saveStatus == SaveMemoryStatus.none)
    #expect(!configured.canBackupSave && !configured.canStartSaveWrite)
}

@Test func backupRejectsChangedConfigurationBeforeReadingAnyContents() throws {
    let device = MemoryDevice(), target = try device.inspect(profile:.automatic), destination = try tempFolder()
    defer { try? FileManager.default.removeItem(at:destination) }
    let request = try BackupRequest(cartridge:target,romBytes:65536,saveLayout:nil,verify:true,destination:destination)
    // The first 512 bytes remain identical; geometry/profile changes must still invalidate the request.
    let wrongTarget = CartridgeSnapshot(title:target.title,regions:target.regions,romSize:target.romSize,flashCapacity:.init(bytes:65536,source:.estimated),rawSaveWindow:target.rawSaveWindow,metadata:target.metadata,geometry:target.geometry,saveLayout:target.saveLayout,identity:target.identity,fingerprint:target.fingerprint,profile:.automatic)
    let staleRequest = try BackupRequest(cartridge:wrongTarget,romBytes:request.romBytes,saveLayout:nil,verify:true,destination:destination)
    #expect(throws:(any Error).self) { try OperationRunner.backup(device:device,request:staleRequest,progress:{_ in}) }
    #expect(device.reads.isEmpty)
}

@Test func nativeAutomaticScanQualifiesSRAMWithoutWritingTestPatterns() throws {
    let cfi = fixtureCFI(eightMB:true)
    var bus = Data(repeating:0,count:256)
    for index in cfi.indices { bus[index * 2 + 1] = cfi[index] }
    let transport = try ScriptTransport(linearInspectionResponses(header:Data(fixtureROM().prefix(512)),cfiBus:bus))
    let device = try FlashKitDevice(transport:transport,path:"test")
    let snapshot = try device.inspect(profile:.automatic)
    #expect(snapshot.canWrite)
    #expect(snapshot.flashCapacity?.bytes == 0x200000)
    #expect(snapshot.romReadLimit == 0x400000 && snapshot.romWriteLimit == 0x200000)
    #expect(snapshot.flashCapacity?.source == .estimated)
    #expect(snapshot.saveLayout?.activeBytes == 8192)
    // Inspection writes commands to the chip/registers, never a data pattern to the SRAM window.
    #expect(!transport.writes.contains { $0.count > 16 || $0.first == 0x83 })
}

@Test func blankFlashGetsVerifiedRecoveryBackupBeforeProgramming() throws {
    let device = MemoryDevice(), destination = try tempFolder()
    defer { try? FileManager.default.removeItem(at:destination) }
    device.rom = Data(repeating:0xFF,count:0x400000)
    let target = try device.inspect(profile:.linearROMOnly)
    #expect(target.romSize == nil)
    let plan = try WritePlan(target:target,image:ROMImage(data:fixtureROM()),romName:"game.bin",save:nil,saveName:nil,format:.raw,backupDestination:destination)
    let result = try testWrite(device:device,plan:plan,progress:{_ in})
    let folder = try #require(result.folder)
    let artifact = try #require(result.manifest.artifacts.first(where: { $0.isROM }))
    let original = try Data(contentsOf:folder.appendingPathComponent(artifact.filename))
    #expect(original == Data(repeating:0xFF,count:target.romReadLimit))
    #expect(result.manifest.artifacts.first?.verified == true)
    #expect(result.manifest.outcome == "completed")
}

@Test func manualSaveRangesMustMatchByteLane() throws {
    #expect(throws:(any Error).self) { try SRAMLayout(start:0x200000,end:0x20FFFF,lane:1) }
    #expect(throws:(any Error).self) { try SRAMLayout(start:0x200001,end:0x20FFFF,lane:nil) }
    #expect(try SRAMLayout(start:0x200000,end:0x20FFFF,lane:nil).activeBytes == 65536)
}

@Test func maskedROMReadLimitAndManualCapacityDoNotEnableROMWrites() throws {
    let metadata = try ROMMetadata.parse(fixtureROM(bytes:0x400000,save:false))
    let target = CartridgeSnapshot(title:metadata.title,regions:[],romSize:.init(bytes:0x400000,source:.header),flashCapacity:nil,rawSaveWindow:nil,metadata:metadata)
    #expect(target.romReadLimit == 0x400000)
    _ = try BackupRequest(cartridge:target,romBytes:0x400000,saveLayout:nil,verify:true,destination:URL(fileURLWithPath:"/tmp"))
    let overridden = target.applying(try .init(romCapacity:0x100000,saveLayout:nil))
    #expect(overridden.flashCapacity?.bytes == 0x100000)
    #expect(!overridden.canWrite)
    #expect(throws:(any Error).self) { try BackupRequest(cartridge:overridden,romBytes:0x100001,saveLayout:nil,verify:true,destination:URL(fileURLWithPath:"/tmp")) }
}

@Test func romOnlyOverrideCanReplaceAStaleHeaderWithoutDisablingDetectedSaveProtection() throws {
    let geometry = try fixtureGeometry(), metadata = try ROMMetadata.parse(fixtureROM())
    let scanned = CartridgeSnapshot(title:metadata.title,regions:[],romSize:nil,
        flashCapacity:.init(bytes:0x200000,source:.estimated),rawSaveWindow:nil,
        metadata:metadata,geometry:geometry,saveLayout:metadata.saveLayout,saveStatus:.unconfirmed)
    let override = try CartridgeConfiguration(romCapacity:0x400000,saveLayout:nil)
    let romOnly = scanned.applying(override)
    #expect(romOnly.hasExplicitROMOnlyConfiguration && romOnly.romWriteLimit == 0x400000)
    let image = try ROMImage(data:fixtureROM(bytes:0x300000,save:false))
    #expect(try WritePlan(target:romOnly,image:image,romName:"game.bin",save:nil,saveName:nil,
                          format:.packed,backupDestination:nil).rom != nil)
    let confirmed = scanned.withSaveStatus(.confirmed).applying(override)
    #expect(!confirmed.hasExplicitROMOnlyConfiguration && confirmed.romWriteLimit == 0x200000)
    #expect(confirmed.detectedSaveStatus == .confirmed)
    #expect(throws:(any Error).self) { try WritePlan(target:confirmed,image:image,romName:"game.bin",save:nil,saveName:nil,format:.packed,backupDestination:nil) }
}

@Test func sramProtectionIsCheckedBeforeFlashIdentificationWithoutRequiringASaveFile() throws {
    let metadata = try ROMMetadata.parse(fixtureROM())
    // No flash geometry yet: MD Dumper has not entered chip-identification mode.
    let target = CartridgeSnapshot(title:metadata.title,regions:[],romSize:nil,
        flashCapacity:nil,rawSaveWindow:nil,metadata:metadata,saveLayout:metadata.saveLayout,
        readerKind:.mdDumper,saveStatus:.unconfirmed)
    #expect(!target.canWrite)
    do {
        try target.validateROMWriteSaveProtection()
        Issue.record("An unconfirmed save declaration should require a board configuration.")
    } catch {
        #expect(error.localizedDescription.contains("current game declares SRAM"))
        #expect(error.localizedDescription.contains("4 MiB ROM only"))
    }
    let romOnly = target.applying(try .init(romCapacity:0x400000,saveLayout:nil))
    try romOnly.validateROMWriteSaveProtection()
    try target.withSaveStatus(.confirmed).validateROMWriteSaveProtection()
    let hiddenConfirmedSave = target.withSaveStatus(.confirmed).applying(try .init(romCapacity:0x400000,saveLayout:nil))
    #expect(throws:(any Error).self) { try hiddenConfirmedSave.validateROMWriteSaveProtection() }
}

@Test(arguments:[SaveMemoryStatus.declared, .unconfirmed, .manual])
func romOnlyConfirmationUsesTheScanRangeWithoutTheOldHeaderSaveBoundary(status: SaveMemoryStatus) throws {
    let device = MemoryDevice(); device.saveStatus = status
    let target = try device.inspect(profile:.automatic)
    #expect(target.canConfirmNoSRAMForROMWriting)
    let configuration = try target.romOnlyConfigurationForWriting()
    #expect(configuration.romCapacity == 0x400000 && configuration.saveLayout == nil)
    let configured = target.applying(configuration)
    try configured.validateROMWriteSaveProtection()
    #expect(configured.romWriteLimit == 0x400000 && !configured.canConfirmNoSRAMForROMWriting)
    let smaller = target.applying(try .init(romCapacity:0x100000,saveLayout:target.saveLayout))
    #expect(try smaller.romOnlyConfigurationForWriting().romCapacity == 0x100000)
}

@Test(arguments:[SaveMemoryStatus.none, .confirmed, .readOnly, .unsupported])
func romOnlyQuestionNeverOverridesDetectedOrUnsupportedSaveMemory(status: SaveMemoryStatus) throws {
    let device = MemoryDevice(); device.saveStatus = status
    let target = try device.inspect(profile:.automatic)
    #expect(!target.canConfirmNoSRAMForROMWriting)
    #expect(throws:(any Error).self) { try target.romOnlyConfigurationForWriting() }
}

@Test(arguments:["unchanged", "confirmed", "readOnly", "cartridge changed"])
func romOnlyConfirmationRechecksCartridgeAndSaveEvidenceBeforeAcceptingUserChoice(change: String) async throws {
    let device = MemoryDevice(); device.saveStatus = .unconfirmed
    let controller = ProgrammerController(makeDevice:{ _,_ in device })
    try await controller.connect(path:"test")
    let original = try await controller.inspect(profile:.automatic)
    if change == "confirmed" { device.saveStatus = .confirmed }
    if change == "readOnly" { device.saveStatus = .readOnly }
    if change == "cartridge changed" { device.changedIdentity = true }
    if change == "unchanged" {
        let configured = try await controller.confirmROMOnlyCartridge(original)
        #expect(configured.hasExplicitROMOnlyConfiguration && configured.saveLayout == nil)
        #expect(configured.romWriteLimit == 0x400000)
    } else {
        await #expect(throws:(any Error).self) { try await controller.confirmROMOnlyCartridge(original) }
    }
    #expect(device.erasures == 0 && device.programs == 0 && device.restores == 0 && device.writeChecks == 0)
}

@Test(arguments:[0x22A7,0x22A8,0x22CB,0x22C9])
func macronixCFIUsesPhysicalCapacityAndBootOrderWithStandardProgramming(id: Int) throws {
    let eight = id == 0x22CB || id == 0x22C9
    let geometry = try FlashGeometry(cfi:fixtureCFI(eightMB:eight),manufacturer:0xC2,deviceID:UInt16(id))
    #expect(geometry.supported && !geometry.usesUnlockBypass)
    #expect(geometry.capacity == (eight ? 0x800000 : 0x400000))
    #expect(geometry.sectors.first?.bytes == ([0x22A7,0x22C9].contains(id) ? 65536 : 8192))
    #expect(CartridgeConfiguration.inferredCapacity(geometry:geometry,saveLayout:nil).bytes == 0x400000)
    var invalid = fixtureCFI(eightMB:eight); invalid[0x13] = 1
    #expect(!(try FlashGeometry(cfi:invalid,manufacturer:0xC2,deviceID:UInt16(id))).supported)
}

@Test func standardCFIFlashKitProgrammingUsesWordUnlocksWithoutUnlockBypass() throws {
    let header = Data(fixtureROM(save:false).prefix(512)), cfi = fixtureCFI(eightMB:true)
    var bus = Data(repeating:0,count:256)
    for index in cfi.indices { bus[index*2+1] = cfi[index] }
    let transport = ScriptTransport([Data([1,1]),header,bus,Data([0,0xC2]),Data([0x22,0xCB]),Data([0,0]),Data([0,0]),header,Data([0x12,0x34])])
    let device = try FlashKitDevice(transport:transport,path:"test")
    let snapshot = try device.inspectConfigured(profile:.linearROMOnly,override:nil,mapper:.automatic)
    #expect(snapshot.canWrite && snapshot.geometry?.capacity == 0x800000 && snapshot.romWriteLimit == 0x400000)
    let before = transport.writes.count
    try device.program(offset:0x300000,data:Data([0x12,0x34,0xFF,0xFF]))
    let writes = Array(transport.writes.dropFirst(before))
    let expected: [UInt8] = [0,0,0,5,0,0x55,0x43,0,0xAA,
                            0,0,0,2,0,0xAA,0x43,0,0x55,
                            0,0,0,5,0,0x55,0x43,0,0xA0,
                            0,0x18,0,0,0,0,0x43,0x12,0x34,4]
    #expect(writes == [Data(expected),Data([0x42])])
    #expect(throws:(any Error).self) { try device.program(offset:0x400000,data:Data([0,0])) }
}

@Test func uniformSTCFIIsAvailableWithoutInventingBootSectors() throws {
    var cfi = fixtureCFI(eightMB:true)
    cfi[0x2C] = 1; cfi[0x2D] = 127; cfi[0x2F] = 0; cfi[0x30] = 1
    let geometry = try FlashGeometry(cfi:cfi,manufacturer:0x20,deviceID:0x22ED)
    #expect(geometry.supported && geometry.capacity == 0x800000 && !geometry.usesUnlockBypass)
    #expect(geometry.sectors.count == 128)
}

@Test func flashKitROMOnlyProfileDoesNotKeepThePreviousGamesSRAMWriteBoundary() throws {
    let header = Data(fixtureROM().prefix(512)), cfi = fixtureCFI(eightMB:true)
    var bus = Data(repeating:0,count:256)
    for index in cfi.indices { bus[index*2+1] = cfi[index] }
    let transport = ScriptTransport([Data([1,1]),header,bus,Data([0,1]),Data([0x22,0x7E]),Data([0x22,0x10]),Data([0x22,0]),header,Data([0x12,0x34])])
    let device = try FlashKitDevice(transport:transport,path:"test")
    let snapshot = try device.inspectConfigured(profile:.linearROMOnly,override:nil,mapper:.automatic)
    #expect(snapshot.metadata?.saveLayout != nil && snapshot.hasExplicitROMOnlyConfiguration)
    #expect(snapshot.saveLayout == nil && snapshot.romWriteLimit == 0x400000)
    try device.program(offset:0x300000,data:Data([0x12,0x34]))
    #expect(throws:(any Error).self) { try device.program(offset:0x400000,data:Data([0,0])) }
}
