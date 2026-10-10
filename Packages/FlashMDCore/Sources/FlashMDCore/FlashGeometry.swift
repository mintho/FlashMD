import Foundation

public struct FlashSector: Codable, Sendable, Equatable {
    public let offset: Int
    public let bytes: Int
}
public struct FlashGeometry: Codable, Sendable, Equatable {
    public let capacity: Int
    public let manufacturer: UInt16
    public let deviceID: UInt16
    public let commandSet: Int
    public let extendedID: UInt16
    public let bootID: UInt16
    public let sectors: [FlashSector]
    public let mdDumperAlgorithm: Int?
    /// Other documented AMD-command-set parts use ordinary word programming.
    public var usesUnlockBypass: Bool {
        mdDumperAlgorithm == nil && (manufacturer == 0x01 || manufacturer == 0x20 && [0x2256,0x2257].contains(deviceID))
    }
    public var supported: Bool {
        if let algorithm = mdDumperAlgorithm {
            return (1...4).contains(algorithm) && sectors == [.init(offset:0,bytes:capacity)] && (0x100000...0x800000).contains(capacity)
        }
        if commandSet == 2, manufacturer == 0x20, deviceID == 0x22ED, capacity == 0x800000 {
            return sectors.count == 128 && sectors.allSatisfy { $0.bytes == 65536 }
        }
        if commandSet == 2, manufacturer == 0xC2,
           (capacity == 0x400000 && [0x22A7,0x22A8].contains(deviceID) || capacity == 0x800000 && [0x22CB,0x22C9].contains(deviceID)) {
            let top = [0x22A7,0x22C9].contains(deviceID)
            let ordered = top ? Array(sectors.reversed()) : sectors
            return ordered.count == (capacity == 0x400000 ? 71 : 135)
                && ordered.prefix(8).allSatisfy { $0.bytes == 8192 }
                && ordered.dropFirst(8).allSatisfy { $0.bytes == 65536 }
        }
        let top = (manufacturer == 0x20 && deviceID == 0x2256) || (manufacturer == 0x01 && bootID == 0x2201)
        let ordered = top ? Array(sectors.reversed()) : sectors
        let geometryMatches = ordered.count == (capacity == 0x400000 ? 71 : 135)
            && ordered.prefix(8).allSatisfy { $0.bytes == 8192 }
            && ordered.dropFirst(8).allSatisfy { $0.bytes == 65536 }
        return geometryMatches && commandSet == 2 && ((manufacturer == 0x20 && [0x2256, 0x2257].contains(deviceID) && capacity == 0x400000) ||
        (manufacturer == 0x01 && deviceID == 0x227E && extendedID == 0x2210 && [0x2200,0x2201].contains(bootID) && capacity == 0x800000))
    }
    public var name: String {
        if mdDumperAlgorithm != nil { return String(format:"Flash %02X:%02X",manufacturer,deviceID) }
        if manufacturer == 0x01 && supported { return "AMD/Spansion S29GL064N" }
        if manufacturer == 0xC2 && supported { return capacity == 0x800000 ? "Macronix MX29LV640" : "Macronix MX29LV320" }
        if manufacturer == 0x20 && deviceID == 0x22ED && supported { return "ST M29W640D" }
        return supported ? (deviceID == 0x2256 ? "ST M29W320ET" : "ST M29W320EB") : String(format: "Flash %04X:%04X", manufacturer, deviceID)
    }
    init(mdDumperCapacity: Int, manufacturer: UInt16, deviceID: UInt16, algorithm: Int) {
        capacity = mdDumperCapacity; self.manufacturer = manufacturer; self.deviceID = deviceID
        commandSet = 0; extendedID = 0; bootID = 0; mdDumperAlgorithm = algorithm
        sectors = [.init(offset:0,bytes:mdDumperCapacity)]
    }
    public init(cfi: Data, manufacturer: UInt16, deviceID: UInt16, extendedID: UInt16 = 0, bootID: UInt16 = 0) throws {
        guard cfi.count >= 0x80, Data(cfi[0x10..<0x13]) == Data("QRY".utf8) else { throw FlashMDError.invalid("Flash did not return valid CFI geometry. ROM backup may still be possible.") }
        func le(_ at: Int) -> Int { Int(cfi[at]) | Int(cfi[at+1]) << 8 }
        let exponent = Int(cfi[0x27]), count = Int(cfi[0x2C])
        guard exponent >= 16, exponent <= 24, count > 0, count <= 8 else { throw FlashMDError.invalid("Unsupported or invalid CFI geometry.") }
        let capacity = 1 << exponent
        var sectors = [FlashSector](), offset = 0
        var regions = [(Int, Int)]()
        for index in 0..<count {
            let at = 0x2D + index * 4, blocks = le(at) + 1, size = le(at+2) == 0 ? 128 : le(at+2) * 256
            guard blocks <= 2048, size > 0, offset + blocks * size <= capacity else { throw FlashMDError.invalid("Inconsistent flash erase geometry.") }
            regions.append((blocks,size)); offset += blocks * size
        }
        guard offset == capacity else { throw FlashMDError.invalid("CFI erase regions do not cover the reported capacity.") }
        // AMD boot-sector CFI tables describe the small region first for both boot variants.
        if (manufacturer == 0x01 && bootID == 0x2201 && regions.count > 1) ||
           (manufacturer == 0x20 && deviceID == 0x2256 && regions.first?.1 == 8192) ||
           (manufacturer == 0xC2 && [0x22A7,0x22C9].contains(deviceID) && regions.first?.1 == 8192) { regions.reverse() }
        offset = 0
        for (blocks,size) in regions { for _ in 0..<blocks { sectors.append(.init(offset:offset,bytes:size)); offset += size } }
        self.mdDumperAlgorithm = nil
        self.capacity = capacity; self.commandSet = le(0x13); self.manufacturer = manufacturer; self.deviceID = deviceID
        self.extendedID = extendedID; self.bootID = bootID
        self.sectors = sectors
    }
    public func programLength(_ length: Int, accessibleCapacity: Int? = nil) throws -> Int {
        if mdDumperAlgorithm != nil {
            // Erasure affects the physical chip. Programming and verification
            // cover only the cartridge's separately established linear range.
            let limit = min(capacity, accessibleCapacity ?? 0x400000, 0x400000)
            guard limit.isMultiple(of:2), length > 0, length <= limit else { throw FlashMDError.invalid("The ROM exceeds accessible cartridge capacity, or the capacity is not an even byte count.") }
            return limit
        }
        guard length > 0, let last = sectors.first(where: { $0.offset + $0.bytes >= length }) else { throw FlashMDError.invalid("The ROM exceeds flash capacity.") }
        return last.offset + last.bytes
    }
}

public enum CartridgeProfile: String, CaseIterable, Sendable, Codable, Identifiable {
    case automatic
    // Keep the serialized key for existing settings and manifests; this SRAM mapper exposes 2 MiB ROM.
    case krikzz4M
    case linearROMOnly
    public var id: Self { self }
    public var displayName: String {
        switch self {
        case .automatic: "Automatic"
        case .krikzz4M: "2 MiB ROM + 32 KiB SRAM"
        case .linearROMOnly: "4 MiB ROM only"
        }
    }
    public var romCapacityLimit: Int? {
        switch self {
        case .automatic: nil
        case .krikzz4M: 0x200000
        case .linearROMOnly: 0x400000
        }
    }
    public func usableCapacity(for geometry: FlashGeometry) -> MemoryMeasurement? {
        romCapacityLimit.map { .init(bytes:min($0,geometry.capacity),source:$0 < geometry.capacity ? .profile : .hardware) }
    }
    public var saveLayout: SRAMLayout? { self == .krikzz4M ? try? SRAMLayout(start: 0x200001, end: 0x20FFFF, lane: 1) : nil }
}
