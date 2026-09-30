import Foundation
import Testing
@testable import FlashMDCore

/// Models only wire behavior: slow ROM reads return 64 bytes, SRAM reads 64
/// odd-lane bytes, SRAM writes carry 32 bytes and wait for an acknowledgement.
private final class DumperWire: ByteTransport, @unchecked Sendable {
    var commands: [Data] = []
    var pending: Data?
    var closed = false
    var ready = Data(repeating:0,count:64)
    var flashID: (UInt8,UInt8) = (0,0)
    var rom: Data
    var save = Data((0..<32768).map { UInt8(truncatingIfNeeded:$0 * 7) })
    var page = 4
    var ignoresBanks = false
    var wrapBanks = false
    var shortReply = false
    var statusValue: UInt8 = 0xAA
    init(banked: Bool = false) {
        ready.replaceSubrange(0..<6,with:Data("READY!".utf8))
        ready[20] = 2; ready[21] = 1; ready[24] = 3
        if banked {
            rom = Data()
            for bank in 0..<10 { rom.append(Data(repeating:UInt8(bank+10),count:0x80000)) }
            var header = Data(fixtureROM(save:false).prefix(512))
            header.replaceSubrange(0x100..<0x110,with:Data("SEGA SSF        ".utf8))
            header[0x1A4] = 0; header[0x1A5] = 0x4F; header[0x1A6] = 0xFF; header[0x1A7] = 0xFF
            rom.replaceSubrange(0..<512,with:header)
        } else { rom = fixtureROM() + Data(repeating:0xFF,count:0x400000-65536) }
    }
    func write(_ data: Data, timeout: TimeInterval) throws {
        #expect(data.count == 64)
        #expect(pending == nil)
        commands.append(data)
        let address = (Int(data[1]) | Int(data[2]) << 8 | Int(data[3]) << 16) * 2
        switch data[0] {
        case 0x10: pending = ready
        case 0x11:
            #expect(data[4] == 0) // No unbounded streaming.
            let logical = (0x200000..<0x280000).contains(address) && rom.count > 0x400000 ? page*0x80000+address-0x200000 : address
            pending = Data(rom[logical..<logical+64])
        case 0x18:
            var result = Data(repeating:0,count:64); result[1] = flashID.0; result[3] = flashID.1; pending = result
        case 0x20:
            #expect(address == 0xA130F8) // Odd register is encoded as a word address.
            if !ignoresBanks { page = Int(data[5]) & (wrapBanks ? 7 : 63) }
        case 0x12:
            let base = (address-0x200000)/2
            pending = Data(save[base..<base+64])
        case 0x13:
            #expect(data[7] == 0xCC) // Never blanket-erase SRAM.
            let base = (address-0x200000)/2
            save.replaceSubrange(base..<base+32,with:data[32..<64])
            var ack = Data(repeating:0,count:64); ack[6] = statusValue; pending = ack
        case 0x15:
            rom = Data(repeating:0xFF,count:rom.count)
            var ack = Data(repeating:0,count:64); ack[0] = 0xFF; pending = ack
        case 0x65:
            var ack = Data(repeating:0,count:64); ack[6] = 0xDD; pending = ack
        case 0x14:
            let length = Int(data[4]); #expect(length > 0 && length <= 54 && length % 2 == 0)
            rom.replaceSubrange(address..<address+length,with:data[5..<5+length])
        default: Issue.record("Unexpected command \(data[0])")
        }
    }
    func read(count: Int, timeout: TimeInterval, cancellable: Bool) throws -> Data {
        guard let pending else { throw FlashMDError.timeout }
        self.pending = nil
        return shortReply ? Data(pending.prefix(63)) : pending
    }
    func close() { closed = true }
    func device() throws -> MDDumperDevice { try MDDumperDevice(transport:self,location:"test-usb") }
}

