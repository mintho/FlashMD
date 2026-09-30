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
    let result = try OperationRunner.write(device:device,plan:plan,progress:{_ in})
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
    let target = CartridgeSnapshot(title:metadata.title,regions:metadata.regions,romSize:nil,flashCapacity:nil,rawSaveWindow:nil,metadata:metadata,saveLayout:metadata.saveLayout)
    #expect(!target.canWrite); #expect(target.canRestoreSave)
    let plan = try WritePlan(target:target,image:nil,romName:nil,save:Data(repeating:0x5A,count:8192),saveName:"save.srm",format:.packed,backupDestination:nil)
    #expect(plan.rom == nil); #expect(plan.saveLayout?.activeBytes == 8192)
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

@Test func nativeAutomaticScanUsesQueriedGeometryAndDeclaredSRAMWithoutProbing() throws {
    let cfi = fixtureCFI(eightMB:true)
    var bus = Data(repeating:0,count:256)
    for index in cfi.indices { bus[index * 2 + 1] = cfi[index] }
    let transport = ScriptTransport([Data([1,1]),Data(fixtureROM().prefix(512)),bus,Data([0,1]),Data([0x22,0x7E]),Data([0x22,0x10]),Data([0x22,1])])
    let device = try FlashKitDevice(transport:transport,path:"test")
    let snapshot = try device.inspect(profile:.automatic)
    #expect(snapshot.canWrite)
    #expect(snapshot.flashCapacity?.bytes == 0x200000)
    #expect(snapshot.flashCapacity?.source == .estimated)
    #expect(snapshot.saveLayout?.activeBytes == 8192)
    // Inspection writes commands to the chip/registers, never a data pattern to the SRAM window.
    #expect(!transport.writes.contains { $0.count == 6 && $0[0] == 0 && $0[1] == 0x10 })
}

@Test func blankFlashGetsVerifiedRecoveryBackupBeforeProgramming() throws {
    let device = MemoryDevice(), destination = try tempFolder()
    defer { try? FileManager.default.removeItem(at:destination) }
    device.rom = Data(repeating:0xFF,count:0x400000)
    let target = try device.inspect(profile:.linearROMOnly)
    #expect(target.romSize == nil)
    let plan = try WritePlan(target:target,image:ROMImage(data:fixtureROM()),romName:"game.bin",save:nil,saveName:nil,format:.raw,backupDestination:destination)
    let result = try OperationRunner.write(device:device,plan:plan,progress:{_ in})
    let folder = try #require(result.folder)
    let original = try Data(contentsOf:folder.appendingPathComponent("game.bin"))
    #expect(original == Data(repeating:0xFF,count:plan.requiredBytes))
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
