import Foundation

public enum ROMMapper: String, CaseIterable, Codable, Sendable, Identifiable {
    case automatic, linear, segaSSF2, pierSolar
    public var id: Self { self }
    public var displayName: String {
        switch self {
        case .automatic: "Automatic"
        case .linear: "Linear"
        case .segaSSF2: "Sega SSF2"
        case .pierSolar: "Pier Solar"
        }
    }
    public static func detect(_ metadata: ROMMetadata?) -> ROMMapper {
        guard let metadata else { return .linear }
        let system = metadata.console.uppercased()
        if system.hasPrefix("SEGA SSF") || system.hasPrefix("SEGA DOA") { return .segaSSF2 }
        if metadata.title.uppercased().contains("SUPER STREET FIGHTER"),
           [UInt16(0xCE25), 0xE41D, 0xE017].contains(metadata.storedChecksum) { return .segaSSF2 }
        if metadata.productCode.hasPrefix("GM T-574023"), metadata.title.uppercased().hasPrefix("PIER SOLAR") { return .pierSolar }
        return .linear
    }
    public func size(_ metadata: ROMMetadata?) -> Int? {
        if self == .pierSolar { return 0x800000 }
        if self == .segaSSF2, let metadata,
           metadata.title.uppercased().contains("SUPER STREET FIGHTER"),
           [UInt16(0xCE25), 0xE41D, 0xE017].contains(metadata.storedChecksum) { return 0x500000 }
        if self == .segaSSF2, metadata?.console.uppercased().hasPrefix("SEGA DOA") == true {
            switch metadata?.storedChecksum {
            case 0x6E1E, 0xBCBF: return 0xEA0000
            case 0x0000: return 0xEAF2F4
            default: return nil
            }
        }
        return metadata?.declaredROMBytes
    }
}

public enum ROMAccess: String, Codable, Sendable {
    case linear, banked, unavailable
}

/// Reads logical ROM offsets through one qualified 512 KiB cartridge window.
/// The callbacks only read memory or write volatile mapper registers.
final class BankedROMReader {
    let mapper: ROMMapper
    let size: Int
    private let register: Int
    private let window: Int
    private let originalPage: Int
    private let select: (Int, UInt8) throws -> Void
    private let read: (Int, Int) throws -> Data

    init(mapper: ROMMapper, size: Int, register: Int? = nil, window: Int? = nil, originalPage: Int? = nil, select: @escaping (Int, UInt8) throws -> Void,
         read: @escaping (Int, Int) throws -> Data) {
        self.mapper = mapper; self.size = size; self.select = select; self.read = read
        self.register = register ?? (mapper == .pierSolar ? 0xA13003 : 0xA130FF)
        self.window = window ?? (mapper == .pierSolar ? 0x280000 : 0x380000)
        self.originalPage = originalPage ?? (mapper == .pierSolar ? 0 : 7)
    }
    func restore() throws { try select(register, UInt8(originalPage)) }

    func qualify() throws -> Bool {
        // Compare two locations against a page that is already visible elsewhere.
        // Identical source and target samples cannot establish that switching works.
        let page = 1
        let offsets = [0, 0x40000]
        let header = try read(0, 512)
        let expected = try offsets.map { try read(page * 0x80000 + $0, 512) }
        let original = try offsets.map { try read(window + $0, 512) }
        var failure: Error?
        var switched = false
        do {
            try select(register, UInt8(page))
            let first = try offsets.map { try read(window + $0, 512) }
            let second = try offsets.map { try read(window + $0, 512) }
            switched = first == expected && second == expected && original != expected
            // Check every additional page-address bit needed by this game's size.
            // Stable reads alone would also accept a reader that silently wraps at 4 MiB.
            var highPage = 8
            while highPage * 0x80000 < size, switched {
                try select(register, UInt8(highPage))
                let remaining = size - highPage * 0x80000
                guard remaining >= 512 else { switched = false; break }
                let highOffsets = [0, min(0x40000, remaining - 512)]
                let low = try highOffsets.map { try read($0, 512) }
                let high = try highOffsets.map { try read(window + $0, 512) }
                let repeatHigh = try highOffsets.map { try read(window + $0, 512) }
                switched = high == repeatHigh && high != low
                highPage *= 2
            }
        } catch { failure = error }
        // Always attempt restoration, including cancellation or a failed read.
        try restore()
        let restored = try offsets.map { try read(window + $0, 512) }
        guard restored == original, try read(0, 512) == header else {
            throw FlashMDError.invalid("ROM mapping could not be restored. Unplug USB before moving the cartridge.")
        }
        if let failure { throw failure }
        return switched
    }

    func readROM(offset: Int, count: Int) throws -> Data {
        guard offset >= 0, count >= 0, offset <= size, count <= size - offset else {
            throw FlashMDError.invalid("ROM read exceeds the mapped game size.")
        }
        var output = Data()
        var failure: Error?
        do {
            while output.count < count {
                try Task.checkCancellation()
                let position = offset + output.count
                let page = position / 0x80000, within = position % 0x80000
                let length = min(count - output.count, 32768, 0x80000 - within)
                try select(register, UInt8(page))
                let data = try read(window + within, length)
                guard data.count == length else { throw FlashMDError.invalid("Incomplete bank read. Scan again.") }
                output.append(data)
            }
        } catch { failure = error }
        try restore()
        if let failure { throw failure }
        return output
    }
}
