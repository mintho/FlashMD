import Foundation
import Testing
@testable import FlashMDCore

private final class MapperBus {
    let mapper: ROMMapper
    var selected: Int
    var ignoresWrites = false
    var pageMask = 63
    var failRead = false
    var writes: [(Int, UInt8)] = []
    var rom: Data
    init(_ mapper: ROMMapper, bytes: Int) {
        self.mapper = mapper; selected = mapper == .pierSolar ? 0 : 7
        rom = Data()
        for page in 0..<((bytes + 0x7FFFF) / 0x80000) {
            rom.append(Data(repeating:UInt8(page + 10),count:min(0x80000,bytes-rom.count)))
        }
        rom.replaceSubrange(0..<512,with:fixtureROM(save:false).prefix(512))
    }
    func select(_ address: Int, _ page: UInt8) {
        writes.append((address,page))
        if !ignoresWrites { selected = Int(page) & pageMask }
    }
    func read(_ address: Int, _ count: Int) throws -> Data {
        if failRead { throw FlashMDError.timeout }
        let window = mapper == .pierSolar ? 0x280000 : 0x380000
        let offset = (window..<window+0x80000).contains(address) ? selected * 0x80000 + address-window : address
        return Data(rom[offset..<offset+count])
    }
    func reader() -> BankedROMReader {
        BankedROMReader(mapper:mapper,size:rom.count,select:select,read:read)
    }
}

@Test func mapperDetectionUsesKnownSignaturesAndDemonsRevision() throws {
    var header = fixtureROM(save:false)
    header.replaceSubrange(0x100..<0x110,with:Data("SEGA DOA        ".utf8))
    header[0x18E] = 0x6E; header[0x18F] = 0x1E
    let doa = try ROMMetadata.parse(header)
    #expect(ROMMapper.detect(doa) == .segaSSF2)
    #expect(ROMMapper.segaSSF2.size(doa) == 0xEA0000)
    header[0x18E] = 0x12
    #expect(ROMMapper.segaSSF2.size(try ROMMetadata.parse(header)) == nil)
    header.replaceSubrange(0x100..<0x110,with:Data("SEGA SSF        ".utf8))
    #expect(ROMMapper.detect(try ROMMetadata.parse(header)) == .segaSSF2)
    #expect(ROMMapper.detect(try ROMMetadata.parse(fixtureROM())) == .linear)
    var retail = fixtureROM(save:false,title:"SUPER STREET FIGHTER II")
    retail[0x18E] = 0xE0; retail[0x18F] = 0x17
    let retailMetadata = try ROMMetadata.parse(retail)
    #expect(ROMMapper.detect(retailMetadata) == .segaSSF2)
    #expect(ROMMapper.segaSSF2.size(retailMetadata) == 0x500000)
    var pier = fixtureROM(save:false,title:"PIER SOLAR")
    pier.replaceSubrange(0x180..<0x18E,with:Data("GM T-574023-00".utf8))
    #expect(ROMMapper.detect(try ROMMetadata.parse(pier)) == .pierSolar)
}

@Test(arguments:[ROMMapper.segaSSF2,.pierSolar])
func mappedReadsCrossBanksAndRestoreOriginalWindow(mapper: ROMMapper) throws {
    let bus = MapperBus(mapper,bytes:0x800000), reader = bus.reader()
    #expect(try reader.qualify())
    let original = mapper == .pierSolar ? 0 : 7
    #expect(bus.selected == original)
    let output = try reader.readROM(offset:0x3FFFF1,count:65536)
    #expect(output == Data(bus.rom[0x3FFFF1..<0x3FFFF1+65536]))
    #expect(bus.selected == original)
    #expect(bus.writes.allSatisfy { $0.0 == (mapper == .pierSolar ? 0xA13003 : 0xA130FF) })
}

@Test func ignoredAndWrappedBankWritesCannotPassQualification() throws {
    let ignored = MapperBus(.segaSSF2,bytes:0xEA0000)
    ignored.ignoresWrites = true
    #expect(try !ignored.reader().qualify())
    #expect(ignored.selected == 7)
    let wrapped = MapperBus(.segaSSF2,bytes:0xEA0000)
    wrapped.pageMask = 7
    #expect(try !wrapped.reader().qualify())
    #expect(wrapped.selected == 7)
    let missingUpperBit = MapperBus(.segaSSF2,bytes:0xEA0000)
    missingUpperBit.pageMask = 15
    #expect(try !missingUpperBit.reader().qualify())
    #expect(missingUpperBit.selected == 7)
}

