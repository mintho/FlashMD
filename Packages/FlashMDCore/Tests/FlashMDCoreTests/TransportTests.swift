import Foundation
import Testing
import Darwin
@testable import FlashMDCore
final class ScriptTransport: ByteTransport, @unchecked Sendable {
    var responses:[Data]
    var writes = [Data]()
    var closed = false
    init(_ responses:[Data]) { self.responses = responses }
    func write(_ data:Data,timeout:TimeInterval) throws { writes.append(data) }
    func read(count:Int,timeout:TimeInterval,cancellable:Bool) throws -> Data {
        guard !responses.isEmpty else { throw FlashMDError.timeout }; let next = responses.removeFirst()
        guard next.count == count else { throw FlashMDError.invalid("Short scripted response") }; return next
    }
    func close() { closed = true }
}
@Test func handshakeRejectsNonFlashKitAndClosesPort() {
    let transport = ScriptTransport([Data([1,2])])
    #expect(throws:(any Error).self) { try FlashKitDevice(transport:transport,path:"test") }
    #expect(transport.closed); #expect(transport.writes.first == Data([0x62]))
}
@Test func packetReadReturnsExactUnalignedLength() throws {
    let transport = ScriptTransport([Data([1,1]),Data([10,11,12,13,14,15])])
    let device = try FlashKitDevice(transport:transport,path:"test")
    let result = try device.readROM(offset:1,count:5)
    #expect(result == Data([11,12,13,14,15]))
    #expect(transport.writes.contains(Data([1,0,1,3,0x82])))
}
@Test(.enabled(if:ProcessInfo.processInfo.environment["FLASHMD_HARDWARE"] == "1"))
func hardwareInspection() async throws {
    let controller = ProgrammerController(), ports = await controller.ports()
    let port = try #require(ports.first { $0.path == "/dev/cu.usbserial-AE01JVAH" })
    try await controller.connect(path:port.path)
    let snapshot = try await controller.inspect(profile:.automatic)
    #expect(!snapshot.identity.isEmpty); #expect(snapshot.metadata != nil)
    #expect(snapshot.geometry?.capacity == 0x800000); #expect(snapshot.flashCapacity?.bytes == 0x200000)
    #expect(snapshot.geometry?.supported == true); #expect(snapshot.canWrite)
    try await controller.disconnect()
}

