import Foundation
import USBBridge

public enum ProgrammerKind: String, Codable, Sendable {
    case flashKit, mdDumper
    public var displayName: String { self == .flashKit ? "FlashKit" : "MD Dumper" }
}

public struct ProgrammerEndpoint: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let kind: ProgrammerKind
    public init(id: String, name: String, kind: ProgrammerKind) {
        self.id = id; self.name = name; self.kind = kind
    }
    public static func discover() -> [Self] {
        var locations = [UInt32](repeating: 0, count: 32)
        let count = locations.withUnsafeMutableBufferPointer { fm_usb_discover($0.baseAddress, $0.count) }
        let usb = locations.prefix(min(count, locations.count)).map {
            Self(id:"md-dumper:\($0)", name:"MD Dumper · USB \(String($0,radix:16).uppercased())",kind:.mdDumper)
        }
        return usb + SerialPort.discover().map { Self(id:$0.path,name:$0.name,kind:.flashKit) }
    }
}

// Synchronous transfers are owned by ProgrammerController, never by the main actor.
public final class MDDumperUSBTransport: ByteTransport, @unchecked Sendable {
    private var handle: OpaquePointer?
    public init(location: UInt32) throws {
        var status: Int32 = 0
        handle = fm_usb_open(location, &status)
        guard handle != nil else { throw Self.error(status) }
    }
    deinit { close() }
    public func close() { if let handle { fm_usb_close(handle); self.handle = nil } }
    private static func error(_ status: Int32) -> FlashMDError {
        switch UInt32(bitPattern:status) {
        case 0xe00002d6, 0xe0004051: return .timeout
        case 0xe00002c5: return .busy
        case 0xe00002c0, 0xe00002cd, 0xe00002ed: return .disconnected
        default: return .invalid("Cannot access MD Dumper USB (\(String(UInt32(bitPattern:status),radix:16))). Close other dumper apps and reconnect USB.")
        }
    }
    public func write(_ data: Data, timeout: TimeInterval) throws {
        guard let handle else { throw FlashMDError.disconnected }
        guard data.count == 64 else { throw FlashMDError.invalid("Invalid MD Dumper USB packet.") }
        let status = data.withUnsafeBytes { fm_usb_write(handle,$0.bindMemory(to:UInt8.self).baseAddress,UInt32(data.count),UInt32(max(1,timeout * 1000))) }
        guard status == 0 else { throw Self.error(status) }
    }
    public func read(count: Int, timeout: TimeInterval, cancellable: Bool) throws -> Data {
        guard let handle else { throw FlashMDError.disconnected }
        guard count == 64 else { throw FlashMDError.invalid("Invalid MD Dumper USB read length.") }
        if cancellable { try Task.checkCancellation() }
        var data = Data(count:count), length = UInt32(count)
        let status = data.withUnsafeMutableBytes { fm_usb_read(handle,$0.bindMemory(to:UInt8.self).baseAddress,&length,UInt32(max(1,timeout * 1000))) }
        guard status == 0 else { throw Self.error(status) }
        guard length == count else { throw FlashMDError.invalid("Incomplete MD Dumper reply. Reconnect USB.") }
        return data
    }
}
