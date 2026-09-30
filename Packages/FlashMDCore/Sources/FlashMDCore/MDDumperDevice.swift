import Foundation

/// USB command layouts independently implemented from X-death25/MD_Dumper's public
/// md_dumper_main.h, md_dumper_read.h and md_dumper_write.h.
/// Slow 64-byte reads avoid the firmware's open-ended fast streaming mode.
public final class MDDumperDevice: CartridgeDevice, @unchecked Sendable {
    private let transport: any ByteTransport
    public let identity: String
    public let firmwareMajor: UInt8
    public let firmwareMinor: UInt8
    public let board: UInt8
    private var bankedReader: BankedROMReader?
    private var readLimit = 0x400000
    private var physicalReadLimit = 0x400000
    private var unavailable = false
    private var flash: MDDumperFlash?
    private var algorithmSelected = false
    public init(transport: any ByteTransport, location: String) throws {
        self.transport = transport
        do {
            var packet = Data(repeating:0,count:64); packet[0] = 0x10
            try transport.write(packet,timeout:2)
            let reply = try transport.read(count:64,timeout:2,cancellable:false)
            guard reply.count == 64, Data(reply.prefix(6)) == Data("READY!".utf8), reply[24] <= 4 else {
                throw FlashMDError.invalid("This USB device did not identify itself as an MD Dumper.")
            }
            guard (1...2).contains(reply[20]) else { throw FlashMDError.invalid("This MD Dumper firmware version is not supported yet.") }
            guard reply[25] == 0 else { throw FlashMDError.invalid("MD Dumper is in Master System mode. Switch it to Mega Drive mode and reconnect.") }
            firmwareMajor = reply[20]; firmwareMinor = reply[21]; board = reply[24]
            identity = "MD Dumper · \(location) · firmware \(reply[20]).\(reply[21]) · board \(reply[24])"
        } catch { transport.close(); throw error }
    }
    public func close() { transport.close() }
    private func packet(_ command: UInt8, address: Int = 0) -> Data {
        var result = Data(repeating:0,count:64)
        let word = address / 2
        result[0] = command
        result[1] = UInt8(truncatingIfNeeded:word)
        result[2] = UInt8(truncatingIfNeeded:word >> 8)
        result[3] = UInt8(truncatingIfNeeded:word >> 16)
        return result
    }
    private func send(_ packet: Data) throws { try transport.write(packet,timeout:5) }
    private func reply(timeout: TimeInterval = 5) throws -> Data {
        let data = try transport.read(count:64,timeout:timeout,cancellable:false)
        guard data.count == 64 else { throw FlashMDError.invalid("Incomplete MD Dumper reply. Reconnect USB.") }
        return data
    }
    private func waitStatus(index: Int, value: UInt8, timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try reply(timeout:min(5,max(0.001,deadline.timeIntervalSinceNow)))[index] == value { return }
        }
        throw FlashMDError.timeout
    }
    private func readBus(offset: Int, count: Int) throws -> Data {
        guard offset >= 0, count >= 0, offset <= 0x400000, count <= 0x400000-offset else {
            throw FlashMDError.invalid("Invalid MD Dumper ROM range.")
        }
        var output = Data()
        while output.count < count {
            let position = offset + output.count
            let base = position & ~63
            try send(packet(0x11,address:base))
            let bytes = try reply()
            let skipped = position-base, length = min(count-output.count,64-skipped)
            output.append(bytes[skipped..<skipped+length])
        }
        return output
    }
    private func selectBank(address: Int, page: UInt8) throws {
        var command = packet(0x20,address:address); command[5] = page
        try send(command)
        // The public client performs a slow read after a mapper command.
        _ = try readBus(offset:0x200000,count:64)
    }
    public func reset() throws {
        try bankedReader?.restore()
        algorithmSelected = false
    }
    public func inspect(profile: CartridgeProfile) throws -> CartridgeSnapshot {
        try inspect(profile:profile,mapper:.automatic)
    }
    public func inspect(profile: CartridgeProfile, mapper selection: ROMMapper) throws -> CartridgeSnapshot {
        try reset(); bankedReader = nil; unavailable = false; flash = nil
        let header = try readBus(offset:0,count:512)
        let valid = Data(header[0x100..<0x104]) == Data("SEGA".utf8)
        let metadata = valid ? try? ROMMetadata.parse(header) : nil
        let detected = ROMMapper.detect(metadata)
        guard detected == .linear || selection == .automatic || selection == detected else {
            throw FlashMDError.invalid("This cartridge uses \(detected.displayName). Select Automatic or \(detected.displayName).")
        }
        let mapper = selection == .automatic ? detected : selection
        if mapper != .linear || (metadata?.declaredROMBytes ?? 0) > 0x400000 {
            let size = mapper.size(metadata)
            var qualified = false
            // 0x20 is documented for Sega mapper registers. The public client does
            // not establish a Pier Solar register command; never guess on a cartridge.
            if mapper == .segaSSF2, let size, size > 0x400000, size <= 0x1000000 {
                let reader = BankedROMReader(mapper:mapper,size:size,register:0xA130F9,window:0x200000,originalPage:4,
                    select:{ [unowned self] address, page in try self.selectBank(address:address,page:page) },
                    read:{ [unowned self] offset, count in try self.readBus(offset:offset,count:count) })
                bankedReader = reader; qualified = try reader.qualify()
            }
            unavailable = !qualified; readLimit = size ?? 0
            let message = qualified ? "\(mapper.displayName) · bank switching verified. SRAM access and writing are unavailable." : "This cartridge’s bank switching is not supported by this reader. ROM backup is unavailable."
            return .init(title:metadata?.title ?? "Unknown cartridge",regions:metadata?.regions ?? [],
                romSize:metadata?.declaredROMBytes.map { .init(bytes:$0,source:.header) },flashCapacity:nil,rawSaveWindow:nil,
                metadata:metadata,identity:identity,fingerprint:hash(header),warning:message,profile:profile,
                mapper:mapper,mapperSelection:selection,romAccess:qualified ? .banked : .unavailable,
                mappedROMBytes:size,mapperMessage:message,readerKind:.mdDumper,saveWriteSupported:false)
        }
        // ID query is only made for linear cartridges; it must leave ROM mode restored.
        try send(packet(0x18)); let id = try reply()
        let candidate = MDDumperFlash.lookup(manufacturer:id[1],chip:id[3])
        guard try readBus(offset:0,count:512) == header else {
            throw FlashMDError.invalid("MD Dumper did not return to ROM read mode. Unplug USB before moving the cartridge.")
        }
        // Published SRAM commands expose the odd lane only, not a two-lane bus dump.
        let declared = profile == .automatic ? metadata?.saveLayout : profile.saveLayout
        let layout = declared?.lane == 1 ? declared : nil
        flash = board == 0 ? nil : candidate
        let physical = candidate?.capacity
        physicalReadLimit = min(physical ?? 0x400000,0x400000)
        readLimit = min(profile.romCapacityLimit ?? 0x400000,physical ?? 0x400000,layout?.base ?? 0x400000)
        // Chip erase affects the entire flash, so only expose programming if all of
        // that chip is reachable and does not overlap the SRAM window.
        let geometry = flash.flatMap { $0.capacity == readLimit ? $0.geometry : nil }
        let warning = declared != nil && layout == nil ? "This reader supports odd-lane SRAM only. ROM backup is available." :
            geometry == nil ? "ROM backup is available. ROM writing is not supported for this cartridge configuration." : nil
        return .init(title:metadata?.title ?? "Blank or invalid game header",regions:metadata?.regions ?? [],
            romSize:metadata?.declaredROMBytes.map { .init(bytes:$0,source:.header) },
            flashCapacity:.init(bytes:readLimit,source:physical == readLimit ? .hardware : .estimated),
            rawSaveWindow:layout.map { .init(bytes:$0.windowBytes,source:.header) },metadata:metadata,
            geometry:geometry,saveLayout:layout,identity:identity,fingerprint:hash(header),warning:warning,
            profile:profile,mapperSelection:selection,readerKind:.mdDumper,saveWriteSupported:layout?.activeBytes.isMultiple(of:32) == true)
    }
    public func readROM(offset: Int, count: Int) throws -> Data {
        guard !unavailable else { throw FlashMDError.invalid("This cartridge’s bank switching is not supported by this reader. ROM backup is unavailable.") }
        if let bankedReader { return try bankedReader.readROM(offset:offset,count:count) }
        guard offset >= 0, count >= 0, offset <= physicalReadLimit, count <= physicalReadLimit-offset else { throw FlashMDError.invalid("ROM read exceeds cartridge capacity.") }
        try Task.checkCancellation()
        return try readBus(offset:offset,count:count)
    }
    public func readSRAM(layout: SRAMLayout, offset: Int, count: Int) throws -> Data {
        guard bankedReader == nil, !unavailable, layout.lane == 1,
              offset >= 0, count >= 0, offset <= layout.windowBytes, count <= layout.windowBytes-offset else {
            throw FlashMDError.invalid("This reader supports odd-lane SRAM only.")
        }
        // Assemble the same raw representation used elsewhere; unused even bytes
        // are zero-filled, matching the official client's .srm export.
        var output = Data(repeating:0,count:count)
        var position = offset
        while position < offset+count {
            try Task.checkCancellation()
            let base = position & ~127
            try send(packet(0x12,address:layout.base+base)); let packed = try reply()
            let end = min(offset+count,base+128)
            for index in position..<end where index % 2 == 1 { output[index-offset] = packed[(index-base)/2] }
            position = end
        }
        return output
    }
    public func restore(layout: SRAMLayout, raw: Data) throws {
        guard bankedReader == nil, !unavailable, layout.lane == 1, raw.count == layout.windowBytes,
              layout.activeBytes.isMultiple(of:32) else { throw FlashMDError.invalid("Unsupported SRAM write layout for this reader.") }
        // Write only requested active bytes. Never issue the client's 0xBB blanket SRAM erase.
        let packed = try layout.pack(raw)
        for offset in stride(from:0,to:packed.count,by:32) {
            try Task.checkCancellation()
            var command = packet(0x13,address:layout.base+offset*2); command[7] = 0xCC
            command.replaceSubrange(32..<64,with:packed[offset..<offset+32])
            try send(command); try waitStatus(index:6,value:0xAA,timeout:10)
        }
    }
    public func erase(sector: FlashSector) throws {
        guard bankedReader == nil, !unavailable, let flash, sector.offset == 0,
              sector.bytes == flash.capacity, flash.capacity == readLimit else { throw FlashMDError.invalid("This MD Dumper flash erase is not supported.") }
        var command = packet(0x15); command[1] = flash.eraseAlgorithm
        try send(command); try waitStatus(index:0,value:0xFF,timeout:120)
        algorithmSelected = false
    }
    public func program(offset: Int, data: Data) throws {
        guard bankedReader == nil, !unavailable, let flash, flash.capacity == readLimit,
              offset >= 0, offset.isMultiple(of:2), !data.isEmpty, data.count.isMultiple(of:2),
              offset <= readLimit, data.count <= readLimit-offset else { throw FlashMDError.invalid("Unsupported MD Dumper flash write.") }
        if !algorithmSelected {
            var command = packet(0x65); command[4] = flash.writeAlgorithm
            try send(command); try waitStatus(index:6,value:0xDD,timeout:10); algorithmSelected = true
        }
        for start in stride(from:0,to:data.count,by:54) {
            let length = min(54,data.count-start)
            var command = packet(0x14,address:offset+start); command[4] = UInt8(length)
            command.replaceSubrange(5..<5+length,with:data[start..<start+length])
            try send(command)
        }
    }
}