private func socketTransport() throws -> (SerialTransport, Int32) {
    var descriptors: [Int32] = [-1,-1]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else { throw FlashMDError.invalid("Cannot create test transport") }
    _ = fcntl(descriptors[0], F_SETFL, O_NONBLOCK)
    return (SerialTransport(ownedDescriptor: descriptors[0]), descriptors[1])
}
@Test func nativeTransportCollectsFragmentedReplies() async throws {
    let (transport, peer) = try socketTransport()
    defer { transport.close(); Darwin.close(peer) }
    let sender = Task.detached {
        for value in UInt8(1)...UInt8(6) {
            var byte = value
            _ = withUnsafePointer(to: &byte) { Darwin.write(peer, $0, 1) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    let bytes = try transport.read(count:6,timeout:1,cancellable:true)
    try await sender.value
    #expect(bytes == Data([1,2,3,4,5,6]))
}
@Test func nativeTransportBoundsTimeoutAndDisconnect() throws {
    let (transport, peer) = try socketTransport()
    defer { transport.close() }
    #expect(throws:FlashMDError.timeout) { try transport.read(count:1,timeout:0.03,cancellable:true) }
    Darwin.close(peer)
    #expect(throws:FlashMDError.disconnected) { try transport.read(count:1,timeout:0.3,cancellable:true) }
    transport.close()
    #expect(throws:FlashMDError.disconnected) { try transport.write(Data([1]),timeout:0.1) }
}
private final class ReceivedBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ bytes: Data) { lock.lock(); defer { lock.unlock() }; data.append(bytes) }
    func value() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}
@Test func nativeTransportCompletesWritesUnderBackPressure() throws {
    let (transport, peer) = try socketTransport()
    defer { transport.close(); Darwin.close(peer) }
    let payload = Data(repeating:0x77,count:262144), received = ReceivedBytes(), finished = DispatchGroup()
    finished.enter()
    DispatchQueue.global().async {
        defer { finished.leave() }
        var buffer = [UInt8](repeating:0,count:4096), count = 0
        while count < payload.count {
            let length = buffer.withUnsafeMutableBytes { Darwin.read(peer,$0.baseAddress!, $0.count) }
            guard length > 0 else { return }
            received.append(Data(buffer.prefix(length))); count += length
        }
    }
    try transport.write(payload,timeout:3)
    #expect(finished.wait(timeout:.now()+3) == .success)
    #expect(received.value() == payload)
}
@Test(.enabled(if:ProcessInfo.processInfo.environment["FLASHMD_BACKUP_TEST"] != nil))
func hardwareVerifiedROMBackup() async throws {
    let controller = ProgrammerController()
    try await controller.connect(path:"/dev/cu.usbserial-AE01JVAH")
    let snapshot = try await controller.inspect(profile:.automatic)
    let destination = URL(fileURLWithPath:ProcessInfo.processInfo.environment["FLASHMD_BACKUP_TEST"]!,isDirectory:true)
    let request = try BackupRequest(cartridge:snapshot,romBytes:snapshot.romSize?.bytes,saveLayout:nil,verify:true,destination:destination)
    let result = try await controller.backup(request,progress:{_ in})
    #expect(result.manifest.outcome == "completed")
    #expect(result.manifest.artifacts.first?.verified == true)
    try await controller.disconnect()
}

@Test(.enabled(if:ProcessInfo.processInfo.environment["FLASHMD_SAVE_BACKUP_TEST"] != nil))
func hardwareVerifiedSRAMBackups() async throws {
    let controller = ProgrammerController()
    try await controller.connect(path:"/dev/cu.usbserial-AE01JVAH")
    let snapshot = try await controller.inspect(profile:.krikzz4M)
    let layout = try #require(snapshot.saveLayout)
    let destination = URL(fileURLWithPath:ProcessInfo.processInfo.environment["FLASHMD_SAVE_BACKUP_TEST"]!,isDirectory:true)
    for format in SaveFormat.allCases {
        let request = try BackupRequest(cartridge:snapshot,romBytes:nil,saveLayout:layout,saveFormat:format,verify:true,destination:destination)
        let result = try await controller.backup(request,progress:{_ in})
        #expect(result.manifest.outcome == "completed")
        #expect(result.manifest.artifacts.first?.bytes == (format == .raw ? 65536 : 32768))
        #expect(result.manifest.artifacts.first?.verified == true)
    }
    try await controller.disconnect()
}

@Test func nativeProgrammingUsesBufferedWordPacketsAndExitsBypass() throws {
    let transport = ScriptTransport([Data([1,1]),Data([0xFF,0xFF])])
    let device = try FlashKitDevice(transport:transport,path:"test")
    try device.program(offset:0x10000,data:Data([0x12,0x34,0x56,0x78]))
    #expect(transport.writes.contains(Data([0x53,0xA0,0xC3,0x12,0x34,4,0x53,0xA0,0xC3,0x56,0x78,4])))
    #expect(transport.writes.contains(Data([0x53,0x90])))
    #expect(transport.writes.contains(Data([0x43,0,0xF0])))
}
@Test func nativeSaveRestoreUsesOnlyOddLaneByteWrites() throws {
    let transport = ScriptTransport([Data([1,1])])
    let device = try FlashKitDevice(transport:transport,path:"test")
    let layout = try SRAMLayout(start:0x200001,end:0x200003,lane:1)
    try device.restore(layout:layout,raw:Data([0xFF,0x12,0xFF,0x34]))
    #expect(transport.writes.last == Data([0,0x10,0,0,0,0,0x53,0x12,0,0x10,0,0,0,1,0x53,0x34]))
    let even = try SRAMLayout(start:0x200000,end:0x200002,lane:0)
    #expect(throws:(any Error).self) { try device.restore(layout:even,raw:Data(count:4)) }
}
