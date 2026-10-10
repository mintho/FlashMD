import Foundation

/// USB command layouts independently implemented from X-death25/MD_Dumper's public
/// md_dumper_main.h, md_dumper_read.h and md_dumper_write.h.
/// Streaming is opt-in and restricted to the hardware/firmware tested on real cartridges.
public final class MDDumperDevice: CartridgeDevice, @unchecked Sendable {
    private let transport: any ByteTransport
    public let identity: String
    public let firmwareMajor: UInt8
    public let firmwareMinor: UInt8
    public let board: UInt8
    public private(set) var streamingEnabled: Bool
    public var supportsROMStreaming: Bool { firmwareMajor == 2 && firmwareMinor == 0 && board == 3 }
    public var preferredROMReadBytes: Int { streamingEnabled ? 0x80000 : 32768 }
    public var requiresROMBackupVerification: Bool { streamingEnabled }

    // Called by the controller only between operations. No USB commands needed.
    public func setROMStreaming(_ enabled: Bool) {
        streamingEnabled = enabled && supportsROMStreaming
        bankedReader?.transferBytes = preferredROMReadBytes
    }
    private var verifyingROM = false
    private var requiresPowerCycle = false
    private let reconnectMessage = "The reader did not stop cleanly. Turn it off and reconnect USB before continuing."
    private var bankedReader: BankedROMReader?
    private var ssf2SaveLayout: SRAMLayout?
    private var ssf2SaveProbe: Int?
    private var linearSaveLayout: SRAMLayout?
    private var readLimit = 0x400000
    private var physicalReadLimit = 0x400000
    private var unavailable = false
    private var unavailableMessage: String?
    private var flash: MDDumperFlash?
    private var preparedHeader: String?
    var pierSolarSaveEnabled = PierSolarSaveSupport.mdDumperQualified
    var pierSolarSPIObserveWord: ((UInt16) -> Void)?
    private var serialSaveQualified = false
    private var algorithmSelected = false
    public init(transport: any ByteTransport, location: String, streaming: Bool = false) throws {
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
            streamingEnabled = streaming && reply[20] == 2 && reply[21] == 0 && reply[24] == 3
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
    private func send(_ packet: Data) throws {
        guard !requiresPowerCycle else { throw FlashMDError.invalid(reconnectMessage) }
        try transport.write(packet,timeout:5)
    }
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
    private func readBus(offset: Int, count: Int, cancellable: Bool = false) throws -> Data {
        guard offset >= 0, count >= 0, offset <= 0x400000, count <= 0x400000-offset else {
            throw FlashMDError.invalid("Invalid MD Dumper ROM range.")
        }
        var output = Data()
        while output.count < count {
            if cancellable { try Task.checkCancellation() }
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
    private func readSSF2Save(layout: SRAMLayout, offset: Int, count: Int) throws -> Data {
        try Task.checkCancellation()
        if count == 0 { return Data() }
        // Use the same bounded bus reads qualified on firmware 2.0 / board 3.
        // 0x12 changes save-control signals itself and is not used for this mapper.
        try bankedReader?.restore()
        var witnesses = [0, 0x200000, 0x280000, 0x300000, 0x380000]
        if let probe = ssf2SaveProbe { witnesses.append(probe) }
        let original = try witnesses.map { try readBus(offset:$0,count:64) }
        var output = Data(), failure: Error?
        do {
            // Bit 0 maps SRAM; bit 1 protects it against writes. Never use 0x01 here.
            try selectBank(address:0xA130F1,page:0x03)
            try Task.checkCancellation()
            if let probe = ssf2SaveProbe {
                let selected = try readBus(offset:probe,count:64)
                let previous = original[original.count-1]
                guard stride(from:1,to:64,by:2).contains(where:{ selected[$0] != previous[$0] }) else {
                    throw FlashMDError.invalid("SRAM could not be selected. Scan again.")
                }
            }
            output = try readBus(offset:layout.base+offset,count:count,cancellable:true)
        } catch { failure = error }
        // Cleanup ignores task cancellation. Verify all affected ROM windows before
        // returning data or propagating a cancelled/failed read.
        do {
            try selectBank(address:0xA130F1,page:0)
            let restored = try witnesses.map { try readBus(offset:$0,count:64) }
            guard restored == original else { throw FlashMDError.invalid("ROM access was not restored.") }
        } catch {
            requiresPowerCycle = true; transport.close()
            throw FlashMDError.invalid(reconnectMessage)
        }
        if let failure { throw failure }
        try Task.checkCancellation()
        return output
    }
    private func readTransfer(offset: Int, count: Int) throws -> Data {
        if !streamingEnabled || verifyingROM || count < 32768 { return try readBus(offset:offset,count:count,cancellable:true) }
        // Preserve three independent fixed-region samples before starting. No mapper
        // changes or save commands are allowed until the stream has been stopped.
        let samples = [0x100,0x2F000,0x1F8000]
        let expected = try samples.map { try readBus(offset:$0,count:64) }
        let base = offset & ~63, skipped = offset - base
        let length = ((skipped + count + 63) / 64) * 64
        var output = Data(), failure: Error?
        do {
            var command = packet(0x11,address:base); command[4] = 1
            try send(command)
            while output.count < length {
                try Task.checkCancellation()
                let requested = min(32768,length-output.count)
                let block = try transport.read(count:requested,timeout:5,cancellable:false)
                guard !block.isEmpty, block.count <= requested, block.count.isMultiple(of:64) else {
                    throw FlashMDError.invalid("Incomplete streamed ROM read.")
                }
                output.append(block)
            }
        } catch { failure = error }
        // A host timeout/cancellation does not stop firmware streaming. Send a
        // bounded read, discard queued replies, then prove fresh synchronization.
        do {
            try send(packet(0x11,address:0x100))
            var settled = false
            for _ in 0..<16 {
                do { _ = try transport.read(count:64,timeout:0.1,cancellable:false) }
                catch FlashMDError.timeout { settled = true; break }
            }
            guard settled else { throw FlashMDError.timeout }
            let actual = try samples.map { try readBus(offset:$0,count:64) }
            guard actual == expected else { throw FlashMDError.invalid("ROM read synchronization failed.") }
        } catch {
            // Prevent further commands on an uncertain USB stream, including bank
            // restoration. Physical power cycling restores the volatile mapper.
            requiresPowerCycle = true; transport.close()
            throw FlashMDError.invalid(reconnectMessage)
        }
        if let failure { throw failure }
        return Data(output[skipped..<skipped+count])
    }
    public func reset() throws {
        guard !requiresPowerCycle else { throw FlashMDError.invalid(reconnectMessage) }
        try bankedReader?.restore()
        algorithmSelected = false
    }
    public func inspect(profile: CartridgeProfile) throws -> CartridgeSnapshot {
        try inspect(profile:profile,mapper:.automatic)
    }
    public func qualifySRAM(layout: SRAMLayout) throws -> SaveMemoryStatus {
        guard bankedReader == nil, firmwareMajor == 2, firmwareMinor == 0, board == 3, layout.lane == 1 else { return .declared }
        let status = try SaveMemoryProbe.qualify(self,layout:layout)
        linearSaveLayout = status == .confirmed ? layout : nil
        return status
    }
    public func inspect(profile: CartridgeProfile, mapper selection: ROMMapper) throws -> CartridgeSnapshot {
        try reset(); bankedReader = nil; ssf2SaveLayout = nil; ssf2SaveProbe = nil; linearSaveLayout = nil; unavailable = false; unavailableMessage = nil; serialSaveQualified = false
        let header = try readBus(offset:0,count:512)
        if preparedHeader != hash(header) { flash = nil; preparedHeader = nil }
        let valid = Data(header[0x100..<0x104]) == Data("SEGA".utf8)
        let metadata = valid ? try? ROMMetadata.parse(header) : nil
        let detected = ROMMapper.detect(metadata)
        guard detected == .linear || selection == .automatic || selection == detected else {
            throw FlashMDError.invalid("This cartridge uses \(detected.displayName). Select Automatic or \(detected.displayName).")
        }
        let mapper = selection == .automatic ? detected : selection
        if mapper != .linear || (metadata?.declaredROMBytes ?? 0) > 0x400000 {
            flash = nil; preparedHeader = nil
            let size = mapper.scanLimit
            var qualified = false
            // SSF2 register F9 is documented by the public client. Pier Solar's
            // ROM-only register 03 was qualified on firmware 2.0 / board 3.
            // SPI access below is separately gated and qualified.
            let qualifiedPierFirmware = firmwareMajor == 2 && firmwareMinor == 0 && board == 3
            if (mapper == .segaSSF2 || mapper == .pierSolar && qualifiedPierFirmware), let size, size > 0x400000, size <= 0x1000000 {
                let pier = mapper == .pierSolar
                let reader = BankedROMReader(mapper:mapper,size:size,register:pier ? 0xA13003 : 0xA130F9,window:pier ? 0x280000 : 0x200000,originalPage:pier ? 0 : 4,
                    select:{ [unowned self] address, page in try self.selectBank(address:address,page:page) },
                    read:{ [unowned self] offset, count in try self.readBus(offset:offset,count:count) },
                    transferBytes:preferredROMReadBytes,
                    readTransfer:{ [unowned self] offset, count in try self.readTransfer(offset:offset,count:count) })
                bankedReader = reader
                do { qualified = try reader.qualify() }
                catch { requiresPowerCycle = true; unavailable = true; transport.close(); throw error }
            }
            unavailable = !qualified; readLimit = size ?? 0
            var serialReadFailed = false
            if qualified, detected == .pierSolar, qualifiedPierFirmware,
               pierSolarSaveEnabled {
                do { _ = try probePierSolarSave(); serialSaveQualified = true }
                catch {
                    if requiresPowerCycle || error is CancellationError || Task.isCancelled { throw error }
                    serialReadFailed = true
                }
            }
            // Qualify the protocol and declared layout, not individual game titles.
            // A changed active lane proves that F1 selected SRAM rather than ROM.
            let declaredSave = metadata?.saveLayout
            var saveMessage: String?
            if qualified, mapper == .segaSSF2, firmwareMajor == 2, firmwareMinor == 0, board == 3,
               let layout = declaredSave, layout.lane == 1, layout.base == 0x200000 {
                let original = try readBus(offset:layout.base,count:layout.windowBytes)
                let save = try readSSF2Save(layout:layout,offset:0,count:layout.windowBytes)
                if !SaveMemoryProbe.isBlank(try layout.pack(save)),
                   let changed = stride(from:1,to:layout.windowBytes,by:2).first(where:{ save[$0] != original[$0] }) {
                    ssf2SaveLayout = layout
                    ssf2SaveProbe = (layout.base + changed) & ~63
                }
                else { saveMessage = "SRAM could not be identified. ROM backup is available." }
            }
            let message: String
            if serialSaveQualified { message = "ROM and SPI save backup available. Writing is not supported." }
            else if serialReadFailed { message = "Save memory could not be read reliably. ROM backup is available." }
            else if qualified, detected == .pierSolar { message = "This reader cannot back up Pier Solar saves. Use a FlashKit. ROM backup is available." }
            else if qualified, ssf2SaveLayout != nil { message = "ROM and SRAM backup available. Writing is not supported." }
            else if qualified { message = saveMessage ?? (declaredSave != nil || metadata?.saveWarning != nil ? "ROM backup available. This cartridge’s save memory is not supported." : "ROM bank switching verified.") }
            else if mapper == .linear { message = "Choose a ROM mapper in Advanced Settings to back up this cartridge." }
            else { message = "This cartridge’s bank switching is not supported by this reader. ROM backup is unavailable." }
            unavailableMessage = qualified ? nil : message
            let saveStatus: SaveMemoryStatus
            if serialSaveQualified { saveStatus = .readOnly }
            else if ssf2SaveLayout != nil { saveStatus = .confirmed }
            else if detected == .pierSolar || metadata?.saveWarning != nil { saveStatus = .unsupported }
            else if declaredSave == nil { saveStatus = .none }
            else { saveStatus = .unconfirmed }
            return .init(title:metadata?.title ?? "Unknown cartridge",regions:metadata?.regions ?? [],
                romSize:metadata?.declaredROMBytes.map { .init(bytes:$0,source:.header) },flashCapacity:nil,
                rawSaveWindow:ssf2SaveLayout.map { .init(bytes:$0.windowBytes,source:.header) },
                metadata:metadata,saveLayout:ssf2SaveLayout,serialSave:detected == .pierSolar ? .pierSolar : nil,identity:identity,fingerprint:hash(header),warning:message,profile:profile,
                mapper:mapper,mapperSelection:selection,romAccess:qualified ? .banked : .unavailable,
                mappedROMBytes:size,mapperMessage:message,readerKind:.mdDumper,saveWriteSupported:false,saveStatus:saveStatus)
        }
        // Never query flash IDs during scan/backup. A separately prepared chip
        // is accepted only after reconnecting and checking the pre-query ROM.
        guard valid || flash != nil else {
            unavailable = true; readLimit = 0; physicalReadLimit = 0x400000
            let message = "Game data could not be read. Turn the reader off, unplug USB, then reconnect with the cartridge still inserted."
            unavailableMessage = message
            return .init(title:"Unreadable cartridge",regions:[],romSize:nil,flashCapacity:nil,rawSaveWindow:nil,
                identity:identity,fingerprint:hash(header),warning:message,profile:profile,
                rawHeader:Data(header[0x100..<0x200]),mapperSelection:selection,romAccess:.unavailable,
                mapperMessage:message,readerKind:.mdDumper,saveWriteSupported:false)
        }
        // Published SRAM commands expose the odd lane only, not a two-lane bus dump.
        let declared = metadata?.saveWarning == nil ? (profile == .automatic ? metadata?.saveLayout : profile.saveLayout) : nil
        let layout = declared?.lane == 1 ? declared : nil
        physicalReadLimit = flash?.capacity ?? 0x400000
        readLimit = min(profile.romCapacityLimit ?? physicalReadLimit,physicalReadLimit,layout?.base ?? 0x400000)
        if let flash, flash.capacity != readLimit { self.flash = nil; preparedHeader = nil }
        let saveStatus: SaveMemoryStatus
        if let layout, firmwareMajor == 2, firmwareMinor == 0, board == 3 {
            saveStatus = try qualifySRAM(layout:layout)
        } else { saveStatus = metadata?.saveWarning != nil ? .unsupported : declared != nil ? .declared : .none }
        linearSaveLayout = saveStatus == .confirmed ? layout : nil
        let warning = declared != nil && layout == nil ? "This reader supports odd-lane SRAM only. ROM backup is available." :
            flash == nil ? "Prepare ROM writing to identify the flash chip." : "ROM writing available. The whole ROM chip will be erased."
        return .init(title:metadata?.title ?? "Blank cartridge",regions:metadata?.regions ?? [],
            romSize:metadata?.declaredROMBytes.map { .init(bytes:$0,source:.header) },
            flashCapacity:.init(bytes:readLimit,source:flash == nil ? .estimated : .hardware),
            rawSaveWindow:layout.map { .init(bytes:$0.windowBytes,source:.header) },metadata:metadata,
            geometry:flash?.geometry,saveLayout:layout,identity:identity,fingerprint:hash(header),warning:warning,
            profile:profile,rawHeader:Data(header[0x100..<0x200]),mapperSelection:selection,readerKind:.mdDumper,saveWriteSupported:linearSaveLayout?.activeBytes.isMultiple(of:32) == true,
            linearROMReadBytes:profile == .automatic ? physicalReadLimit : nil,saveStatus:saveStatus)
    }
    private func withPierSolarSPI<T>(_ work: (PierSolarSPIReader) throws -> T) throws -> T {
        guard !unavailable, !requiresPowerCycle, bankedReader?.mapper == .pierSolar,
              firmwareMajor == 2, firmwareMinor == 0, board == 3,
              let metadata = try? ROMMetadata.parse(readBus(offset:0,count:512)),
              ROMMapper.detect(metadata) == .pierSolar,
              pierSolarSaveEnabled else {
            throw FlashMDError.invalid("SPI save reading is awaiting validation for this reader.")
        }
        let offsets = [0,0x80000,0x280000,0x380000]
        let witnesses: [Data]
        do {
            try bankedReader?.restore()
            witnesses = try offsets.map { try readBus(offset:$0,count:64) }
        } catch {
            requiresPowerCycle = true; transport.close()
            throw FlashMDError.invalid("ROM mapping could not be checked. Turn the reader off and unplug USB before continuing.")
        }
        let spi = PierSolarSPIReader(setPins:{ [unowned self] value in
            var command = self.packet(0x20,address:PierSolarSPIReader.controlAddress)
            command[5] = value
            try self.send(command)
        },readPin:{ [unowned self] in
            // Diagnostic-only until TIME reads are proved on the actual firmware.
            // Do not widen ordinary ROM reads or enable streaming at this address.
            try self.send(self.packet(0x11,address:PierSolarSPIReader.dataAddress))
            let reply = try self.reply()
            self.pierSolarSPIObserveWord?(UInt16(reply[0]) << 8 | UInt16(reply[1]))
            return reply[1] & 1
        })
        let result: Result<T,any Error>
        do { result = .success(try work(spi)) } catch { result = .failure(error) }
        do {
            try spi.deselect(); try bankedReader?.restore()
            guard try offsets.map({ try readBus(offset:$0,count:64) }) == witnesses else {
                throw FlashMDError.invalid("ROM mapping changed after SPI access.")
            }
        } catch {
            requiresPowerCycle = true; transport.close()
            throw FlashMDError.invalid("SPI access did not stop cleanly. Turn the reader off and unplug USB before continuing.")
        }
        return try result.get()
    }
    func probePierSolarSave() throws -> PierSolarSaveProbe {
        try withPierSolarSPI { try $0.probe() }
    }
    func validatePierSolarHeader(_ expected: Data) throws {
        guard expected.count == 512, ROMMapper.detect(try ROMMetadata.parse(expected)) == .pierSolar,
              try readBus(offset:0,count:512) == expected,
              try readBus(offset:0,count:512) == expected else {
            throw FlashMDError.invalid("The inserted cartridge does not match the Pier Solar reference. No SPI access was attempted.")
        }
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

    /// Explicit write preparation only. Identification may leave the chip in
    /// autoselect mode; close immediately and never attempt a speculative reset.
    func prepareROMWriting(cartridge: CartridgeSnapshot, progress: ProgressHandler) throws -> MDDumperWritePreparation {
        guard firmwareMajor == 2, firmwareMinor == 0, board == 3,
              cartridge.readerKind == .mdDumper, cartridge.mapper == .linear,
              bankedReader == nil, !requiresPowerCycle else {
            throw FlashMDError.invalid("ROM writing preparation requires a linear cartridge and MD Dumper firmware 2.0 / board 3.")
        }
        let header = try readBus(offset:0,count:512)
        guard hash(header) == cartridge.fingerprint else { throw FlashMDError.invalid("The cartridge changed. Scan again.") }
        let limit = min(cartridge.flashCapacity?.bytes ?? 0x400000,cartridge.saveLayout?.base ?? 0x400000,cartridge.metadata?.saveLayout?.base ?? 0x400000)
        let digest = try preparationDigest(bytes:limit,progress:progress)
        try Task.checkCancellation()
        // From this point even a timeout requires a physical restart.
        requiresPowerCycle = true
        defer { transport.close() }
        do {
            try transport.write(packet(0x18),timeout:5)
            let identification = try reply()
            guard let chip = MDDumperFlash.lookup(manufacturer:identification[1],chip:identification[3]),
                  chip.capacity <= limit else {
                throw FlashMDError.invalid("This flash chip is not supported for ROM writing.")
            }
            return .init(identity:identity,chip:chip,bytes:limit,digest:digest,header:hash(header))
        } catch {
            throw FlashMDError.invalid("\(error.localizedDescription) Leave the cartridge inserted, turn the reader off, unplug USB, then reconnect before scanning.")
        }
    }

    func acceptROMWritingPreparation(_ preparation: MDDumperWritePreparation, cartridge: CartridgeSnapshot) throws {
        guard identity == preparation.identity, cartridge.mapper == .linear, bankedReader == nil,
              cartridge.fingerprint == preparation.header,
              preparation.chip.capacity <= (cartridge.saveLayout?.base ?? 0x400000),
              preparation.chip.capacity <= (cartridge.metadata?.saveLayout?.base ?? 0x400000),
              preparation.chip.capacity <= (cartridge.flashCapacity?.bytes ?? 0x400000) else {
            throw FlashMDError.invalid("The cartridge or configuration changed. Prepare ROM writing again.")
        }
        guard try preparationDigest(bytes:preparation.bytes,progress:{ _ in }) == preparation.digest else {
            throw FlashMDError.invalid("ROM data changed or the chip is still in identification mode. Restart the reader with the same cartridge inserted, then prepare ROM writing again.")
        }
        flash = preparation.chip; preparedHeader = preparation.header
    }

    private func preparationDigest(bytes: Int, progress: ProgressHandler) throws -> String {
        guard (512...0x400000).contains(bytes) else { throw FlashMDError.invalid("Unsupported ROM preparation range.") }
        var contents = Data()
        for offset in stride(from:0,to:bytes,by:32768) {
            try Task.checkCancellation()
            let count = min(32768,bytes-offset)
            let first = try readBus(offset:offset,count:count)
            guard try readBus(offset:offset,count:count) == first else { throw FlashMDError.mismatch(offset) }
            contents.append(first)
            progress(.init(.inspecting,offset+count,bytes,detail:"Checking cartridge before enabling ROM writing"))
        }
        return hash(contents)
    }
    public func readROM(offset: Int, count: Int) throws -> Data {
        guard !requiresPowerCycle else { throw FlashMDError.invalid(reconnectMessage) }
        guard !unavailable else { throw FlashMDError.invalid(unavailableMessage ?? "Game data could not be read. Scan again.") }
        if let bankedReader { return try bankedReader.readROM(offset:offset,count:count) }
        guard offset >= 0, count >= 0, offset <= physicalReadLimit, count <= physicalReadLimit-offset else { throw FlashMDError.invalid("ROM read exceeds cartridge capacity.") }
        try Task.checkCancellation()
        return try readTransfer(offset:offset,count:count)
    }
    public func readROMForVerification(offset: Int, count: Int) throws -> Data {
        verifyingROM = true
        defer { verifyingROM = false }
        return try readROM(offset:offset,count:count)
    }
    public func readSRAM(layout: SRAMLayout, offset: Int, count: Int) throws -> Data {
        guard !unavailable, layout.lane == 1,
              offset >= 0, count >= 0, offset <= layout.windowBytes, count <= layout.windowBytes-offset else {
            throw FlashMDError.invalid("This reader supports odd-lane SRAM only.")
        }
        if bankedReader != nil {
            guard layout == ssf2SaveLayout else { throw FlashMDError.invalid("SRAM backup is unavailable for this cartridge. Scan again.") }
            return try readSSF2Save(layout:layout,offset:offset,count:count)
        }
        // Assemble the same raw representation used elsewhere; unused even bytes
        // are zero-filled, matching the official client's .srm export.
        guard firmwareMajor == 2, firmwareMinor == 0, board == 3, !requiresPowerCycle else {
            throw FlashMDError.invalid("SRAM reading is not qualified for this reader firmware.")
        }
        return try withLinearSaveAccess(layout:layout) {
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
    }
    private func withLinearSaveAccess<T>(layout: SRAMLayout, _ work: () throws -> T) throws -> T {
        let witnesses = [0,0x80000,0x100000,0x180000]
        let original = try witnesses.map { try readBus(offset:$0,count:64) }
        let count = min(64,layout.windowBytes)
        func active(_ data: Data) -> Data { Data(stride(from:1,to:data.count,by:2).map { data[$0] }) }
        let upperOffsets = [layout.base,layout.base+layout.windowBytes-count]
        var upper: [(Int,Data)] = []
        for offset in upperOffsets {
            let first = active(try readBus(offset:offset,count:count))
            if try active(readBus(offset:offset,count:count)) == first { upper.append((offset,first)) }
        }
        let result: Result<T,any Error>
        do { result = .success(try work()) } catch { result = .failure(error) }
        do {
            // Restore and check ROM even after a write timeout or task cancellation.
            // Unused even SRAM lanes are excluded from the witnesses.
            try selectBank(address:0xA130F1,page:0)
            guard try witnesses.map({ try readBus(offset:$0,count:64) }) == original else { throw FlashMDError.invalid("ROM access was not restored.") }
            for (offset,expected) in upper {
                guard try active(readBus(offset:offset,count:count)) == expected else { throw FlashMDError.invalid("Save mapping was not restored.") }
            }
        } catch {
            requiresPowerCycle = true; transport.close()
            throw FlashMDError.invalid(reconnectMessage)
        }
        return try result.get()
    }
    public func restore(layout: SRAMLayout, raw: Data) throws {
        guard bankedReader == nil, !unavailable, !requiresPowerCycle, let qualified = linearSaveLayout,
              qualified.base == layout.base, qualified.lane == layout.lane, layout.windowBytes <= qualified.windowBytes,
              layout.lane == 1, raw.count == layout.windowBytes,
              layout.activeBytes.isMultiple(of:32) else { throw FlashMDError.invalid("Unsupported SRAM write layout for this reader.") }
        // Write only requested active bytes. Never issue the client's 0xBB blanket SRAM erase.
        let packed = try layout.pack(raw)
        try withLinearSaveAccess(layout:layout) {
            for offset in stride(from:0,to:packed.count,by:32) {
                try Task.checkCancellation()
                var command = packet(0x13,address:layout.base+offset*2); command[7] = 0xCC
                command.replaceSubrange(32..<64,with:packed[offset..<offset+32])
                try send(command); try waitStatus(index:6,value:0xAA,timeout:10)
            }
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
        try MDDumperROMProgramming.write(offset:offset,data:data,transport:transport)
    }
}

/// The firmware acknowledges each programming packet, not just algorithm selection.
/// Consume the reply before another command so it cannot become ROM readback data.
enum MDDumperROMProgramming {
    static func write(offset: Int, data: Data, transport: any ByteTransport) throws {
        guard offset >= 0, offset.isMultiple(of:2), !data.isEmpty, data.count.isMultiple(of:2),
              offset <= 0x400000, data.count <= 0x400000-offset else {
            throw FlashMDError.invalid("Unsupported MD Dumper flash write.")
        }
        for start in stride(from:0,to:data.count,by:54) {
            try Task.checkCancellation()
            let length = min(54,data.count-start), word = (offset+start)/2
            var command = Data(repeating:0,count:64)
            command[0] = 0x14
            command[1] = UInt8(truncatingIfNeeded:word)
            command[2] = UInt8(truncatingIfNeeded:word >> 8)
            command[3] = UInt8(truncatingIfNeeded:word >> 16)
            command[4] = UInt8(length)
            command.replaceSubrange(5..<5+length,with:data[start..<start+length])
            try transport.write(command,timeout:5)
            let acknowledgement = try transport.read(count:64,timeout:10,cancellable:false)
            guard acknowledgement.count == 64, acknowledgement[6] == 0xDD else {
                throw FlashMDError.invalid("MD Dumper did not confirm the ROM write. Reconnect the reader before trying again.")
            }
        }
    }
}

struct MDDumperWritePreparation: Sendable {
    let identity: String
    let chip: MDDumperFlash
    let bytes: Int
    let digest: String
    let header: String
}

struct MDDumperFlash: Sendable {
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
