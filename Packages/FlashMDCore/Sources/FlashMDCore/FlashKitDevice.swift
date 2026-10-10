import Foundation

public protocol CartridgeDevice: AnyObject, Sendable {
    var identity: String { get }
    var preferredROMReadBytes: Int { get }
    var requiresROMBackupVerification: Bool { get }
    func inspect(profile: CartridgeProfile) throws -> CartridgeSnapshot
    func inspect(profile: CartridgeProfile, mapper: ROMMapper) throws -> CartridgeSnapshot
    func readROM(offset: Int, count: Int) throws -> Data
    func readROMForVerification(offset: Int, count: Int) throws -> Data
    func readSRAM(layout: SRAMLayout, offset: Int, count: Int) throws -> Data
    func readSerialSave(offset: Int, count: Int) throws -> Data
    func qualifySRAM(layout: SRAMLayout) throws -> SaveMemoryStatus
    func checkSRAMWriting(layout: SRAMLayout, originalRaw: Data) throws
    func erase(sector: FlashSector) throws
    func program(offset: Int, data: Data) throws
    func restore(layout: SRAMLayout, raw: Data) throws
    func reset() throws
    func close()
    func configureROMWriting(_ cartridge: CartridgeSnapshot) throws
}

public extension CartridgeDevice {
    func configureROMWriting(_ cartridge: CartridgeSnapshot) throws {}
    func readSerialSave(offset: Int, count: Int) throws -> Data {
        throw FlashMDError.invalid("Serial save reading is not supported by this reader.")
    }
    func checkSRAMWriting(layout: SRAMLayout, originalRaw: Data) throws {
        throw FlashMDError.invalid("This reader cannot verify SRAM writing for this cartridge.")
    }
    func qualifySRAM(layout: SRAMLayout) throws -> SaveMemoryStatus { try SaveMemoryProbe.qualify(self,layout:layout) }
    func inspectConfigured(profile: CartridgeProfile, override: CartridgeConfiguration?, mapper: ROMMapper) throws -> CartridgeSnapshot {
        let original = try inspect(profile:profile,mapper:mapper)
        let configured = original.applying(override)
        let result: CartridgeSnapshot
        if configured.serialSave != nil { result = configured }
        else if original.metadata?.saveWarning != nil { result = configured.withSaveStatus(.unsupported) }
        else if override != nil, configured.mapper == .linear, let layout = configured.saveLayout,
                configured.saveStatus != .confirmed {
            let status = try qualifySRAM(layout:layout)
            // A manual read remains available when selection is inconclusive; writing does not.
            result = configured.withSaveStatus(status == .confirmed || status == .readOnly ? status : .manual)
        } else { result = configured }
        try configureROMWriting(result)
        return result
    }
    var preferredROMReadBytes: Int { 32768 }
    var requiresROMBackupVerification: Bool { false }
    func readROMForVerification(offset: Int, count: Int) throws -> Data {
        try readROM(offset:offset,count:count)
    }
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
    private var qualifiedSaveLayout: SRAMLayout?
    private var requiresReconnect = false
    private var qualifiedGeometry: FlashGeometry?
    private var programmingLimit = 0
    private var pendingSaveWriteCheck: SRAMLayout?
    private var saveWritingUnqualified = false
    private var checkingSaveWriting = false
    var pierSolarSaveEnabled = PierSolarSaveSupport.flashKitQualified
    var pierSolarSPIPipelined = true
    var pierSolarSPIObserveWord: ((UInt16) -> Void)?
    private var serialSaveQualified = false
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
    private func readWord(_ offset: Int, cancellable: Bool = true) throws -> UInt16 {
        try address(offset); try transport.write(Data([0x42]), timeout: 2)
        let data = try transport.read(count: 2, timeout: 2, cancellable: cancellable)
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
        let data = try transport.read(count: busCount, timeout: 5, cancellable: cancellable && !checkingSaveWriting)
        return Data(data[skipped..<skipped+count])
    }
    public func reset() throws {
        guard !requiresReconnect else { throw FlashMDError.invalid("Reader state is uncertain. Unplug USB, then reconnect before scanning.") }
        if mappedCartridge { try bankedReader?.restore(); return }
        try word(0xF0, at: 0); try word(0, at: 0xA13000); try transport.write(Data([5,1]), timeout: 2) }
    public func readROM(offset: Int, count: Int) throws -> Data {
        guard !requiresReconnect else { throw FlashMDError.invalid("Reader state is uncertain. Unplug USB, then reconnect before scanning.") }
        guard !mapperUnavailable else { throw FlashMDError.invalid("This cartridge’s bank switching is not supported by this reader. ROM backup is unavailable.") }
        if let bankedReader { return try bankedReader.readROM(offset:offset,count:count) }
        try word(0, at: 0xA13000)
        return try readBytes(offset: offset, count: count)
    }
    public func readSRAM(layout: SRAMLayout, offset: Int, count: Int) throws -> Data {
        guard !mappedCartridge else { throw FlashMDError.invalid("SRAM access is not supported for this mapper.") }
        guard !requiresReconnect, offset >= 0, count >= 0, offset <= layout.windowBytes, count <= layout.windowBytes-offset else { throw FlashMDError.invalid("Invalid SRAM read range.") }
        let witnesses = [0,0x80000,0x100000,0x180000]
        try word(0,at:0xA13000)
        let original = try witnesses.map { try readBytes(offset:$0,count:64,cancellable:false) }
        let sampleCount = min(64,layout.windowBytes)
        func active(_ data: Data) -> Data {
            guard let lane = layout.lane else { return data }
            return Data(stride(from:lane,to:data.count,by:2).map { data[$0] })
        }
        var upper: [(Int,Data)] = []
        for position in [layout.base,layout.base+layout.windowBytes-sampleCount] {
            let first = active(try readBytes(offset:position,count:sampleCount,cancellable:false))
            if try active(readBytes(offset:position,count:sampleCount,cancellable:false)) == first { upper.append((position,first)) }
        }
        var result = Data(), failure: Error?
        do {
            try word(0xFFFF, at: 0xA13000)
            result = try readBytes(offset: layout.base+offset, count: count)
        } catch { failure = error }
        do {
            try word(0,at:0xA13000)
            guard try witnesses.map({ try readBytes(offset:$0,count:64,cancellable:false) }) == original else {
                throw FlashMDError.invalid("ROM access was not restored.")
            }
            for (position,expected) in upper {
                guard try active(readBytes(offset:position,count:sampleCount,cancellable:false)) == expected else { throw FlashMDError.invalid("Save mapping was not restored.") }
            }
        } catch {
            requiresReconnect = true; transport.close()
            throw FlashMDError.invalid("Reader state is uncertain. Unplug USB, then reconnect before scanning.")
        }
        if let failure { throw failure }
        return result
    }
    public func inspect(profile: CartridgeProfile) throws -> CartridgeSnapshot {
        try inspect(profile:profile,mapper:.automatic)
    }
    public func qualifySRAM(layout: SRAMLayout) throws -> SaveMemoryStatus {
        let status = try SaveMemoryProbe.qualify(self,layout:layout)
        qualifiedSaveLayout = status == .confirmed ? layout : nil
        saveWritingUnqualified = status != .confirmed
        programmingLimit = min(programmingLimit,layout.base)
        return status
    }
    public func checkSRAMWriting(layout: SRAMLayout, originalRaw: Data) throws {
        guard !requiresReconnect, !mappedCartridge, qualifiedGeometry?.supported == true,
              pendingSaveWriteCheck == layout, layout.base == 0x200000, layout.lane == 1,
              (64...65536).contains(layout.windowBytes), originalRaw.count == layout.windowBytes else {
            throw FlashMDError.invalid("This SRAM layout cannot be checked for writing.")
        }
        try Task.checkCancellation()
        let original = try layout.pack(originalRaw)
        let positions = [0,0x80000,0x100000,0x180000]
        let witnesses = try positions.map { try readROMForVerification(offset:$0,count:64) }
        checkingSaveWriting = true
        defer { checkingSaveWriting = false; pendingSaveWriteCheck = nil }
        do {
            try SRAMWriteProbe.check(original:original,read:{
                var raw = Data()
                for offset in stride(from:0,to:layout.windowBytes,by:32768) {
                    raw.append(try self.readSRAM(layout:layout,offset:offset,count:min(32768,layout.windowBytes-offset)))
                }
                return try layout.pack(raw)
            },writePrefix:{ bytes in
                guard bytes.count == 32 else { throw FlashMDError.invalid("Invalid write-check length.") }
                try self.word(0xFFFF,at:0xA13000)
                for (index,value) in bytes.enumerated() {
                    try self.byte(value,at:0x200001+index*2)
                }
            },verifyROM:{
                guard try positions.map({ try self.readROMForVerification(offset:$0,count:64) }) == witnesses else {
                    throw FlashMDError.invalid("ROM mapping changed during the SRAM write check.")
                }
            })
            qualifiedSaveLayout = layout
            saveWritingUnqualified = false
        } catch {
            // The connection cannot be reused after an inconclusive active check.
            qualifiedSaveLayout = nil; requiresReconnect = true; transport.close()
            throw error
        }
    }
    public func inspect(profile: CartridgeProfile, mapper selection: ROMMapper) throws -> CartridgeSnapshot {
        try bankedReader?.restore()
        bankedReader = nil; mappedCartridge = false; mapperUnavailable = false; qualifiedSaveLayout = nil; qualifiedGeometry = nil; programmingLimit = 0; pendingSaveWriteCheck = nil; saveWritingUnqualified = false; serialSaveQualified = false
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
            let size = mapper.scanLimit
            var qualified = false
            if mapper == .segaSSF2 || mapper == .pierSolar,
               let size, size > 0x400000, size <= 0x1000000 {
                let reader = BankedROMReader(mapper:mapper,size:size,
                    select:{ [unowned self] address, value in try self.byte(value,at:address) },
                    read:{ [unowned self] address, count in try self.readBytes(offset:address,count:count,cancellable:false) })
                bankedReader = reader
                do { qualified = try reader.qualify() }
                catch { requiresReconnect = true; mapperUnavailable = true; transport.close(); throw error }
            }
            mapperUnavailable = !qualified
            var serialReadFailed = false
            if qualified, detected == .pierSolar, pierSolarSaveEnabled {
                do { _ = try probePierSolarSave(); serialSaveQualified = true }
                catch {
                    if requiresReconnect || error is CancellationError || Task.isCancelled { throw error }
                    serialReadFailed = true
                }
            }
            let message: String
            if serialSaveQualified { message = "ROM and SPI save backup available. Writing is not supported." }
            else if serialReadFailed { message = "Save memory could not be read reliably. ROM backup is available." }
            else if qualified { message = "ROM bank switching verified. This mapper’s save memory cannot be backed up or written yet." }
            else if mapper == .linear { message = "Complete ROM unavailable. Select a known ROM mapper in Advanced Settings." }
            else { message = "This cartridge’s bank switching is not supported by this reader. ROM backup is unavailable." }
            return .init(title:metadata?.title ?? "Unknown cartridge",regions:metadata?.regions ?? [],
                romSize:metadata?.declaredROMBytes.map { .init(bytes:$0,source:.header) },
                flashCapacity:nil,rawSaveWindow:nil,metadata:metadata,serialSave:detected == .pierSolar ? .pierSolar : nil,identity:identity,
                fingerprint:hash(header),warning:message,profile:profile,rawHeader:Data(header[0x100..<0x200]),
                mapper:mapper,mapperSelection:selection,romAccess:qualified ? .banked : .unavailable,
                mappedROMBytes:size,mapperMessage:message,saveWriteSupported:false,saveStatus:serialSaveQualified ? .readOnly : detected == .pierSolar ? .unsupported : nil)
        }
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
        let layout = metadata?.saveWarning == nil ? (profile == .automatic ? (validHeader ? metadata?.saveLayout : nil) : profile.saveLayout) : nil
        let capacity: MemoryMeasurement?
        if profile == .automatic {
            // Programming keeps the declared save boundary; read-only scans can
            // inspect beyond it because SDK placeholder headers often understate ROM size.
            capacity = geometry.map { CartridgeConfiguration.inferredCapacity(geometry:$0,saveLayout:layout) }
            let assumption = layout != nil
                ? "ROM scans include the accessible chip range. Writing stays below the header's SRAM address."
                : "Automatic configuration assumes linear ROM access up to 4 MiB. A missing save declaration does not prove that the board has no SRAM. Adjust Advanced Settings if needed."
            warning = [warning, metadata?.saveWarning, assumption].compactMap { $0 }.joined(separator:" ")
        } else {
            capacity = geometry.flatMap { profile.usableCapacity(for:$0) } ?? profile.romCapacityLimit.map { .init(bytes:$0,source:.profile) }
        }
        try reset()
        guard try readBytes(offset:0,count:512) == header else {
            requiresReconnect = true; transport.close()
            throw FlashMDError.invalid("ROM access was not restored. Unplug USB, then reconnect before scanning.")
        }
        let saveStatus: SaveMemoryStatus = metadata?.saveWarning != nil ? .unsupported : try layout.map { try qualifySRAM(layout:$0) } ?? .none
        if saveStatus == .confirmed { qualifiedSaveLayout = layout }
        saveWritingUnqualified = layout != nil && saveStatus != .confirmed
        qualifiedGeometry = geometry
        programmingLimit = min(capacity?.bytes ?? 0,profile == .linearROMOnly ? 0x400000 : metadata?.saveLayout?.base ?? 0x400000)
        let snapshot = CartridgeSnapshot(title: title, regions: validHeader ? metadata?.regions ?? [] : [], romSize: validHeader ? metadata?.declaredROMBytes.map { .init(bytes: $0, source: .header) } : nil,
            flashCapacity: capacity, rawSaveWindow: layout.map { .init(bytes: $0.windowBytes, source: profile == .automatic ? .header : .profile) },
            metadata: validHeader ? metadata : nil, geometry: geometry, saveLayout: layout,
            identity: identity, fingerprint: hash(header), warning: warning, profile: profile, rawHeader:Data(header[0x100..<0x200]),mapperSelection:selection,linearROMReadBytes:profile == .automatic ? min(geometry?.capacity ?? 0x400000,0x400000) : nil,saveStatus:saveStatus)
        if snapshot.canCheckSaveWriting { pendingSaveWriteCheck = layout }
        return snapshot
    }

    private func withPierSolarSPI<T>(_ work: (PierSolarSPIReader) throws -> T) throws -> T {
        guard mappedCartridge, !mapperUnavailable, !requiresReconnect, bankedReader?.mapper == .pierSolar,
              let metadata = try? ROMMetadata.parse(readBytes(offset:0,count:512,cancellable:false)),
              ROMMapper.detect(metadata) == .pierSolar,
              pierSolarSaveEnabled else {
            throw FlashMDError.invalid("SPI save reading is awaiting validation for this reader.")
        }
        let offsets = [0,0x80000,0x280000,0x380000]
        let witnesses: [Data]
        do {
            try bankedReader?.restore()
            witnesses = try offsets.map { try readBytes(offset:$0,count:64,cancellable:false) }
        } catch {
            requiresReconnect = true; transport.close()
            throw FlashMDError.invalid("ROM mapping could not be checked. Unplug USB before continuing.")
        }
        let spi = PierSolarSPIReader(setPins:{ [unowned self] value in
            try self.byte(value,at:PierSolarSPIReader.controlAddress)
        },readPin:{ [unowned self] in
            let word = try self.readWord(PierSolarSPIReader.dataAddress & ~1,cancellable:false)
            self.pierSolarSPIObserveWord?(word)
            return UInt8(word & 1)
        },clockReadBytes:pierSolarSPIPipelined ? { [unowned self] count in
            try self.readPierSolarSPIBytes(count)
        } : nil)
        let result: Result<T,any Error>
        do { result = .success(try work(spi)) } catch { result = .failure(error) }
        do {
            try spi.deselect(); try bankedReader?.restore()
            guard try offsets.map({ try readBytes(offset:$0,count:64,cancellable:false) }) == witnesses else {
                throw FlashMDError.invalid("ROM mapping changed after SPI access.")
            }
        } catch {
            requiresReconnect = true; transport.close()
            throw FlashMDError.invalid("SPI access did not stop cleanly. Unplug USB before continuing.")
        }
        return try result.get()
    }
    func probePierSolarSave() throws -> PierSolarSaveProbe {
        try withPierSolarSPI { try $0.probe() }
    }
    func validatePierSolarHeader(_ expected: Data) throws {
        guard expected.count == 512, ROMMapper.detect(try ROMMetadata.parse(expected)) == .pierSolar,
              try readBytes(offset:0,count:512,cancellable:false) == expected,
              try readBytes(offset:0,count:512,cancellable:false) == expected else {
            throw FlashMDError.invalid("The inserted cartridge does not match the Pier Solar reference. No SPI access was attempted.")
        }
    }
    private func readPierSolarSPIBytes(_ count: Int) throws -> Data {
        guard (1...4).contains(count) else { throw FlashMDError.invalid("Invalid SPI transfer size.") }
        // At most 544 command bytes produce just 64 response bytes.
        // The cartridge has separate control (09) and data (0B) registers.
        // This bounded request avoids long command queues and USB deadlocks.
        var commands = Data()
        for _ in 0..<count*8 {
            for address in [PierSolarSPIReader.controlAddress,PierSolarSPIReader.dataAddress] {
                let word = address >> 1
                commands.append(contentsOf:[0,UInt8(truncatingIfNeeded:word >> 16),0,UInt8(truncatingIfNeeded:word >> 8),0,UInt8(truncatingIfNeeded:word)])
                if address == PierSolarSPIReader.controlAddress { commands.append(contentsOf:[0x53,4,0x53,6]) }
                else { commands.append(0x42) }
            }
        }
        try transport.write(commands,timeout:2)
        let samples = try transport.read(count:count*16,timeout:2,cancellable:false)
        guard samples.count == count*16 else { throw FlashMDError.invalid("Incomplete SPI bit samples.") }
        var result = Data()
        for byte in 0..<count {
            var value: UInt8 = 0
            for index in stride(from:byte*16+1,to:(byte+1)*16,by:2) {
                value = (value << 1) | (samples[index] & 1)
            }
            result.append(value)
        }
        return result
    }

    public func readSerialSave(offset: Int, count: Int) throws -> Data {
        guard serialSaveQualified else { throw FlashMDError.invalid("SPI save reading has not been confirmed. Scan again.") }
        return try withPierSolarSPI { spi in
            let status = try spi.readStatus()
            let data = try spi.read(offset:offset,count:count)
            guard try spi.readStatus() == status else { throw FlashMDError.invalid("SPI status changed. No save file was created.") }
            return data
        }
    }
    public func erase(sector: FlashSector) throws {
        guard !mappedCartridge else { throw FlashMDError.invalid("Writing is unavailable for banked cartridges.") }
        guard !requiresReconnect, !saveWritingUnqualified, let geometry = qualifiedGeometry, geometry.supported,
              geometry.sectors.contains(sector), sector.offset >= 0, sector.bytes <= programmingLimit-sector.offset else {
            throw FlashMDError.invalid("Flash erasure exceeds the qualified ROM area. Scan again.")
        }
        try word(0, at: 0xA13000); try transport.write(Data([5,0]), timeout: 2)
        try word(0xAA, at: 0xAAA); try word(0x55, at: 0x554); try word(0x80, at: 0xAAA)
        try word(0xAA, at: 0xAAA); try word(0x55, at: 0x554); try word(0x30, at: sector.offset)
        try transport.write(Data([4,0x42]), timeout: 2)
        _ = try transport.read(count: 2, timeout: 120, cancellable: false)
    }
    public func configureROMWriting(_ cartridge: CartridgeSnapshot) throws {
        guard let geometry = qualifiedGeometry, cartridge.geometry == geometry,
              cartridge.identity == identity, cartridge.canWrite, !mappedCartridge,
              cartridge.romWriteLimit <= min(geometry.capacity,0x400000) else { return }
        programmingLimit = cartridge.romWriteLimit
        if cartridge.hasExplicitROMOnlyConfiguration {
            qualifiedSaveLayout = nil; pendingSaveWriteCheck = nil; saveWritingUnqualified = false
        }
    }
    public func program(offset: Int, data: Data) throws {
        guard !mappedCartridge else { throw FlashMDError.invalid("Writing is unavailable for banked cartridges.") }
        guard !requiresReconnect, !saveWritingUnqualified, qualifiedGeometry?.supported == true, offset >= 0, offset.isMultiple(of:2),
              data.count > 0, data.count <= 4096, data.count.isMultiple(of: 2), offset <= programmingLimit,
              data.count <= programmingLimit-offset else { throw FlashMDError.invalid("Programming exceeds the qualified ROM area. Scan again.") }
        if qualifiedGeometry?.usesUnlockBypass == false {
            // Ordinary word programming avoids assuming unlock-bypass support.
            var packet = Data()
            func appendWord(_ value: UInt16, at byteAddress: Int) {
                let address = byteAddress >> 1
                packet.append(contentsOf:[0,UInt8(truncatingIfNeeded:address >> 16),0,UInt8(truncatingIfNeeded:address >> 8),0,UInt8(truncatingIfNeeded:address),
                                          0x43,UInt8(truncatingIfNeeded:value >> 8),UInt8(truncatingIfNeeded:value)])
            }
            for index in stride(from:0,to:data.count,by:2) {
                let value = UInt16(data[index]) << 8 | UInt16(data[index+1])
                if value == 0xFFFF { continue }
                appendWord(0xAA,at:0xAAA); appendWord(0x55,at:0x554)
                appendWord(0xA0,at:0xAAA); appendWord(value,at:offset+index)
                packet.append(4) // Wait for the chip to stop toggling.
            }
            if !packet.isEmpty {
                try transport.write(packet,timeout:30)
                try transport.write(Data([0x42]),timeout:2)
                _ = try transport.read(count:2,timeout:30,cancellable:false)
            }
            return
        }
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
        guard !requiresReconnect, let qualified = qualifiedSaveLayout, qualified.base == layout.base,
              qualified.lane == layout.lane, layout.windowBytes <= qualified.windowBytes else { throw FlashMDError.invalid("SRAM writing requires confirmed save memory. Scan again.") }
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
