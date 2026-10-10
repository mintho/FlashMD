import Foundation
import Testing
@testable import FlashMDCore

/// A separate serial peripheral model; accepts edges and decodes commands rather
/// than echoing the reader's expected packets. No memory-writing opcode is allowed.
final class SPIReadPeripheral {
    var memory = Data((0..<65536).map { UInt8(truncatingIfNeeded:($0 * 37) ^ ($0 >> 8)) })
    var status: UInt8 = 0x0C
    var pins: UInt8 = 0x0C
    var output: UInt8 = 1
    var forcedPin: UInt8?
    var failAfterReads: Int?
    var reads = 0
    var commands: [UInt8] = []
    private var input = 0
    private var bits = 0
    private var address = 0
    private var outputBits = 0
    private enum Mode { case command, address, status, memory }
    private var mode = Mode.command
    func drive(_ next: UInt8) throws {
        #expect(next & 0xF0 == 0 && next & 4 != 0)
        defer { pins = next }
        if next & 8 != 0 {
            mode = .command; bits = 0; input = 0; output = 1; outputBits = 0
            return
        }
        if next & 2 == 0 || pins & 2 != 0 { return }
        switch mode {
        case .command, .address:
            input = (input << 1) | Int(next & 1); bits += 1
            let needed = mode == .command ? 8 : 16
            if bits == needed {
                if mode == .address { address = input; mode = .memory }
                else {
                    commands.append(UInt8(input))
                    switch input {
                    case 3: mode = .address
                    case 5: mode = .status
                    default: throw FlashMDError.invalid("A memory-writing or unknown SPI opcode was sent.")
                    }
                }
                input = 0; bits = 0
            }
        case .memory, .status:
            let byte = mode == .status ? status : memory[address]
            output = (byte >> (7-outputBits)) & 1
            outputBits += 1
            if outputBits == 8 {
                outputBits = 0
                if mode == .memory { address = (address + 1) & 65535 }
            }
        }
    }
    func sample() throws -> UInt8 {
        reads += 1
        if let failAfterReads, reads == failAfterReads { throw FlashMDError.disconnected }
        return forcedPin ?? output
    }
    func reader(cancellation: @escaping () throws -> Void = {}) -> PierSolarSPIReader {
        .init(setPins:drive,readPin:sample,checkCancellation:cancellation)
    }
}

@Test func spiSaveReadUsesOnlyReadOpcodesAndPreservesEveryByte() throws {
    let bus = SPIReadPeripheral(), original = bus.memory, originalStatus = bus.status
    let reader = bus.reader()
    #expect(try reader.readStatus() == originalStatus)
    for (offset,count) in [(0,256),(0xFF,257),(0x7FFF,258),(0xFFFF,1),(65536,0)] {
        #expect(try reader.read(offset:offset,count:count) == Data(original[offset..<offset+count]))
    }
    let probe = try reader.probe()
    #expect(probe.samples.count == 5 && probe.status == originalStatus)
    #expect(bus.commands.allSatisfy { $0 == 3 || $0 == 5 })
    #expect(bus.pins == 12 && bus.output == 1 && bus.memory == original && bus.status == originalStatus)
    #expect(throws:(any Error).self) { try reader.read(offset:65535,count:2) }
}

@Test func spiFailureAndCancellationReleaseChipSelect() throws {
    let failed = SPIReadPeripheral(); failed.failAfterReads = 7
    #expect(throws:(any Error).self) { try failed.reader().read(offset:0xA123,count:16) }
    #expect(failed.pins == 12 && failed.commands == [3])
    let cancelled = SPIReadPeripheral()
    var checks = 0
    let reader = cancelled.reader {
        checks += 1
        if checks == 3 { throw CancellationError() }
    }
    #expect(throws:CancellationError.self) { try reader.read(offset:17,count:16) }
    #expect(cancelled.pins == 12 && cancelled.commands == [3])
}

@Test func spiBlankFloatingAndBusySignalsCannotQualifySaveReading() throws {
    for pin in [UInt8(0),1] {
        let bus = SPIReadPeripheral(); bus.forcedPin = pin
        #expect(throws:(any Error).self) { try bus.reader().probe() }
        #expect(bus.pins == 12)
    }
    let blank = SPIReadPeripheral(); blank.memory = Data(repeating:0xFF,count:65536)
    #expect(throws:(any Error).self) { try blank.reader().probe() }
    let busy = SPIReadPeripheral(); busy.status = 1
    #expect(throws:(any Error).self) { try busy.reader().probe() }
    #expect(busy.commands == [5] && busy.pins == 12)
}