@Test func mapperReadFailureRestoresAndBoundsLastPartialBank() throws {
    let bus = MapperBus(.segaSSF2,bytes:0xEA0000), reader = bus.reader()
    #expect(try reader.qualify())
    #expect(try reader.readROM(offset:0xE9FFF1,count:15) == Data(bus.rom.suffix(15)))
    #expect(bus.selected == 7)
    let writeCount = bus.writes.count
    #expect(throws:(any Error).self) { try reader.readROM(offset:0xEA0000,count:2) }
    #expect(bus.writes.count == writeCount)
    bus.failRead = true
    #expect(throws:FlashMDError.timeout) { try reader.readROM(offset:0x400000,count:512) }
    #expect(bus.selected == 7)
}

@Test func unavailableMappedCartridgeRejectsBackupAndWriteOverrides() throws {
    let snapshot = CartridgeSnapshot(title:"Demons",regions:[],romSize:.init(bytes:0x400000,source:.header),
        flashCapacity:nil,rawSaveWindow:nil,mapper:.segaSSF2,romAccess:.unavailable,mappedROMBytes:0xEA0000)
    #expect(!snapshot.canBackupROM); #expect(!snapshot.canWrite); #expect(!snapshot.canRestoreSave)
    #expect(throws:(any Error).self) {
        try BackupRequest(cartridge:snapshot,romBytes:0x400000,saveLayout:nil,verify:true,destination:URL(fileURLWithPath:"/tmp"))
    }
    let overridden = snapshot.applying(try .init(romCapacity:0x400000,saveLayout:nil))
    #expect(overridden == snapshot)
}

@Test func bankedBackupMustBeCompleteAndVerified() throws {
    let snapshot = CartridgeSnapshot(title:"SSF2",regions:[],romSize:.init(bytes:0x500000,source:.header),
        flashCapacity:nil,rawSaveWindow:nil,mapper:.segaSSF2,romAccess:.banked,mappedROMBytes:0x500000)
    #expect(throws:(any Error).self) {
        try BackupRequest(cartridge:snapshot,romBytes:0x400000,saveLayout:nil,verify:false,destination:URL(fileURLWithPath:"/tmp"))
    }
    let request = try BackupRequest(cartridge:snapshot,romBytes:0x500000,saveLayout:nil,verify:false,destination:URL(fileURLWithPath:"/tmp"))
    #expect(request.verify)
}

private final class MapperTransport: ByteTransport, @unchecked Sendable {
    let bus: MapperBus
    var address = 0
    var pending = Data()
    var writes: [Data] = []
    init(_ bus: MapperBus) { self.bus = bus }
    func write(_ data: Data, timeout: TimeInterval) throws {
        writes.append(data)
        if data == Data([0x62]) { pending = Data([1,1]) }
        else if data.count == 6, data[0] == 0, data[2] == 0, data[4] == 0 {
            address = (Int(data[1]) << 16 | Int(data[3]) << 8 | Int(data[5])) * 2
        } else if data.count == 2, data[0] == 0x53 {
            // Word-addressed protocol: low-lane byte writes represent odd registers.
            let register = address + 1
            guard register == (bus.mapper == .pierSolar ? 0xA13003 : 0xA130FF) else {
                throw FlashMDError.invalid("Unexpected memory write in mapper test")
            }
            bus.select(register, data[1])
        } else if data.count == 5, data[0] == 1, data[2] == 1, data[4] == 0x82 {
            let length = (Int(data[1]) << 8 | Int(data[3])) * 2
            pending = try bus.read(address, length)
        } else if data == Data([5,1]) { }
        else { throw FlashMDError.invalid("Unexpected protocol command in mapper test") }
    }
    func read(count: Int, timeout: TimeInterval, cancellable: Bool) throws -> Data {
        guard pending.count == count else { throw FlashMDError.invalid("Wrong mapper reply length") }
        let data = pending; pending = Data(); return data
    }
    func close() { }
}

private func nativeMapperBus(_ mapper: ROMMapper) -> MapperBus {
    let bus = MapperBus(mapper,bytes:mapper == .pierSolar ? 0x800000 : 0x500000)
    if mapper == .segaSSF2 {
        bus.rom.replaceSubrange(0x100..<0x110,with:Data("SEGA SSF        ".utf8))
    } else {
        bus.rom.replaceSubrange(0x150..<0x150+10,with:Data("PIER SOLAR".utf8))
        bus.rom.replaceSubrange(0x180..<0x18E,with:Data("GM T-574023-00".utf8))
    }
    let end = bus.rom.count - 1
    for index in 0..<4 { bus.rom[0x1A4+index] = UInt8(truncatingIfNeeded:end >> (24-index*8)) }
    return bus
}