@Test func mdDumperHandshakeAndLinearScanAreNonDestructive() throws {
    let wire = DumperWire(), before = wire.save, device = try wire.device()
    let snapshot = try device.inspect(profile:.automatic)
    #expect(snapshot.readerKind == .mdDumper)
    #expect(snapshot.title == "TEST GAME")
    #expect(snapshot.saveLayout?.activeBytes == 8192)
    #expect(!snapshot.canWrite && snapshot.canRestoreSave)
    #expect(snapshot.romReadLimit == 0x200000)
    #expect(wire.commands.allSatisfy { [UInt8(0x10),0x11,0x18].contains($0[0]) })
    #expect(wire.save == before)
    #expect(try device.readROM(offset:61,count:130) == Data(wire.rom[61..<191]))
    #expect(try device.readROM(offset:0x400000,count:0) == Data())
    #expect(throws:FlashMDError.self) { try device.readROM(offset:0x400000,count:1) }
}

@Test(arguments: [0,1,2,3,4])
func mdDumperRejectsInvalidIdentityAndCloses(caseIndex: Int) throws {
    let wire = DumperWire()
    switch caseIndex {
    case 0: wire.ready[0] = 0
    case 1: wire.ready[20] = 9
    case 2: wire.ready[24] = 9
    case 3: wire.ready[25] = 1
    default: wire.shortReply = true
    }
    #expect(throws:FlashMDError.self) { try wire.device() }
    #expect(wire.closed)
}

@Test func mdDumperSRAMRoundTripPreservesUnselectedBytes() throws {
    let wire = DumperWire(), device = try wire.device()
    let layout = try #require(try device.inspect(profile:.automatic).saveLayout)
    let original = wire.save
    let raw = try device.readSRAM(layout:layout,offset:0,count:layout.windowBytes)
    #expect(try layout.pack(raw) == Data(original.prefix(layout.activeBytes)))
    #expect(stride(from:0,to:raw.count,by:2).allSatisfy { raw[$0] == 0 })
    #expect(try device.readSRAM(layout:layout,offset:125,count:130) == Data(raw[125..<255]))
    let replacement = Data(repeating:0x58,count:layout.activeBytes)
    try device.restore(layout:layout,raw:try layout.rawRepresentation(replacement,format:.packed))
    #expect(try layout.pack(device.readSRAM(layout:layout,offset:0,count:layout.windowBytes)) == replacement)
    #expect(Data(wire.save.dropFirst(layout.activeBytes)) == Data(original.dropFirst(layout.activeBytes)))
    #expect(!wire.commands.contains { $0[0] == 0x13 && $0[7] == 0xBB })
    let even = try SRAMLayout(start:0x200000,end:0x203FFE,lane:0)
    #expect(throws:FlashMDError.self) { try device.restore(layout:even,raw:raw) }
}