/// Interprets both programmers' wire protocols into a shared cartridge model.
private final class PierSaveWire: ByteTransport, @unchecked Sendable {
    let md: Bool
    let spi = SPIReadPeripheral()
    var response = Data()
    var closed = false
    var spiControlWrites = 0
    var spiRegisterReads = 0
    var maximumSPIResponseBytes = 0
    var failROMRestore = false
    var pages = [0,0,0]
    var address = 0
    var length = 0
    var rom = Data()
    init(md: Bool) {
        self.md = md
        for page in 0..<16 { rom.append(Data(repeating:UInt8(page + 10),count:0x80000)) }
        var header = Data(fixtureROM(save:false,title:"PIER SOLAR").prefix(512))
        header.replaceSubrange(0x180..<0x18E,with:Data("GM T-574023-00 ".utf8))
        header.replaceSubrange(0x1A4..<0x1A8,with:Data([0,0x7F,0xFF,0xFF]))
        header.replaceSubrange(0x1B0..<0x1B2,with:Data("EP".utf8))
        rom.replaceSubrange(0..<512,with:header)
    }
    func wordAddress(_ packet: Data) -> Int { (Int(packet[1]) | Int(packet[2]) << 8 | Int(packet[3]) << 16) * 2 }
    func control(address: Int, value: UInt8) throws {
        let even = address & ~1
        if even == 0xA13008 { spiControlWrites += 1; try spi.drive(value) }
        else {
            #expect([0xA13002,0xA13004,0xA13006].contains(even))
            if even == 0xA13002, value == 0, failROMRestore { throw FlashMDError.timeout }
            pages[(even-0xA13002)/2] = Int(value)
        }
    }
    func bus(_ offset: Int, count: Int) throws -> Data {
        // Control reads are an open bus; only the distinct 0B register drives SO.
        if offset == 0xA13008 { return Data(repeating:0xFF,count:count) }
        if offset == 0xA1300A {
            spiRegisterReads += 1
            let bit = try spi.sample()
            var bytes = Data(repeating:0,count:count)
            for index in stride(from:1,to:count,by:2) { bytes[index] = bit }
            return bytes
        }
        #expect(offset < 0x400000)
        let logical: Int
        if offset >= 0x280000 {
            let slot = (offset-0x280000)/0x80000
            logical = pages[slot]*0x80000 + offset%0x80000
        } else { logical = offset }
        return Data(rom[logical..<logical+count])
    }
    func write(_ data: Data, timeout: TimeInterval) throws {
        let previousReads = spiRegisterReads
        if md {
            #expect(data.count == 64 && response.isEmpty)
            switch data[0] {
            case 0x10:
                response = Data(repeating:0,count:64)
                response.replaceSubrange(0..<6,with:Data("READY!".utf8))
                response[20] = 2; response[24] = 3
            case 0x11: #expect(data[4] == 0); response = try bus(wordAddress(data),count:64)
            case 0x20: try control(address:wordAddress(data),value:data[5])
            default: Issue.record("Unexpected or destructive MD Dumper command \(data[0])")
            }
        } else {
            var index = 0
            while index < data.count {
                switch data[index] {
                case 0x62: response.append(contentsOf:[1,1]); index += 1
                case 0: address = ((address << 8) | Int(data[index+1])) & 0x7FFFFF; index += 2
                case 1: length = ((length << 8) | Int(data[index+1])) & 65535; index += 2
                case 5: index += 2 // existing timing parameter
                case 0x53: try control(address:address*2,value:data[index+1]); index += 2
                case 0x42: response.append(try bus(address*2,count:2)); index += 1
                case 0x82: response.append(try bus(address*2,count:length*2)); index += 1
                default: Issue.record("Unexpected or destructive FlashKit command \(data[index])"); index = data.count
                }
            }
        }
        if spiRegisterReads != previousReads { maximumSPIResponseBytes = max(maximumSPIResponseBytes,response.count) }
    }
    func read(count: Int, timeout: TimeInterval, cancellable: Bool) throws -> Data {
        guard response.count >= count else { throw FlashMDError.timeout }
        let next = Data(response.prefix(count)); response.removeFirst(count); return next
    }
    func close() { closed = true }
}

