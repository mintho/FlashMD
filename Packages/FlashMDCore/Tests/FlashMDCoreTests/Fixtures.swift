import Foundation
@testable import FlashMDCore

func fixtureROM(bytes: Int = 65536, save: Bool = true, title: String = "TEST GAME") -> Data {
    var data = Data(repeating:0,count:bytes)
    func text(_ value: String, _ offset: Int) { let raw = Array(value.utf8); data.replaceSubrange(offset..<offset+raw.count,with:raw) }
    func word(_ value:Int,_ offset:Int) { for n in 0..<4 { data[offset+n] = UInt8(truncatingIfNeeded:value >> ((3-n)*8)) } }
    text("SEGA MEGA DRIVE",0x100); text("(C)SEGA 1994",0x110); text(title,0x120); text(title,0x150); text("GM 00000000-00",0x180); text("J",0x190); text("JUE",0x1F0)
    word(bytes-1,0x1A4)
    if save { text("RA",0x1B0); data[0x1B2] = 0xF8; data[0x1B3] = 0x20; word(0x200001,0x1B4); word(0x203FFF,0x1B8) }
    var checksum:UInt16 = 0
    for offset in stride(from:0x200,to:bytes,by:2) { data[offset] = UInt8(truncatingIfNeeded:offset/2); data[offset+1] = 0x51; checksum &+= UInt16(data[offset]) << 8 | 0x51 }
    data[0x18E] = UInt8(checksum >> 8); data[0x18F] = UInt8(truncatingIfNeeded:checksum)
    return data
}
func fixtureCFI(eightMB:Bool = false) -> Data {
    var cfi = Data(repeating:0,count:128)
    cfi.replaceSubrange(0x10..<0x13,with:Data("QRY".utf8)); cfi[0x13] = 2; cfi[0x27] = eightMB ? 23 : 22; cfi[0x2C] = 2
    cfi[0x2D] = 7; cfi[0x2F] = 0x20; cfi[0x31] = eightMB ? 126 : 62; cfi[0x34] = 1
    return cfi
}
func fixtureGeometry(top:Bool = false) throws -> FlashGeometry { try FlashGeometry(cfi:fixtureCFI(),manufacturer:0x20,deviceID:top ? 0x2256 : 0x2257) }
func tempFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("FlashMDTests-\(UUID().uuidString)",isDirectory:true)
    try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true); return url
}
final class MemoryDevice: CartridgeDevice, @unchecked Sendable {
    let identity = "test-port · 0101"
    var rom:Data
    var sram = Data(repeating:0xA5,count:65536)
    var changedIdentity = false
    var failSaveRead = false
    var failErase = false
    var changeSaveOnErase = false
    var failRestore = false
    var corruptProgram = false
    var shortRead = false
    var failProgram = false
    var corruptRestore = false
    var mismatchSecondRead = false
    var erasures = 0
    var programs = 0
    var restores = 0
    var resets = 0
    var reads:[Int] = []
    init() { rom = fixtureROM() + Data(repeating:0xFF,count:0x400000-65536) }
    func inspect(profile:CartridgeProfile) throws -> CartridgeSnapshot {
        let metadata = try ROMMetadata.parse(rom), geometry = try fixtureGeometry()
        let layout = profile == .automatic ? metadata.saveLayout : profile.saveLayout
        let capacity = profile == .automatic ? CartridgeConfiguration.inferredCapacity(geometry:geometry,saveLayout:layout) : profile.usableCapacity(for:geometry)
        return .init(title:metadata.title,regions:metadata.regions,romSize:metadata.declaredROMBytes.map { .init(bytes:$0,source:.header) },flashCapacity:capacity,rawSaveWindow:.init(bytes:65536,source:.profile),metadata:metadata,geometry:geometry,saveLayout:layout,identity:identity,fingerprint:changedIdentity ? "changed" : hash(Data(rom.prefix(512))),profile:profile)
    }
    func readROM(offset:Int,count:Int) throws -> Data { reads.append(count)
        var block = Data(rom[offset..<offset+count-(shortRead ? 1 : 0)])
        if mismatchSecondRead, reads.count > 2, !block.isEmpty { block[0] ^= 1 }
        return block }
    func readSRAM(layout:SRAMLayout,offset:Int,count:Int) throws -> Data { if failSaveRead { throw FlashMDError.disconnected }; return Data(sram[(layout.base-0x200000+offset)..<(layout.base-0x200000+offset+count)]) }
    func erase(sector:FlashSector) throws { if failErase { throw FlashMDError.timeout }; erasures += 1; rom.replaceSubrange(sector.offset..<sector.offset+sector.bytes,with:Data(repeating:0xFF,count:sector.bytes)); if changeSaveOnErase { sram[1] = 0x5A } }
    func program(offset:Int,data:Data) throws { if failProgram { throw FlashMDError.disconnected }; programs += 1; rom.replaceSubrange(offset..<offset+data.count,with:data); if corruptProgram { rom[offset] ^= 1 } }
    func restore(layout:SRAMLayout,raw:Data) throws {
        if failRestore { throw FlashMDError.disconnected }; restores += 1
        if let lane = layout.lane { for index in stride(from:lane,to:raw.count,by:2) { sram[index] = raw[index] } } else { sram = raw }
        if corruptRestore { sram[layout.lane ?? 0] ^= 1 }
    }
    func reset() throws { resets += 1 }
    func close() {}
}
