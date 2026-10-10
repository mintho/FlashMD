import Foundation

/// Content evidence, not proof of a game's required size. Never trims a backup by itself.
public struct ROMContentAnalysis: Sendable, Codable, Equatable {
    public let scannedBytes: Int
    public let headerBytes: Int?
    public let lastNonErasedByte: Int?
    public let trailingErasedBytes: Int
    public let nonErasedBytesBeyondHeader: Int?
    public let possibleMirrorBytes: Int?
    public private(set) var suggestedBytes: Int?
    public let sha256: String
    public var requestedScanBytes: Int? = nil
    public var excludedROMStart: Int? = nil
    public var limitation: String? = nil
    public var identitySHA256: String? = nil
    public var possibleSaveMirrorStart: Int? = nil
    public var possibleSaveMirrorBytes: Int? = nil
    public var hasUncertainRange: Bool { excludedROMStart != nil }

    public var explanation: String {
        if let limitation { return limitation }
        guard suggestedBytes != nil else { return "Only FF bytes were read. No game size can be suggested." }
        if possibleMirrorBytes != nil {
            return "Repeated ROM blocks were found. They may be intentional or mirrored by the board; the suggestion keeps them."
        }
        if let count = nonErasedBytesBeyondHeader, count > 0 {
            return "Data exists beyond the header's ROM size. It may belong to this game or an earlier flash; the suggestion keeps it."
        }
        if trailingErasedBytes > 0 {
            return "The end of the ROM contains FF bytes. The suggestion keeps the header range and rounds additional data up to 128 KiB."
        }
        return "No erased end area was found. The suggestion keeps the complete accessible ROM range."
    }

    public static func analyze(_ input: Data, headerBytes: Int?) throws -> ROMContentAnalysis {
        let data = Data(input)
        guard data.count >= 512, data.count <= 0x1000000 else {
            throw FlashMDError.invalid("Content analysis requires a ROM range between 512 bytes and 16 MiB.")
        }
        let last = data.lastIndex { $0 != 0xFF }
        let usedEnd = last.map { $0 + 1 } ?? 0
        let validHeader = headerBytes.flatMap { (512...data.count).contains($0) && $0.isMultiple(of:2) ? $0 : nil }
        let beyond = validHeader.map { size in data[size...].reduce(0) { $0 + ($1 == 0xFF ? 0 : 1) } }
        var mirror: Int?
        var period = data.count
        while period.isMultiple(of:2), period / 2 >= 0x20000 {
            let half = period / 2
            guard data.prefix(half).elementsEqual(data[half..<period]) else { break }
            mirror = half; period = half
        }
        let suggestion: Int?
        if last == nil { suggestion = nil }
        else if let validHeader, usedEnd <= validHeader { suggestion = validHeader }
        else { suggestion = min(data.count, max(512, ((usedEnd + 0x1FFFF) / 0x20000) * 0x20000)) }
        return .init(scannedBytes:data.count,headerBytes:headerBytes,lastNonErasedByte:last,
            trailingErasedBytes:data.count-usedEnd,nonErasedBytesBeyondHeader:beyond,
            possibleMirrorBytes:mirror,suggestedBytes:suggestion,sha256:hash(data))
    }