@Test(arguments: [0,1,2])
func mdDumperBankQualificationAndRestoration(mode: Int) throws {
    let wire = DumperWire(banked:true)
    wire.ignoresBanks = mode == 1; wire.wrapBanks = mode == 2
    let device = try wire.device(), snapshot = try device.inspect(profile:.automatic)
    #expect(snapshot.canBackupROM == (mode == 0))
    #expect(!snapshot.canWrite && !snapshot.canRestoreSave)
    #expect(wire.page == 4)
    #expect(!wire.commands.contains { [UInt8(0x12),0x13,0x14,0x15,0x18].contains($0[0]) })
    if mode == 0 {
        #expect(try device.readROM(offset:0x3FFFF1,count:130) == Data(wire.rom[0x3FFFF1..<0x3FFFF1+130]))
        #expect(wire.page == 4)
    } else { #expect(throws:FlashMDError.self) { try device.readROM(offset:0,count:512) } }
}

@Test func mdDumperKnownFlashUsesWholeChipPlanAndExplicitAlgorithms() throws {
    let wire = DumperWire(); wire.flashID = (0x20,0x57)
    wire.rom.replaceSubrange(0..<65536,with:fixtureROM(save:false))
    let device = try wire.device(), snapshot = try device.inspect(profile:.automatic)
    #expect(snapshot.canWrite)
    let geometry = try #require(snapshot.geometry)
    #expect(geometry.sectors.count == 1 && geometry.sectors[0].bytes == 0x400000)
    let image = try ROMImage(data:fixtureROM(save:false))
    #expect(throws:FlashMDError.self) { try WritePlan(target:snapshot,image:image,romName:"test",save:nil,saveName:nil,format:.packed,backupDestination:nil,clearUnusedROM:false) }
    let plan = try WritePlan(target:snapshot,image:image,romName:"test",save:nil,saveName:nil,format:.packed,backupDestination:nil,clearUnusedROM:true)
    #expect(plan.rom?.count == 0x400000)
    try device.erase(sector:geometry.sectors[0])
    let data = Data((0..<128).map { UInt8($0) })
    try device.program(offset:0x100,data:data)
    #expect(try device.readROM(offset:0x100,count:128) == data)
    #expect(wire.commands.first { $0[0] == 0x15 }?[1] == 2)
    #expect(wire.commands.first { $0[0] == 0x65 }?[4] == 2)
    #expect(wire.commands.filter { $0[0] == 0x14 }.map { $0[4] } == [54,54,20])
    let json = try JSONEncoder().encode(geometry)
    #expect(try JSONDecoder().decode(FlashGeometry.self,from:json) == geometry)
}

@Test func mdDumperUnknownOrLegacyFlashNeverEnablesROMWrites() throws {
    for entry in [(UInt8(0xC2),UInt8(0xF9),UInt8(3)),(0xFF,0xFF,3),(0x20,0x57,0)] {
        let wire = DumperWire(); wire.flashID = (entry.0,entry.1); wire.ready[24] = entry.2
        wire.rom.replaceSubrange(0..<65536,with:fixtureROM(save:false))
        let device = try wire.device(), snapshot = try device.inspect(profile:.automatic)
        #expect(!snapshot.canWrite)
        #expect(throws:FlashMDError.self) { try device.program(offset:0,data:Data([1,2])) }
        #expect(!wire.commands.contains { [UInt8(0x14),0x15,0x65].contains($0[0]) })
    }
}

@Test func mdDumperVerifiedSRAMBackupPublishesCompatibleFiles() throws {
    let wire = DumperWire(), device = try wire.device()
    let snapshot = try device.inspect(profile:.automatic), layout = try #require(snapshot.saveLayout)
    let folder = try tempFolder(); defer { try? FileManager.default.removeItem(at:folder) }
    let request = try BackupRequest(cartridge:snapshot,romBytes:nil,saveLayout:layout,saveFormat:.packed,verify:true,destination:folder)
    let result = try OperationRunner.backup(device:device,request:request,progress:{ _ in })
    let artifact = try #require(result.manifest.artifacts.first)
    #expect(artifact.verified)
    let outputFolder = try #require(result.folder)
    #expect(try Data(contentsOf:outputFolder.appendingPathComponent(artifact.filename)) == Data(wire.save.prefix(layout.activeBytes)))
    #expect(!wire.commands.contains { [UInt8(0x13),0x14,0x15].contains($0[0]) })
}

@Test func mdDumperWriteFailuresAndUnsupportedOverridesFailClosed() throws {
    let wire = DumperWire(), device = try wire.device()
    let snapshot = try device.inspect(profile:.automatic), layout = try #require(snapshot.saveLayout)
    let even = try SRAMLayout(start:0x200000,end:0x203FFE,lane:0)
    let override = try CartridgeConfiguration(romCapacity:0x200000,saveLayout:even)
    let modified = snapshot.applying(override)
    #expect(modified.readerKind == .mdDumper && modified.saveLayout == nil && !modified.canRestoreSave)
    wire.statusValue = 0
    #expect(throws:FlashMDError.timeout) { try device.restore(layout:layout,raw:Data(repeating:0,count:layout.windowBytes)) }
    #expect(wire.commands.filter { $0[0] == 0x13 }.count == 1)
    wire.shortReply = true
    #expect(throws:FlashMDError.self) { try device.readROM(offset:0,count:64) }
}
