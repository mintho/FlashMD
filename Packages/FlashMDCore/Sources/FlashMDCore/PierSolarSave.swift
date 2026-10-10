import Foundation

/// A serial address envelope, not a claim about the physical chip's capacity.
/// Repeated or erased bytes cannot prove a smaller chip is fitted.
public struct SerialSaveConfiguration: Codable, Sendable, Equatable {
    public enum ProtocolKind: String, Codable, Sendable { case pierSolarSPI }
    public let kind: ProtocolKind
    public let addressBytes: Int
    public static let pierSolar = Self(kind:.pierSolarSPI,addressBytes:65536)
    public var displayName: String { "SPI save memory" }
}

struct PierSolarSaveProbe: Codable, Sendable {
    struct Sample: Codable, Sendable {
        let offset: Int
        let data: Data
    }
    let status: UInt8
    let samples: [Sample]
}

/// Independently implemented serial read protocol. The only possible opcodes
/// are READ and READ STATUS. Control writes affect pins, never the memory array.
/// Each transaction starts/ends with CS high; failed transactions are not retried.
final class PierSolarSPIReader {
    static let controlAddress = 0xA13009
    static let dataAddress = 0xA1300B
    private let setPins: (UInt8) throws -> Void
    private let readPin: () throws -> UInt8
    private let clockReadBytes: ((Int) throws -> Data)?
    private let checkCancellation: () throws -> Void

    init(setPins: @escaping (UInt8) throws -> Void, readPin: @escaping () throws -> UInt8,
         clockReadBytes: ((Int) throws -> Data)? = nil,
         checkCancellation: @escaping () throws -> Void = { try Task.checkCancellation() }) {
        self.setPins = setPins; self.readPin = readPin; self.clockReadBytes = clockReadBytes; self.checkCancellation = checkCancellation
    }
    func deselect() throws { try setPins(0x0C) }
    private func sendByte(_ value: UInt8) throws {
        for bit in stride(from:7,through:0,by:-1) {
            let pins = UInt8(4) | ((value >> bit) & 1)
            try setPins(pins); try setPins(pins | 2)
        }
    }
    private func receiveByte() throws -> UInt8 {
        if let clockReadBytes {
            let data = try clockReadBytes(1)
            guard data.count == 1 else { throw FlashMDError.invalid("Incomplete SPI byte.") }
            return data[0]
        }
        var byte: UInt8 = 0
        for _ in 0..<8 {
            try setPins(4); try setPins(6)
            byte = (byte << 1) | (try readPin() & 1)
        }
        return byte
    }
    private func transaction<T>(_ work: () throws -> T) throws -> T {
        let result: Result<T, any Error>
        do {
            try checkCancellation(); try deselect()
            // SO is high impedance while CS is high. Its idle value is not
            // evidence of successful selection or cleanup on real hardware.
            try setPins(4)
            result = .success(try work())
        } catch { result = .failure(error) }
        // No cancellation check here: CS must be released even on cancellation.
        try deselect()
        return try result.get()
    }
    func readStatus() throws -> UInt8 {
        try transaction {
            try sendByte(0x05)
            let status = try receiveByte()
            // Reserved status bits cannot all be high. Busy EEPROM is not a
            // stable snapshot; do not wait/retry on a save transaction in progress.
            guard status & 0x70 == 0, status & 3 == 0 else {
                throw FlashMDError.invalid("SPI save memory returned an invalid or busy status (\(String(format:"%02X",status))). No save file was created.")
            }
            return status
        }
    }
    func read(offset: Int, count: Int) throws -> Data {
        guard offset >= 0, count >= 0, offset <= 65536, count <= 65536-offset else {
            throw FlashMDError.invalid("Invalid SPI save range.")
        }
        if count == 0 { return Data() }
        return try transaction {
            try sendByte(0x03)
            try sendByte(UInt8(truncatingIfNeeded:offset >> 8))
            try sendByte(UInt8(truncatingIfNeeded:offset))
            var data = Data()
            while data.count < count {
                try checkCancellation()
                if let clockReadBytes {
                    let length = min(4,count-data.count)
                    let bytes = try clockReadBytes(length)
                    guard bytes.count == length else { throw FlashMDError.invalid("Incomplete SPI bytes.") }
                    data.append(bytes)
                } else { data.append(try receiveByte()) }
            }
            return data
        }
    }
    /// Check status and repeated data without writing a test pattern.
    /// Blank data cannot distinguish a fitted memory from a disconnected bus.
    func probe() throws -> PierSolarSaveProbe {
        let status = try readStatus()
        guard try readStatus() == status else { throw FlashMDError.invalid("SPI status readings differed. No save file was created.") }
        var samples: [PierSolarSaveProbe.Sample] = []
        for offset in [0,0x7F0,0x1FF0,0x7FF0,0xFFF0] {
            let first = try read(offset:offset,count:16)
            guard try read(offset:offset,count:16) == first else { throw FlashMDError.invalid("SPI save readings differed at \(String(format:"%04X",offset)). No save file was created.") }
            samples.append(.init(offset:offset,data:first))
        }
        let bytes = samples.reduce(into:Data()) { $0.append($1.data) }
        guard !SaveMemoryProbe.isBlank(bytes) else { throw FlashMDError.invalid("SPI samples are blank; save memory access could not be confirmed. No save file was created.") }
        guard try readStatus() == status else { throw FlashMDError.invalid("SPI status changed during reading. No save file was created.") }
        return .init(status:status,samples:samples)
    }
}

/// Reader access has to be qualified on actual hardware before ordinary scans
/// may touch this interface. Diagnostic tests explicitly opt in per session.
enum PierSolarSaveSupport {
    // Four matching full captures, emulator save-menu proof and console check.
    static let flashKitQualified = true
    static let mdDumperQualified = false
}