    public static func read(device: any CartridgeDevice, cartridge: CartridgeSnapshot,
                            progress: ProgressHandler) throws -> ROMContentAnalysis {
        guard cartridge.canBackupROM else { throw FlashMDError.invalid(cartridge.mapperMessage ?? "Complete ROM unavailable.") }
        let fresh = try device.inspectConfigured(profile:cartridge.profile,override:cartridge.configurationOverride,mapper:cartridge.mapperSelection)
        guard fresh == cartridge else { throw FlashMDError.invalid("The cartridge changed before content analysis. Scan again.") }
        var data = Data()
        // A bounded independent read checks stability even when streaming is off.
        // Keep blocks aligned to header/save boundaries to isolate uncertain tails.
        let chunkBytes = device.preferredROMReadBytes
        var excludedStart: Int?
        var limitation: String?
        let headerLimit = (cartridge.romSize?.bytes).flatMap { (512...cartridge.romReadLimit).contains($0) && $0.isMultiple(of:2) ? $0 : nil }
        var offset = 0
        while offset < cartridge.romReadLimit {
            try Task.checkCancellation()
            let boundary = [headerLimit,cartridge.saveLayout?.base].compactMap { $0 }
                .filter { $0 > offset }.min() ?? cartridge.romReadLimit
            let length = min(chunkBytes,cartridge.romReadLimit-offset,boundary-offset)
            let block = try device.readROM(offset:offset,count:length)
            guard block.count == length else { throw FlashMDError.invalid("The programmer returned a short read during content analysis.") }
            let check = try device.readROMForVerification(offset:offset,count:length)
            guard check.count == length else { throw FlashMDError.invalid("The programmer returned a short verification read.") }
            if check != block {
                // Do not hide instability inside the declared game. Outside it,
                // preserve the verified prefix and explicitly exclude the tail.
                guard cartridge.mapper == .linear, let headerLimit, offset >= headerLimit else {
                    throw ROMScanMismatch(first:block,second:check,offset:offset)
                }
                // Keep every checked block, including real game data beyond an
                // incorrect header. Cutting back to the header would truncate Bailey.
                excludedStart = offset
                limitation = "Reads beyond the header range were unstable. The suggestion keeps the checked prefix; the rest is unconfirmed."
                break
            }
            data.append(block)
            progress(.init(.readingROM,offset+length,cartridge.romReadLimit,detail:"Analyzing ROM contents"))
            offset += length
        }
        // A selected SRAM window must not be incorporated into a ROM file simply
        // because its bytes are stable. Only selection-confirmed SRAM can exclude
        // a stable window. Read-only lane heuristics must not truncate real ROM.
        if cartridge.mapper == .linear, cartridge.saveStatus == .confirmed,
           let layout = cartridge.saveLayout, let headerLimit, headerLimit <= layout.base,
           data.count >= layout.base+layout.windowBytes {
            var save = Data()
            for offset in stride(from:0,to:layout.windowBytes,by:32768) {
                let count = min(32768,layout.windowBytes-offset)
                save.append(try device.readSRAM(layout:layout,offset:offset,count:count))
            }
            if try layout.pack(Data(data[layout.base..<layout.base+layout.windowBytes])) == layout.pack(save) {
                excludedStart = layout.base; data = Data(data.prefix(layout.base))
                limitation = "Save memory overlaps this read range. The suggestion excludes it; ROM beyond that boundary is unconfirmed."
            }
        }
        var result = try analyze(data,headerBytes:cartridge.romSize?.bytes)
        // Permanently mapped single-lane memory cannot be selection-confirmed.
        // A whole tail that repeats the declared saves is stronger sizing evidence
        // than a matching window alone. Keep the complete scan and permit a full
        // export: this remains a suggestion, never proof of physical memory type.
        if cartridge.mapper == .linear, cartridge.saveStatus == .readOnly,
           let layout = cartridge.saveLayout, let headerLimit, headerLimit <= layout.base,
           data.count >= layout.base + layout.windowBytes * 4 {
            var save = Data(), check = Data()
            for offset in stride(from:0,to:layout.windowBytes,by:32768) {
                let count = min(32768,layout.windowBytes-offset)
                save.append(try device.readSRAM(layout:layout,offset:offset,count:count))
                check.append(try device.readSRAM(layout:layout,offset:offset,count:count))
            }
            let packed = try layout.pack(save)
            let packedCheck = try layout.pack(check)
            guard packed == packedCheck else { throw FlashMDError.invalid("SRAM reads did not match. Scan again.") }
            if let period = try possibleSaveMirrorPeriod(data:Data(data[layout.base...]),layout:layout,packedSave:packed) {
                result.suggestedBytes = layout.base
                result.possibleSaveMirrorStart = layout.base
                result.possibleSaveMirrorBytes = period
                limitation = "Possible save-memory mirrors follow the ROM. The suggestion excludes them; Back Up Complete ROM keeps the full read range."
            }
        }
        let after = try device.inspectConfigured(profile:cartridge.profile,override:cartridge.configurationOverride,mapper:cartridge.mapperSelection)
        guard after == cartridge, hash(Data(data.prefix(512))) == cartridge.fingerprint else {
            throw FlashMDError.invalid("The cartridge changed during content analysis. Scan again.")
        }
        result.requestedScanBytes = cartridge.romReadLimit
        result.excludedROMStart = excludedStart; result.limitation = limitation
        // Naming identity never includes SRAM, floating bus bytes or unconfirmed tails.
        let identityEnd = min(data.count,headerLimit ?? 0x20000,cartridge.saveLayout?.base ?? data.count)
        result.identitySHA256 = hash(Data(data.prefix(identityEnd)))
        return result
    }

    private static func possibleSaveMirrorPeriod(data: Data, layout: SRAMLayout, packedSave: Data) throws -> Int? {
        guard let lane = layout.lane, data.count >= layout.windowBytes,
              try layout.pack(Data(data.prefix(layout.windowBytes))) == packedSave else { return nil }
        let unusedCount = data.count / 2
        let blankCount = stride(from:1-lane,to:data.count,by:2).reduce(0) { count, index in
            count + (data[index] == 0 || data[index] == 0xFF ? 1 : 0)
        }
        guard blankCount * 100 >= unusedCount * 99 else { return nil }
        var period = 128
        while period < layout.windowBytes { period *= 2 }
        // Require at least four complete repetitions, including bytes outside the
        // declared window. A small header plus one matching ROM slice is insufficient.
        while period <= min(0x20000,data.count / 4) {
            if data.count.isMultiple(of:period) {
                let sample = data.prefix(period)
                if stride(from:period,to:data.count,by:period).allSatisfy({ sample.elementsEqual(data[$0..<$0+period]) }) { return period }
            }
            period *= 2
        }
        return nil
    }
}
