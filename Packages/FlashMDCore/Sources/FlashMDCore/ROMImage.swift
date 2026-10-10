import Foundation
import CryptoKit

public enum FlashMDError: LocalizedError, Sendable, Equatable {
    case invalid(String)
    case disconnected
    case busy
    case timeout
    case cancelled
    case mismatch(Int)
    public var errorDescription: String? {
        switch self {
        case .invalid(let text): text
        case .disconnected: "The programmer was disconnected. Reconnect it and refresh before trying again."
        case .busy: "The programmer is busy. Close other apps using this USB device, then scan again."
        case .timeout: "The programmer did not respond before the timeout. Check the USB connection and refresh."
        case .cancelled: "The operation was cancelled."
        case .mismatch(let offset): "Readback differs at byte 0x\(String(offset, radix: 16).uppercased()). Verification failed."
        }
    }
}

public enum SaveFormat: String, CaseIterable, Codable, Sendable, Identifiable {
    case raw, packed
    public var id: Self { self }
    public var displayName: String { self == .raw ? "Full bus dump" : "Save bytes only" }
}

public struct SRAMLayout: Codable, Sendable, Equatable {
    public let start: Int
    public let end: Int
    public let lane: Int? // nil is a 16-bit region; 0/1 is the active byte lane.
    public var base: Int { start & ~1 }
    public var windowBytes: Int { (end | 1) - base + 1 }
    public var activeBytes: Int { lane == nil ? windowBytes : windowBytes / 2 }
    public init(start: Int, end: Int, lane: Int?) throws {
        guard start >= 0x200000, end >= start, end < 0x300000, end - start < 0x10000,
              lane == nil || lane == 0 || lane == 1 else {
            throw FlashMDError.invalid("Unsupported SRAM range or layout. Select a supported cartridge profile.")
        }
        if let lane {
            guard start & 1 == lane, end & 1 == lane else { throw FlashMDError.invalid("For 8-bit SRAM, start and end addresses must both match the selected odd or even byte lane.") }
        } else {
            guard start & 1 == 0, end & 1 == 1 else { throw FlashMDError.invalid("For 16-bit SRAM, use an even start address and an odd inclusive end address.") }
        }
        self.start = start; self.end = end; self.lane = lane
    }
    public func pack(_ raw: Data) throws -> Data {
        guard raw.count == windowBytes else { throw FlashMDError.invalid("Raw save length must be exactly \(windowBytes) bytes.") }
        guard let lane else { return raw }
        return Data(stride(from: lane, to: raw.count, by: 2).map { raw[$0] })
    }
    public func rawRepresentation(_ input: Data, format: SaveFormat) throws -> Data {
        if format == .raw {
            guard input.count == windowBytes else { throw FlashMDError.invalid("Raw save length must be exactly \(windowBytes) bytes. No data will be truncated.") }
            return input
        }
        guard input.count == activeBytes else { throw FlashMDError.invalid("Packed save length must be exactly \(activeBytes) bytes.") }
        guard let lane else { return input }
        var raw = Data(repeating: 0xFF, count: windowBytes)
        for index in input.indices { raw[index * 2 + lane] = input[index] }
        return raw
    }
}

public struct ROMMetadata: Codable, Sendable, Equatable {
    public let console: String
    public let domesticTitle: String
    public let internationalTitle: String
    public let productCode: String
    public let copyright: String
    public let copyrightYear: String?
    public let peripherals: String
    public let regions: [String]
    public let declaredROMBytes: Int?
    public let storedChecksum: UInt16
    public let saveLayout: SRAMLayout?
    public let saveWarning: String?
    public let rawHeader: Data
    // Some Neofid cartridges put studio credits in the international title slot.
    // Keep both original fields in metadata, but use the game name for display/export.
    public var title: String {
        if internationalTitle.uppercased() == "NEOFID STUDIOS BITBEAM CANNON", !domesticTitle.isEmpty { return domesticTitle }
        return internationalTitle.isEmpty ? (domesticTitle.isEmpty ? "Untitled cartridge" : domesticTitle) : internationalTitle
    }
    var isDaemonClaw: Bool {
        domesticTitle.uppercased() == "DAEMON CLAW" && internationalTitle.uppercased() == "NEOFID STUDIOS BITBEAM CANNON"
    }
    public var revision: Int? {
        guard productCode.range(of:"^(GM|AI|OS|BR) [A-Za-z0-9-]+-[0-9]{2}$",options:.regularExpression) != nil else { return nil }
        return Int(productCode.suffix(2))
    }

