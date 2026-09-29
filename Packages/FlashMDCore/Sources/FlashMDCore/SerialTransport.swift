import Foundation
import Darwin
import IOKit

public struct SerialPort: Sendable, Hashable, Identifiable, Codable {
    public let path: String
    public let name: String
    public var id: String { path }
    public init(path: String, name: String) { self.path = path; self.name = name }
    public static func discover() -> [SerialPort] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOSerialBSDClient"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var ports = [SerialPort]()
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let path = IORegistryEntryCreateCFProperty(service, "IOCalloutDevice" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
               path.hasPrefix("/dev/cu.usb") {
                let vendor = IORegistryEntrySearchCFProperty(service, kIOServicePlane, "USB Product Name" as CFString, kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)) as? String
                ports.append(.init(path: path, name: vendor ?? URL(fileURLWithPath: path).lastPathComponent))
            }
            IOObjectRelease(service); service = IOIteratorNext(iterator)
        }
        return ports.sorted { $0.path < $1.path }
    }
}

public protocol ByteTransport: AnyObject, Sendable {
    func write(_ data: Data, timeout: TimeInterval) throws
    func read(count: Int, timeout: TimeInterval, cancellable: Bool) throws -> Data
    func close()
}

// The owning cartridge actor is the sole caller; no descriptor is exposed to the UI.
public final class SerialTransport: ByteTransport, @unchecked Sendable {
    private var fd: Int32 = -1
    public init(path: String) throws {
        guard path.hasPrefix("/dev/cu."), !path.contains("..") else { throw FlashMDError.invalid("Select a macOS callout serial port.") }
        fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw errno == EBUSY ? FlashMDError.busy : FlashMDError.invalid("Cannot open \(path): \(String(cString: strerror(errno))).") }
        do {
            guard ioctl(fd, UInt(TIOCEXCL)) == 0 else { throw FlashMDError.busy }
            var config = termios()
            guard tcgetattr(fd, &config) == 0 else { throw FlashMDError.disconnected }
            cfmakeraw(&config)
            config.c_cflag |= tcflag_t(CLOCAL | CREAD)
            config.c_cflag &= ~tcflag_t(PARENB | CSTOPB | CSIZE)
            config.c_cflag |= tcflag_t(CS8)
            cfsetspeed(&config, speed_t(B9600))
            guard tcsetattr(fd, TCSANOW, &config) == 0 else { throw FlashMDError.disconnected }
            tcflush(fd, TCIOFLUSH)
        } catch { close(); throw error }
    }
    // Takes ownership of an already configured descriptor; used by syscall-level transport tests.
    init(ownedDescriptor: Int32) { fd = ownedDescriptor }
    deinit { close() }
    public func close() { if fd >= 0 { Darwin.close(fd); fd = -1 } }
    private func wait(_ events: Int16, deadline: Date, cancellable: Bool) throws {
        while true {
            if cancellable { try Task.checkCancellation() }
            guard fd >= 0 else { throw FlashMDError.disconnected }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw FlashMDError.timeout }
            var item = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&item, 1, Int32(min(remaining * 1000, 50)))
            if result < 0 { if errno == EINTR { continue }; throw FlashMDError.disconnected }
            if item.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { throw FlashMDError.disconnected }
            if result > 0, item.revents & events != 0 { return }
        }
    }
    public func write(_ data: Data, timeout: TimeInterval = 2) throws {
        let deadline = Date().addingTimeInterval(timeout)
        var offset = 0
        while offset < data.count {
            // Finish emitting an entire protocol packet once it has started.
            try wait(Int16(POLLOUT), deadline: deadline, cancellable: false)
            let count = data.withUnsafeBytes { bytes in Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), data.count - offset) }
            if count < 0 { if errno == EAGAIN || errno == EINTR { continue }; throw FlashMDError.disconnected }
            guard count > 0 else { throw FlashMDError.disconnected }; offset += count
        }
    }
    public func read(count: Int, timeout: TimeInterval = 2, cancellable: Bool = true) throws -> Data {
        guard count >= 0, count <= 0x10000 else { throw FlashMDError.invalid("Invalid serial read length.") }
        var output = Data(count: count), offset = 0
        let deadline = Date().addingTimeInterval(timeout)
        while offset < count {
            try wait(Int16(POLLIN), deadline: deadline, cancellable: cancellable)
            let received = output.withUnsafeMutableBytes { bytes in Darwin.read(fd, bytes.baseAddress!.advanced(by: offset), count-offset) }
            if received < 0 { if errno == EAGAIN || errno == EINTR { continue }; throw FlashMDError.disconnected }
            guard received > 0 else { throw FlashMDError.disconnected }; offset += received
        }
        return output
    }
}