private struct MDDumperFlash {
    let capacity: Int
    let manufacturer: UInt8
    let chip: UInt8
    let eraseAlgorithm: UInt8
    let writeAlgorithm: UInt8
    var geometry: FlashGeometry { .init(mdDumperCapacity:capacity,manufacturer:UInt16(manufacturer),deviceID:UInt16(chip),algorithm:Int(writeAlgorithm)) }
    static func lookup(manufacturer: UInt8, chip: UInt8) -> Self? {
        // Explicit allowlist from the public flashlist.csv; algorithm 5 uses a
        // separate buffered protocol and is intentionally not treated as algorithm 1–4.
        let id = Int(manufacturer) << 8 | Int(chip)
        let entry: (Int, UInt8, UInt8)
        switch id {
        case 0xBFB7: entry = (0x100000,1,1)
        case 0xBF53,0xBF5A,0xBF5B: entry = (0x400000,2,1)
        case 0x2056,0x2057,0xB0E3: entry = (0x400000,2,2)
        case 0xC2A7,0xC2A8: entry = (0x400000,2,3)
        case 0x98C2: entry = (0x200000,2,2)
        default: return nil
        }
        return .init(capacity:entry.0,manufacturer:manufacturer,chip:chip,eraseAlgorithm:entry.1,writeAlgorithm:entry.2)
    }
}