    public static func parse(_ data: Data) throws -> ROMMetadata {
        guard data.count >= 512 else { throw FlashMDError.invalid("The ROM is too short to contain a Mega Drive header.") }
        let data = Data(data.prefix(512))
        func text(_ offset: Int, _ count: Int) -> String {
            let bytes = Data(data[offset..<offset + count]).map { $0 == 0 || $0 == 0xFF ? UInt8(32) : $0 }
            // Some aftermarket headers use Western copyright/trademark bytes
            // that are invalid Shift-JIS. Preserve them instead of replacing them.
            let field = Data(bytes)
            let value = String(data: field, encoding: .shiftJIS)
                ?? String(data: field, encoding: .windowsCP1252)
                ?? String(decoding: bytes, as: UTF8.self)
            return value.components(separatedBy: .controlCharacters).joined().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
        func u32(_ offset: Int) -> Int { data[offset..<offset+4].reduce(0) { ($0 << 8) | Int($1) } }
        let copyright = text(0x110,16)
        let year = copyright.range(of: "(?:19|20)[0-9]{2}", options: .regularExpression).map { String(copyright[$0]) }
        let region = text(0x1F0,16).uppercased()
        var regions = [String]()
        if region.allSatisfy({ "JUE ".contains($0) }) {
            if region.contains("J") { regions.append("Japan") }; if region.contains("U") { regions.append("USA") }; if region.contains("E") { regions.append("Europe") }
        } else if let first = region.first, let bits = Int(String(first), radix: 16) {
            if bits & 1 != 0 { regions.append("Japan") }; if bits & 4 != 0 { regions.append("USA") }; if bits & 8 != 0 { regions.append("Europe") }
        }
        let romStart = u32(0x1A0), romEnd = u32(0x1A4)
        let length = romStart == 0 && romEnd >= 511 && romEnd < 0x1000000 ? romEnd + 1 : nil
        var layout: SRAMLayout?, warning: String?
        if data[0x1B0] == 0x52 && data[0x1B1] == 0x41 {
            let type = data[0x1B2]
            if data[0x1B3] & 0x40 != 0 || ![UInt8(0xF0),0xF8,0xE0].contains(type) {
                warning = "EEPROM or an unsupported save type is declared."
            } else {
                let start = u32(0x1B4), end = u32(0x1B8)
                // The type byte declares the lane. Some headers give the whole
                // bus window (even start, odd end) for single-lane SRAM.
                let lane: Int? = type == 0xE0 ? nil : type == 0xF8 ? 1 : 0
                let first = lane.map { start + ((start & 1) == $0 ? 0 : 1) } ?? start
                let last = lane.map { end - ((end & 1) == $0 ? 0 : 1) } ?? end
                do { layout = try SRAMLayout(start: first, end: last, lane: lane) }
                catch { warning = error.localizedDescription }
            }
        } else if data[0x1B0] == 0x45 && data[0x1B1] == 0x50 {
            warning = "An unsupported save protocol is declared."
        }
        return ROMMetadata(console: text(0x100,16), domesticTitle: text(0x120,48), internationalTitle: text(0x150,48), productCode: text(0x180,14), copyright: copyright, copyrightYear: year, peripherals: text(0x190,16), regions: regions, declaredROMBytes: length, storedChecksum: UInt16(data[0x18E]) << 8 | UInt16(data[0x18F]), saveLayout: layout, saveWarning: warning, rawHeader: Data(data[0x100..<0x200]))
    }
}

public struct ROMImage: Sendable {
    public let data: Data
    public let metadata: ROMMetadata
    public let checksum: UInt16
    public let sha256: String
    public let warnings: [String]
    public init(data: Data) throws {
        let data = Data(data)
        guard data.count >= 512, data.count <= 16 * 1024 * 1024 else { throw FlashMDError.invalid("Select a ROM between 512 bytes and 16 MiB.") }
        if Data(data[0x100..<0x104]) != Data("SEGA".utf8) {
            if Data(data[0x100..<0x104]) == Data("ESAG".utf8) { throw FlashMDError.invalid("This image is byte-swapped. Convert it to raw big-endian format before writing.") }
            if data.count > 0x2280, data[0x2280] == 0x53, data[0x280] == 0x45 { throw FlashMDError.invalid("This is an interleaved SMD image. Convert it to raw binary before writing.") }
            throw FlashMDError.invalid(data.allSatisfy { $0 == 0xFF } ? "The image is all FF; it is blank or unreadable, not a game ROM." : "A valid SEGA header was not found. Select a raw big-endian .bin or .md ROM.")
        }
        guard data.count.isMultiple(of: 2) else { throw FlashMDError.invalid("The ROM has an odd byte count and cannot be programmed as 16-bit data.") }
        metadata = try ROMMetadata.parse(data)
        var checksum: UInt16 = 0
        for offset in stride(from: 0x200, to: data.count, by: 2) { checksum &+= UInt16(data[offset]) << 8 | UInt16(data[offset+1]) }
        self.checksum = checksum; self.data = data; self.sha256 = hash(data)
        var warnings = [String]()
        if metadata.declaredROMBytes != data.count { warnings.append("The header length differs from the file length.") }
        if checksum != metadata.storedChecksum { warnings.append("The header checksum does not match the game data (common with patched ROMs).") }
        if let warning = metadata.saveWarning { warnings.append(warning) }
        self.warnings = warnings
    }
    public init(url: URL) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let length = values.fileSize, length <= 16 * 1024 * 1024 else { throw FlashMDError.invalid("Select a regular ROM file no larger than 16 MiB.") }
        try self.init(data: Data(contentsOf: url))
    }
}
public func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
