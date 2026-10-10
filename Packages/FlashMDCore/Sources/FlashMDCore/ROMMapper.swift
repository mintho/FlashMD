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
        if metadata.isDaemonClaw { return .segaSSF2 }
        if system.hasPrefix("SEGA SSF") || system.hasPrefix("SEGA DOA") { return .segaSSF2 }
        if metadata.title.uppercased().contains("SUPER STREET FIGHTER"),
           [UInt16(0xCE25), 0xE41D, 0xE017].contains(metadata.storedChecksum) { return .segaSSF2 }
        if metadata.productCode.hasPrefix("GM T-574023"), metadata.title.uppercased().hasPrefix("PIER SOLAR") { return .pierSolar }
        return .linear
    }
    /// Supported scan envelope, not physical chip capacity or a game's length.
    /// Analyze every page, including pages after gaps; never rely on a revision table.
    public var scanLimit: Int? {
        switch self {
        case .segaSSF2: 0x1000000
        case .pierSolar: 0x800000
        case .automatic, .linear: nil
        }
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
    private let readTransfer: (Int, Int) throws -> Data
    var transferBytes: Int
    private var restorationWitnesses: [(Int, Data)] = []

    init(mapper: ROMMapper, size: Int, register: Int? = nil, window: Int? = nil, originalPage: Int? = nil, select: @escaping (Int, UInt8) throws -> Void,
         read: @escaping (Int, Int) throws -> Data, transferBytes: Int = 32768,
         readTransfer: ((Int, Int) throws -> Data)? = nil) {
        self.mapper = mapper; self.size = size; self.select = select; self.read = read
        self.readTransfer = readTransfer ?? read; self.transferBytes = transferBytes
        self.register = register ?? (mapper == .pierSolar ? 0xA13003 : 0xA130FF)
        self.window = window ?? (mapper == .pierSolar ? 0x280000 : 0x380000)
        self.originalPage = originalPage ?? (mapper == .pierSolar ? 0 : 7)
    }
    func restore() throws {
        try select(register, UInt8(originalPage))
        for (offset,expected) in restorationWitnesses {
            guard try read(offset,expected.count) == expected else {
                throw FlashMDError.invalid("ROM mapping could not be restored. Unplug USB before continuing.")
            }
        }
    }

    func qualify() throws -> Bool {
        // Compare two locations against a page that is already visible elsewhere.
        // Identical source and target samples cannot establish that switching works.
        let page = 1
        let offsets = [0, 0x40000]
        let header = try read(0, 512)
        let expected = try offsets.map { try read(page * 0x80000 + $0, 512) }
        let original = try offsets.map { try read(window + $0, 512) }
        restorationWitnesses = [(0,header)] + offsets.enumerated().map { (window+$0.element,original[$0.offset]) }
        // Pier Solar has only five fixed pages; its three upper windows can
        // initially all expose page zero. They cannot be reference pages 5–7.
        let visiblePages = (1..<(mapper == .pierSolar ? 5 : 8)).filter { $0*0x80000 != window || $0 == originalPage }
        let visible = try visiblePages.map { page in (page,try offsets.map { try read(page*0x80000+$0,512) }) }
        var failure: Error?
        var switched = false
        do {
            try select(register, UInt8(page))
            let first = try offsets.map { try read(window + $0, 512) }
            let second = try offsets.map { try read(window + $0, 512) }
            switched = first == expected && second == expected && original != expected
            // Prove the remaining low page bits against already visible ROM,
            // including bank boundaries. This catches stuck bits and partial mappers.
            for (page,expectedPage) in visible where page >= 2 && switched {
                try select(register,UInt8(page))
                let selected = try offsets.map { try read(window+$0,512) }
                let repeated = try offsets.map { try read(window+$0,512) }
                switched = selected == expectedPage && repeated == selected
            }
            // Check every additional page-address bit in the supported scan range.
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
        if switched {
            restorationWitnesses = [(0,header)] + offsets.enumerated().map { (window+$0.element,original[$0.offset]) }
        }
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
                let length = min(count - output.count, transferBytes, 0x80000 - within)
                try select(register, UInt8(page))
                let data = try readTransfer(window + within, length)
                guard data.count == length else { throw FlashMDError.invalid("Incomplete bank read. Scan again.") }
                output.append(data)
            }
        } catch { failure = error }
        try restore()
        if let failure { throw failure }
        return output
    }
}
