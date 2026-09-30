import Foundation

public protocol CartridgeDevice: AnyObject, Sendable {
    var identity: String { get }
    func inspect(profile: CartridgeProfile) throws -> CartridgeSnapshot
    func inspect(profile: CartridgeProfile, mapper: ROMMapper) throws -> CartridgeSnapshot
    func readROM(offset: Int, count: Int) throws -> Data
    func readSRAM(layout: SRAMLayout, offset: Int, count: Int) throws -> Data
    func erase(sector: FlashSector) throws
    func program(offset: Int, data: Data) throws
    func restore(layout: SRAMLayout, raw: Data) throws
    func reset() throws
    func close()
}

public extension CartridgeDevice {
    func inspect(profile: CartridgeProfile, mapper: ROMMapper) throws -> CartridgeSnapshot {
        guard mapper == .automatic || mapper == .linear else { throw FlashMDError.invalid("This reader does not support mapper selection.") }
        return try inspect(profile:profile)
    }
}

public final class FlashKitDevice: CartridgeDevice, @unchecked Sendable {
    private let transport: any ByteTransport
    public let identity: String
    private let deviceID: String
    private var bankedReader: BankedROMReader?
    private var mappedCartridge = false
    private var mapperUnavailable = false
    public init(transport: any ByteTransport, path: String) throws {
        self.transport = transport
        do {
            try transport.write(Data([0x62]), timeout: 0.5)
            let id = try transport.read(count: 2, timeout: 0.5, cancellable: true)
            guard id[0] == id[1], id[0] != 0, id[0] != 0xFF else { throw FlashMDError.invalid("This port did not identify itself as a FlashKit programmer.") }
            deviceID = String(format: "%02X%02X", id[0], id[1])
            identity = "\(path) · \(deviceID)"
            try transport.write(Data([5,1]), timeout: 2)
        } catch { transport.close(); throw error }
    }
    public func close() { transport.close() }
    private func address(_ value: Int) throws {
        let word = value >> 1
        try transport.write(Data([0,UInt8(truncatingIfNeeded: word >> 16),0,UInt8(truncatingIfNeeded: word >> 8),0,UInt8(truncatingIfNeeded: word)]), timeout: 2)
    }
    private func word(_ value: Int, at offset: Int) throws {
        try address(offset)
        try transport.write(Data([0x43, UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]), timeout: 2)
    }
    private func byte(_ value: UInt8, at offset: Int) throws {
        try address(offset); try transport.write(Data([0x53,value]), timeout: 2)
    }
    private func readWord(_ offset: Int) throws -> UInt16 {
        try address(offset); try transport.write(Data([0x42]), timeout: 2)
        let data = try transport.read(count: 2, timeout: 2, cancellable: true)
        return UInt16(data[0]) << 8 | UInt16(data[1])
    }
    private func readBytes(offset: Int, count: Int, cancellable: Bool = true) throws -> Data {
        guard offset >= 0, count >= 0, count <= 65536 else { throw FlashMDError.invalid("Invalid cartridge read range.") }
        if count == 0 { return Data() }
        let base = offset & ~1, skipped = offset & 1
        let busCount = (count + skipped + 1) & ~1
        guard busCount <= 65536 else { throw FlashMDError.invalid("Read block exceeds the device limit.") }
        let words = busCount / 2
        try address(base)
        try transport.write(Data([1,UInt8(truncatingIfNeeded: words >> 8),1,UInt8(truncatingIfNeeded: words),0x82]), timeout: 2)
        let data = try transport.read(count: busCount, timeout: 5, cancellable: cancellable)
        return Data(data[skipped..<skipped+count])
    }
    public func reset() throws {
        if mappedCartridge { try bankedReader?.restore(); return }
        try word(0xF0, at: 0); try word(0, at: 0xA13000); try transport.write(Data([5,1]), timeout: 2) }
    public func readROM(offset: Int, count: Int) throws -> Data {
        guard !mapperUnavailable else { throw FlashMDError.invalid("This cartridge’s bank switching is not supported by this reader. ROM backup is unavailable.") }
        if let bankedReader { return try bankedReader.readROM(offset:offset,count:count) }
        try word(0, at: 0xA13000)
        return try readBytes(offset: offset, count: count)
    }
    public func readSRAM(layout: SRAMLayout, offset: Int, count: Int) throws -> Data {
        guard !mappedCartridge else { throw FlashMDError.invalid("SRAM access is not supported for this mapper.") }
        try word(0xFFFF, at: 0xA13000)
        return try readBytes(offset: layout.base+offset, count: count)
    }
    public func inspect(profile: CartridgeProfile) throws -> CartridgeSnapshot {
        try inspect(profile:profile,mapper:.automatic)
    }
    public func inspect(profile: CartridgeProfile, mapper selection: ROMMapper) throws -> CartridgeSnapshot {
        try bankedReader?.restore()
        bankedReader = nil; mappedCartridge = false; mapperUnavailable = false
        let header = try readBytes(offset: 0, count: 512)
        let metadata = try? ROMMetadata.parse(header)
        let validHeader = Data(header[0x100..<0x104]) == Data("SEGA".utf8)
        let detected = ROMMapper.detect(validHeader ? metadata : nil)
        guard detected == .linear || selection == .automatic || selection == detected else {
            throw FlashMDError.invalid("This cartridge uses \(detected.displayName). Select Automatic or \(detected.displayName).")
        }
        let mapper = selection == .automatic ? detected : selection
        let oversized = (metadata?.declaredROMBytes ?? 0) > 0x400000
        if mapper != .linear || detected != .linear || oversized {
            mappedCartridge = true
            let size = mapper.size(metadata)
            var qualified = false
            if mapper == .segaSSF2 || mapper == .pierSolar,
               let size, size > 0x400000, size <= 0x1000000 {
                let reader = BankedROMReader(mapper:mapper,size:size,
                    select:{ [unowned self] address, value in try self.byte(value,at:address) },
                    read:{ [unowned self] address, count in try self.readBytes(offset:address,count:count,cancellable:false) })
                bankedReader = reader
                qualified = try reader.qualify()
            }
            mapperUnavailable = !qualified
            let message: String
            if qualified { message = "\(mapper.displayName) · bank switching verified. SRAM access and writing are unavailable." }
            else if mapper == .linear { message = "Complete ROM unavailable. Select a known ROM mapper in Advanced Settings." }
            else if size == nil { message = "Complete ROM unavailable. This mapper revision has no known ROM size." }
            else { message = "This cartridge’s bank switching is not supported by this reader. ROM backup is unavailable." }
            return .init(title:metadata?.title ?? "Unknown cartridge",regions:metadata?.regions ?? [],
                romSize:metadata?.declaredROMBytes.map { .init(bytes:$0,source:.header) },
                flashCapacity:nil,rawSaveWindow:nil,metadata:metadata,identity:identity,
                fingerprint:hash(header),warning:message,profile:profile,rawHeader:Data(header[0x100..<0x200]),
                mapper:mapper,mapperSelection:selection,romAccess:qualified ? .banked : .unavailable,
                mappedROMBytes:size,mapperMessage:message)
        }
        defer { try? reset() }
        try word(0,at:0xA13000)
        var geometry: FlashGeometry?, warning: String?
        do {
            try byte(0x98, at: 0xAA)
            let bus = try readBytes(offset: 0, count: 256)
            let cfi = Data(stride(from: 1, to: bus.count, by: 2).map { bus[$0] })
            try word(0xF0, at: 0)
            if Data(cfi[0x10..<0x13]) == Data("QRY".utf8) {
                try word(0xAA, at: 0xAAA); try word(0x55, at: 0x554); try word(0x90, at: 0xAAA)
                let manufacturer = try readWord(0), chip = try readWord(2)
                let extended = try readWord(0x1C), boot = try readWord(0x1E)
                try word(0xF0, at: 0)
                geometry = try FlashGeometry(cfi: cfi, manufacturer: manufacturer, deviceID: chip, extendedID: extended, bootID: boot)
            } else { warning = "No CFI flash detected. ROM backup may still work; writing is disabled." }
        } catch let error as FlashMDError {
            if error == .disconnected || error == .timeout { throw error }
            warning = error.localizedDescription
        }
        let title = validHeader ? (metadata?.title ?? "Untitled cartridge") : (geometry != nil ? "Blank or invalid game header" : "Unreadable cartridge")
        let layout = profile == .automatic ? (validHeader ? metadata?.saveLayout : nil) : profile.saveLayout
        let capacity: MemoryMeasurement?
        if profile == .automatic {
            // A header describes a game's requirements, not the board. Use it as an explicit
            // assumption; never mistake the physical chip's size for accessible ROM space.
            capacity = geometry.map { CartridgeConfiguration.inferredCapacity(geometry:$0,saveLayout:layout) }
            let assumption = layout != nil
                ? "Automatic configuration uses the header's SRAM range and keeps ROM below it. Adjust Advanced Settings for a switchable mapper or a different physical save size."
                : "Automatic configuration assumes linear ROM access up to 4 MiB. A missing save declaration does not prove that the board has no SRAM. Adjust Advanced Settings if needed."
            warning = [warning, metadata?.saveWarning, assumption].compactMap { $0 }.joined(separator:" ")
        } else {
            capacity = geometry.flatMap { profile.usableCapacity(for:$0) } ?? profile.romCapacityLimit.map { .init(bytes:$0,source:.profile) }
        }
        return CartridgeSnapshot(title: title, regions: validHeader ? metadata?.regions ?? [] : [], romSize: validHeader ? metadata?.declaredROMBytes.map { .init(bytes: $0, source: .header) } : nil,
            flashCapacity: capacity, rawSaveWindow: layout.map { .init(bytes: $0.windowBytes, source: profile == .automatic ? .header : .profile) },
            metadata: validHeader ? metadata : nil, geometry: geometry, saveLayout: layout,
            identity: identity, fingerprint: hash(header), warning: warning, profile: profile, rawHeader:Data(header[0x100..<0x200]),mapperSelection:selection)
    }
    public func erase(sector: FlashSector) throws {
        guard !mappedCartridge else { throw FlashMDError.invalid("Writing is unavailable for banked cartridges.") }
        try word(0, at: 0xA13000); try transport.write(Data([5,0]), timeout: 2)
        try word(0xAA, at: 0xAAA); try word(0x55, at: 0x554); try word(0x80, at: 0xAAA)
        try word(0xAA, at: 0xAAA); try word(0x55, at: 0x554); try word(0x30, at: sector.offset)
        try transport.write(Data([4,0x42]), timeout: 2)
        _ = try transport.read(count: 2, timeout: 120, cancellable: false)
    }
    public func program(offset: Int, data: Data) throws {
        guard !mappedCartridge else { throw FlashMDError.invalid("Writing is unavailable for banked cartridges.") }
        guard data.count > 0, data.count <= 4096, data.count.isMultiple(of: 2) else { throw FlashMDError.invalid("Invalid programming block.") }
        try byte(0xAA, at: 0xAAA); try byte(0x55, at: 0x554); try byte(0x20, at: 0xAAA)
        try address(offset)
        var packet = Data()
        for index in stride(from: 0, to: data.count, by: 2) { packet.append(contentsOf: [0x53,0xA0,0xC3,data[index],data[index+1],4]) }
        try transport.write(packet, timeout: 30)
        try transport.write(Data([0x42]), timeout: 2)
        _ = try transport.read(count: 2, timeout: 30, cancellable: false)
        // Exit bypass at a completed block boundary.
        try byte(0x90, at: 0); try byte(0, at: 0); try word(0xF0, at: 0)
    }
    public func restore(layout: SRAMLayout, raw: Data) throws {
        guard !mappedCartridge else { throw FlashMDError.invalid("Writing is unavailable for banked cartridges.") }
        guard layout.lane != 0 else { throw FlashMDError.invalid("Even-lane SRAM writes are not qualified for this programmer.") }
        guard raw.count == layout.windowBytes else { throw FlashMDError.invalid("Save representation length does not match the cartridge.") }
        try word(0xFFFF, at: 0xA13000)
        if let lane = layout.lane {
            // A single buffered packet uses 8-bit writes exclusively on the active lane.
            for start in stride(from: 0, to: raw.count, by: 2048) {
                try Task.checkCancellation()
                var packet = Data()
                for index in stride(from: start+lane, to: min(start+2048,raw.count), by: 2) {
                    let address = (layout.base+index) >> 1
                    packet.append(contentsOf: [0,UInt8(truncatingIfNeeded: address >> 16),0,UInt8(truncatingIfNeeded: address >> 8),0,UInt8(truncatingIfNeeded: address),0x53,raw[index]])
                }
                try transport.write(packet, timeout: 10)
            }
        } else {
            for offset in stride(from: 0, to: raw.count, by: 4096) {
                try Task.checkCancellation()
                let chunk = Data(raw[offset..<min(offset+4096,raw.count)]), words = chunk.count/2
                try address(layout.base+offset)
                try transport.write(Data([1,UInt8(truncatingIfNeeded: words >> 8),1,UInt8(truncatingIfNeeded: words),0x83])+chunk, timeout: 10)
            }
        }
    }
}
