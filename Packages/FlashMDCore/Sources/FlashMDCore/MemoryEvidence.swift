import Foundation

/// A header describes a save layout; it does not identify the memory behind it.
public enum SaveMemoryStatus: String, Codable, Sendable {
    case none, declared, confirmed, readOnly, unconfirmed, manual, unsupported
    public var explanation: String {
        switch self {
        case .none: "No supported save memory declared"
        case .declared: "Declared by the game; not confirmed"
        case .confirmed: "SRAM selection checked"
        case .readOnly: "Save reads match; writing unconfirmed"
        case .unconfirmed: "SRAM could not be confirmed"
        case .manual: "Manual layout; memory type not confirmed"
        case .unsupported: "Save protocol not supported"
        }
    }
}

enum SaveMemoryProbe {
    static func isBlank(_ bytes: Data) -> Bool { bytes.allSatisfy { $0 == 0xFF } || bytes.allSatisfy { $0 == 0 } }
    /// Does not write test patterns. Blank or always-visible memory can be inconclusive.
    static func qualify(_ device: any CartridgeDevice, layout: SRAMLayout) throws -> SaveMemoryStatus {
        try Task.checkCancellation()
        func rom() throws -> Data {
            var bytes = Data()
            for offset in stride(from:0,to:layout.windowBytes,by:32768) {
                let count = min(32768,layout.windowBytes-offset)
                let block = try device.readROMForVerification(offset:layout.base+offset,count:count)
                guard block.count == count else { throw FlashMDError.invalid("Incomplete memory identification read.") }
                bytes.append(block)
            }
            return bytes
        }
        func save() throws -> Data {
            var bytes = Data()
            for offset in stride(from:0,to:layout.windowBytes,by:32768) {
                let count = min(32768,layout.windowBytes-offset)
                let block = try device.readSRAM(layout:layout,offset:offset,count:count)
                guard block.count == count else { throw FlashMDError.invalid("Incomplete SRAM identification read.") }
                bytes.append(block)
            }
            return try layout.pack(bytes)
        }
        let originalBus = try rom(), checkBus = try rom()
        let original = try layout.pack(originalBus), originalCheck = try layout.pack(checkBus)
        let first = try save(), second = try save()
        let restoredBus = try rom(), restored = try layout.pack(restoredBus)
        guard first == second else { throw FlashMDError.invalid("SRAM reads did not match. No save file was created.") }
        guard !isBlank(first) else { return .unconfirmed }
        // Only compare active lanes: unused bus bytes need not be driven by SRAM.
        guard original == originalCheck, restored == original else { return .unconfirmed }
        if first != original { return .confirmed }
        // Non-overlapping SRAM can be permanently mapped, so selection need not
        // change the active lane. An almost empty unused lane is supporting evidence
        // for a read-only export, never proof of SRAM type or safe write access.
        // Keep stable, meaningful two-lane ROM (including misleading headers) out.
        if let lane = layout.lane {
            let busReads = [originalBus,checkBus,restoredBus]
            func unusedLaneHasNoMeaningfulData(_ bus: Data) -> Bool {
                let unused = stride(from:1-lane,to:bus.count,by:2).map { bus[$0] }
                let blank = unused.filter { $0 == 0 || $0 == 0xFF }.count
                // Floating lanes can retain occasional bits. This is only a
                // read-only heuristic; it never grants erase or write access.
                return blank * 100 >= unused.count * 99
            }
            // Some undriven lanes retain one data bit more often than the sparse
            // noise allowance above. Accept that extra read-only evidence only
            // when the residue is a single bit across all three reads and varies
            // while the active save lane stays identical. Stable ROM patterns or
            // several meaningful data bits do not qualify through this path.
            func unusedLaneHasChangingSingleBitResidue() -> Bool {
                var residue: UInt8 = 0
                var changed = false
                for index in stride(from:1-lane,to:originalBus.count,by:2) {
                    let values = busReads.map { $0[index] }
                    if values[0] != values[1] || values[0] != values[2] { changed = true }
                    for value in values {
                        residue |= value.nonzeroBitCount <= 4 ? value : ~value
                    }
                    if residue.nonzeroBitCount > 1 { return false }
                }
                return changed && residue.nonzeroBitCount == 1
            }
            if (busReads.allSatisfy(unusedLaneHasNoMeaningfulData) || unusedLaneHasChangingSingleBitResidue()),
               let metadata = try? ROMMetadata.parse(device.readROMForVerification(offset:0,count:512)),
               metadata.saveWarning == nil, metadata.saveLayout == layout,
               let romBytes = metadata.declaredROMBytes, romBytes <= layout.base {
                return .readOnly
            }
        }
        return .unconfirmed
    }
}

/// A write-flow check, never part of scanning. The caller journals the complete
/// original save before invoking this and supplies uncancellable restoration I/O.
enum SRAMWriteProbe {
    static func check(original: Data, read: () throws -> Data,
                      writePrefix: (Data) throws -> Void, verifyROM: () throws -> Void) throws {
        guard original.count >= 32, try read() == original else {
            throw FlashMDError.invalid("Save data changed before the write check. Scan again.")
        }
        // Neither value is a flash programming/erase command. Only the first
        // 32 save bytes are touched; no unlock addresses are written.
        let prefix = Data(original.prefix(32))
        let pattern = Data(prefix.map { $0 == 0x33 ? 0xCC : 0x33 })
        var failure: Error?
        do {
            try writePrefix(pattern)
            let changed = try read()
            guard changed == pattern + original.dropFirst(32) else {
                throw FlashMDError.invalid("SRAM writing could not be verified. No ROM was erased.")
            }
            try verifyROM()
        } catch { failure = error }
        // Restore even if writing or readback failed partway. Cancellation must
        // not interrupt this cleanup; a failed cleanup keeps the recovery journal.
        do {
            try writePrefix(prefix)
            guard try read() == original else {
                throw FlashMDError.invalid("Original SRAM could not be restored.")
            }
            try verifyROM()
        } catch {
            throw FlashMDError.invalid("Save restoration could not be verified. Keep the save recovery files and reconnect the reader.")
        }
        if let failure { throw failure }
    }
}