@Test(arguments:[ROMMapper.segaSSF2,.pierSolar])
func nativeAutomaticMappedBackupExportsEveryBankAndVerifies(mapper: ROMMapper) throws {
    let bus = nativeMapperBus(mapper), transport = MapperTransport(bus)
    let device = try FlashKitDevice(transport:transport,path:"test")
    let snapshot = try device.inspect(profile:.automatic)
    #expect(snapshot.mapper == mapper); #expect(snapshot.romAccess == .banked)
    #expect(snapshot.romReadLimit == bus.rom.count)
    #expect(!snapshot.canWrite); #expect(snapshot.saveLayout == nil)
    let folder = try tempFolder()
    defer { try? FileManager.default.removeItem(at:folder) }
    let request = try BackupRequest(cartridge:snapshot,romBytes:bus.rom.count,saveLayout:nil,verify:false,destination:folder)
    let result = try OperationRunner.backup(device:device,request:request,progress:{_ in})
    let artifact = try #require(result.manifest.artifacts.first)
    #expect(artifact.verified); #expect(result.manifest.mapper == mapper)
    let output = try Data(contentsOf:try #require(result.folder).appendingPathComponent(artifact.filename))
    #expect(output == bus.rom)
    #expect(Set(bus.writes.map { Int($0.1) }).isSuperset(of:Set(0..<bus.rom.count/0x80000)))
    try device.reset()
    #expect(bus.selected == (mapper == .pierSolar ? 0 : 7))
}

@Test func nativeIgnoredMapperReturnsIdentifiedButBlockedCartridge() throws {
    let bus = nativeMapperBus(.segaSSF2); bus.ignoresWrites = true
    let device = try FlashKitDevice(transport:MapperTransport(bus),path:"test")
    let snapshot = try device.inspect(profile:.automatic)
    #expect(snapshot.metadata != nil); #expect(snapshot.romAccess == .unavailable)
    #expect(!snapshot.canBackupROM)
    #expect(throws:(any Error).self) { try device.readROM(offset:0,count:512) }
    #expect(throws:(any Error).self) { try device.program(offset:0,data:Data([0,0])) }
    #expect(bus.selected == 7)
}

@Test func cancelledBankedReadRestoresWithoutEmittingAnotherRead() async throws {
    let task = Task {
        let bus = MapperBus(.pierSolar,bytes:0x800000), reader = bus.reader()
        withUnsafeCurrentTask { $0?.cancel() }
        #expect(throws:CancellationError.self) { try reader.readROM(offset:0x400000,count:512) }
        #expect(bus.selected == 0)
        #expect(bus.writes.count == 1)
    }
    await task.value
}

@Test(.enabled(if:ProcessInfo.processInfo.environment["FLASHMD_MAPPER_REFERENCE"] != nil))
func referenceROMReplaysThroughNativeMapperWithoutHardware() throws {
    let path = try #require(ProcessInfo.processInfo.environment["FLASHMD_MAPPER_REFERENCE"])
    let reference = try Data(contentsOf:URL(fileURLWithPath:path))
    let mapper = ROMMapper.detect(try ROMMetadata.parse(reference))
    #expect(mapper != .linear)
    let bus = MapperBus(mapper,bytes:reference.count); bus.rom = reference
    let device = try FlashKitDevice(transport:MapperTransport(bus),path:"offline-reference")
    let snapshot = try device.inspect(profile:.automatic)
    #expect(snapshot.romAccess == .banked)
    #expect(snapshot.romReadLimit == reference.count)
    var result = Data()
    for offset in stride(from:0,to:reference.count,by:32768) {
        result.append(try device.readROM(offset:offset,count:min(32768,reference.count-offset)))
    }
    #expect(result == reference)
    #expect(bus.selected == (mapper == .pierSolar ? 0 : 7))
}

@Test func knownMapperCannotBeOverriddenWithAnotherRegisterProtocol() throws {
    let bus = nativeMapperBus(.segaSSF2), transport = MapperTransport(bus)
    let device = try FlashKitDevice(transport:transport,path:"test")
    #expect(throws:(any Error).self) { try device.inspect(profile:.automatic,mapper:.pierSolar) }
    #expect(bus.writes.isEmpty)
}