@Test(arguments:[false,true]) func flashKitSPIReadsSeparateRegisterWithBoundedResponses(pipelined: Bool) throws {
    let wire = PierSaveWire(md:false), original = wire.spi.memory
    let device = try FlashKitDevice(transport:wire,path:"test")
    device.pierSolarSaveEnabled = true
    device.pierSolarSPIPipelined = pipelined
    _ = try device.inspect(profile:.automatic)
    for (offset,count) in [(0xFF,257),(0x7FFF,258),(0xFFFF,1),(65536,0)] {
        #expect(try device.readSerialSave(offset:offset,count:count) == Data(original[offset..<offset+count]))
    }
    #expect(wire.maximumSPIResponseBytes <= 64)
    #expect(wire.spi.memory == original && wire.spi.pins == 12 && wire.pages == [0,0,0])
}

@Test func qualifiedFlashKitReadsPierSavesAutomaticallyWhileMDDumperRemainsBlocked() throws {
    let flashWire = PierSaveWire(md:false)
    let flashKit = try FlashKitDevice(transport:flashWire,path:"test")
    let supported = try flashKit.inspect(profile:.automatic)
    #expect(supported.canBackupSave && supported.saveStatus == .readOnly)
    #expect(!supported.canStartSaveWrite && !supported.canWrite)
    #expect(try flashKit.readSerialSave(offset:0,count:32) == Data(flashWire.spi.memory.prefix(32)))
    let mdWire = PierSaveWire(md:true)
    let dumper = try MDDumperDevice(transport:mdWire,location:"test")
    let unsupported = try dumper.inspect(profile:.automatic)
    #expect(unsupported.canBackupROM && !unsupported.canBackupSave)
    #expect(unsupported.saveStatus == .unsupported)
    #expect(unsupported.warning == "This reader cannot back up Pier Solar saves. Use a FlashKit. ROM backup is available.")
    #expect(mdWire.spiControlWrites == 0 && mdWire.spiRegisterReads == 0)
    #expect(throws:(any Error).self) { try dumper.readSerialSave(offset:0,count:16) }
}

@Test(arguments:[false,true]) func pierSaveAdaptersRequireQualificationAndKeepROMAndSaveIntact(md: Bool) throws {
    let wire = PierSaveWire(md:md), originalROM = wire.rom, originalSave = wire.spi.memory
    let device: any CartridgeDevice
    if md { device = try MDDumperDevice(transport:wire,location:"test") }
    else { device = try FlashKitDevice(transport:wire,path:"test") }
    if let dumper = device as? MDDumperDevice { dumper.pierSolarSaveEnabled = false }
    if let flashKit = device as? FlashKitDevice { flashKit.pierSolarSaveEnabled = false }
    let initial = try device.inspectConfigured(profile:.automatic,override:nil,mapper:.automatic)
    #expect(initial.mapper == .pierSolar && !initial.canBackupSave && initial.serialSave == .pierSolar)
    #expect(wire.spiControlWrites == 0 && wire.spiRegisterReads == 0)
    #expect(throws:(any Error).self) { try device.readSerialSave(offset:0,count:16) }
    if let dumper = device as? MDDumperDevice { dumper.pierSolarSaveEnabled = true }
    if let flashKit = device as? FlashKitDevice { flashKit.pierSolarSaveEnabled = true }
    let qualified = try device.inspectConfigured(profile:.automatic,override:nil,mapper:.automatic)
    #expect(qualified.canBackupSave && !qualified.canStartSaveWrite && !qualified.canWrite)
    #expect(qualified.saveStatus == .readOnly && qualified.saveLayout == nil)
    #expect(try device.readSerialSave(offset:0x1FF8,count:32) == Data(originalSave[0x1FF8..<0x2018]))
    #expect(wire.spi.commands.allSatisfy { $0 == 3 || $0 == 5 })
    #expect(wire.spi.pins == 12 && wire.pages == [0,0,0] && wire.rom == originalROM && wire.spi.memory == originalSave)
    let layout = try SRAMLayout(start:0x200001,end:0x20FFFF,lane:1)
    #expect(throws:(any Error).self) { try device.restore(layout:layout,raw:Data(count:layout.windowBytes)) }
}

@Test(arguments:[false,true]) func pierSPIAdapterFailureStillReleasesPinsWithoutWritingMemory(md: Bool) throws {
    let wire = PierSaveWire(md:md), originalROM = wire.rom, originalSave = wire.spi.memory
    let device: any CartridgeDevice
    if md {
        let dumper = try MDDumperDevice(transport:wire,location:"test")
        dumper.pierSolarSaveEnabled = true; device = dumper
    } else {
        let flashKit = try FlashKitDevice(transport:wire,path:"test")
        flashKit.pierSolarSaveEnabled = true; device = flashKit
    }
    _ = try device.inspect(profile:.automatic)
    wire.spi.failAfterReads = wire.spi.reads+7
    #expect(throws:(any Error).self) { try device.readSerialSave(offset:0,count:16) }
    #expect(wire.spi.pins == 12 && wire.rom == originalROM && wire.spi.memory == originalSave)
    #expect(wire.spi.commands.allSatisfy { $0 == 3 || $0 == 5 })
}

@Test(arguments:[false,true]) func unreliableSPISaveDoesNotBlockQualifiedROMBackup(md: Bool) throws {
    let wire = PierSaveWire(md:md), originalROM = wire.rom, originalSave = wire.spi.memory
    wire.spi.forcedPin = 1
    let device: any CartridgeDevice
    if md {
        let dumper = try MDDumperDevice(transport:wire,location:"test")
        dumper.pierSolarSaveEnabled = true; device = dumper
    } else {
        let flashKit = try FlashKitDevice(transport:wire,path:"test")
        flashKit.pierSolarSaveEnabled = true; device = flashKit
    }
    let snapshot = try device.inspect(profile:.automatic)
    #expect(snapshot.romAccess == .banked && !snapshot.canBackupSave && !snapshot.canWrite)
    #expect(snapshot.warning == "Save memory could not be read reliably. ROM backup is available.")
    #expect(try device.readROM(offset:0x480000,count:256) == Data(originalROM[0x480000..<0x480100]))
    #expect(wire.spi.pins == 12 && wire.spi.memory == originalSave && wire.rom == originalROM)
}

@Test(arguments:[false,true]) func failedSPIROMPreflightClosesReaderBeforeAnySerialCommands(md: Bool) throws {
    let wire = PierSaveWire(md:md), originalSave = wire.spi.memory
    let device: any CartridgeDevice
    if md {
        let dumper = try MDDumperDevice(transport:wire,location:"test")
        dumper.pierSolarSaveEnabled = true; device = dumper
    } else {
        let flashKit = try FlashKitDevice(transport:wire,path:"test")
        flashKit.pierSolarSaveEnabled = true; device = flashKit
    }
    _ = try device.inspect(profile:.automatic)
    let commandsBefore = wire.spiControlWrites
    wire.failROMRestore = true
    #expect(throws:(any Error).self) { try device.readSerialSave(offset:0,count:16) }
    #expect(wire.closed && wire.spiControlWrites == commandsBefore && wire.spi.memory == originalSave)
    #expect(throws:(any Error).self) { try device.readROM(offset:0,count:16) }
}

@Test func wrongCartridgeCannotGainSPIAccessBySelectingThePierMapper() throws {
    let wire = PierSaveWire(md:true)
    wire.rom.replaceSubrange(0x180..<0x18E,with:Data("GM 00000000-00".utf8))
    let device = try MDDumperDevice(transport:wire,location:"test")
    device.pierSolarSaveEnabled = true
    _ = try device.inspect(profile:.automatic,mapper:.pierSolar)
    #expect(throws:(any Error).self) { try device.probePierSolarSave() }
    #expect(wire.spiControlWrites == 0 && wire.spiRegisterReads == 0)
}

@Test(arguments:[false,true]) func hardwareSPIReferenceGuardReadsHeaderBeforeAnyCartridgeControl(md: Bool) throws {
    let wire = PierSaveWire(md:md), reference = Data(wire.rom.prefix(512))
    if md {
        let device = try MDDumperDevice(transport:wire,location:"test")
        try device.validatePierSolarHeader(reference)
        wire.rom[0x123] ^= 1
        #expect(throws:(any Error).self) { try device.validatePierSolarHeader(reference) }
    } else {
        let device = try FlashKitDevice(transport:wire,path:"test")
        try device.validatePierSolarHeader(reference)
        wire.rom[0x123] ^= 1
        #expect(throws:(any Error).self) { try device.validatePierSolarHeader(reference) }
    }
    #expect(wire.pages == [0,0,0] && wire.spi.commands.isEmpty)
    #expect(wire.spiControlWrites == 0 && wire.spiRegisterReads == 0)
}

private final class SerialSaveDevice: CartridgeDevice, @unchecked Sendable {
    let identity = "serial-test"
    let bytes = Data((0..<65536).map { UInt8(truncatingIfNeeded:$0 * 37) })
    var reads = 0
    var corruptVerification = false
    func inspect(profile: CartridgeProfile) throws -> CartridgeSnapshot {
        .init(title:"PIER SOLAR",regions:["Europe"],romSize:nil,flashCapacity:nil,rawSaveWindow:nil,
              serialSave:.pierSolar,identity:identity,fingerprint:"serial-test",mapper:.pierSolar,
              romAccess:.banked,mappedROMBytes:0x800000,saveWriteSupported:false,saveStatus:.readOnly)
    }
    func inspect(profile: CartridgeProfile, mapper: ROMMapper) throws -> CartridgeSnapshot { try inspect(profile:profile) }
    func readSerialSave(offset: Int, count: Int) throws -> Data {
        reads += 1; var block = Data(bytes[offset..<offset+count])
        if corruptVerification && reads > 256 { block[0] ^= 1 }
        return block
    }
    func readROM(offset: Int, count: Int) throws -> Data { throw FlashMDError.invalid("ROM not requested") }
    func readSRAM(layout: SRAMLayout, offset: Int, count: Int) throws -> Data { throw FlashMDError.invalid("SRAM not requested") }
    func erase(sector: FlashSector) throws { Issue.record("Erase invoked"); throw FlashMDError.invalid("No erase") }
    func program(offset: Int, data: Data) throws { Issue.record("Program invoked"); throw FlashMDError.invalid("No program") }
    func restore(layout: SRAMLayout, raw: Data) throws { Issue.record("Restore invoked"); throw FlashMDError.invalid("No restore") }
    func reset() throws {}
    func close() {}
}

@Test func serialSaveBackupsUseBytesOnlyAndAlwaysVerifyBeforePublishing() throws {
    let device = SerialSaveDevice(), snapshot = try device.inspect(profile:.automatic), destination = try tempFolder()
    defer { try? FileManager.default.removeItem(at:destination) }
    let request = try BackupRequest(cartridge:snapshot,romBytes:nil,saveLayout:nil,saveFormat:.packed,verify:false,destination:destination,includeSerialSave:true)
    #expect(request.verify)
    let result = try OperationRunner.backup(device:device,request:request,progress:{_ in})
    let artifact = try #require(result.manifest.artifacts.first), folder = try #require(result.folder)
    #expect(artifact.verified && artifact.bytes == 65536 && artifact.saveFormat == .packed)
    #expect(try Data(contentsOf:folder.appendingPathComponent(artifact.filename)) == device.bytes)
    #expect(result.manifest.serialSave == .pierSolar && result.manifest.saveLayout == nil && result.manifest.unusedSaveLaneFill == nil)
    #expect(result.manifest.limitations?.contains(where:{ $0.contains("physical chip capacity") }) == true)
    #expect(throws:(any Error).self) {
        try BackupRequest(cartridge:snapshot,romBytes:nil,saveLayout:nil,saveFormat:.raw,verify:true,destination:destination,includeSerialSave:true)
    }
    #expect(throws:(any Error).self) {
        try WritePlan(target:snapshot,image:nil,romName:nil,save:device.bytes,saveName:"save.srm",format:.packed,backupDestination:nil)
    }
    device.reads = 0; device.corruptVerification = true
    do {
        _ = try OperationRunner.backup(device:device,request:request,progress:{_ in})
        Issue.record("Mismatching serial save was published")
    } catch let failure as OperationFailure {
        #expect(failure.result.manifest.artifacts.isEmpty)
        #expect(failure.result.manifest.readDifference?.memory == "SPI save")
        if let folder = failure.result.folder {
            #expect(try FileManager.default.contentsOfDirectory(atPath:folder.path).allSatisfy { !$0.hasSuffix(".srm") })
        }
    }
}
