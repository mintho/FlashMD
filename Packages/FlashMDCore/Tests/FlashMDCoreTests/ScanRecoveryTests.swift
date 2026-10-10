import Foundation
import Testing
@testable import FlashMDCore

private final class ScanWireDevice: CartridgeDevice, @unchecked Sendable {
    enum Fault { case none, mismatch, timeout, cancel, cleanup, save, mapper }
    let identity = "scan-test reader"
    let kind: ProgrammerKind
    var fault: Fault
    var rom = fixtureROM(save:false)
    var closed = false
    var readOffsets: [Int] = []
    var resets = 0
    init(_ fault: Fault, kind: ProgrammerKind = .mdDumper) { self.fault = fault; self.kind = kind }
    func inspect(profile: CartridgeProfile) throws -> CartridgeSnapshot {
        if fault == .save { throw FlashMDError.invalid("SRAM reads did not match. No save file was created.") }
        if fault == .mapper { throw FlashMDError.invalid("ROM mapping could not be restored. Unplug USB before continuing.") }
        let metadata = try ROMMetadata.parse(rom)
        return .init(title:metadata.title,regions:[],romSize:.init(bytes:rom.count,source:.header),
            flashCapacity:.init(bytes:rom.count,source:.estimated),rawSaveWindow:nil,metadata:metadata,
            identity:identity,fingerprint:hash(Data(rom.prefix(512))),readerKind:kind,saveStatus:SaveMemoryStatus.none)
    }
    func readROM(offset: Int, count: Int) throws -> Data {
        #expect(!closed); readOffsets.append(offset)
        if fault == .timeout { throw FlashMDError.timeout }
        if fault == .cancel { throw CancellationError() }
        return Data(rom[offset..<offset+count])
    }
    func readROMForVerification(offset: Int, count: Int) throws -> Data {
        var data = try readROM(offset:offset,count:count)
        if offset == 0x8000, fault == .mismatch || fault == .cleanup { data[0] ^= 1 }
        return data
    }
    func reset() throws {
        resets += 1
        if fault == .cleanup { throw FlashMDError.invalid("Mapper state is uncertain") }
    }
    func close() { closed = true }
    func readSRAM(layout: SRAMLayout, offset: Int, count: Int) throws -> Data { throw FlashMDError.invalid("Unexpected save read") }
    func erase(sector: FlashSector) throws { Issue.record("Scan must never erase memory") }
    func program(offset: Int, data: Data) throws { Issue.record("Scan must never program memory") }
    func restore(layout: SRAMLayout, raw: Data) throws { Issue.record("Scan must never write saves") }
}

private final class ScanConnections: @unchecked Sendable {
    let devices: [ScanWireDevice]
    var opens = 0
    var streaming: [Bool] = []
    init(_ devices: [ScanWireDevice]) { self.devices = devices }
    func open(_ path: String, _ mode: Bool) throws -> any CartridgeDevice {
        guard opens < devices.count else { throw FlashMDError.invalid("Unexpected extra connection") }
        if opens > 0 { #expect(devices[opens-1].closed) }
        streaming.append(mode); defer { opens += 1 }; return devices[opens]
    }
    var controller: ProgrammerController { ProgrammerController(makeDevice:{ [self] path, mode in try open(path,mode) }) }
}

private func scanPath(_ kind: ProgrammerKind) -> String { kind == .mdDumper ? "md-dumper:123" : "/dev/test" }

@Test(arguments:[1,2],[ProgrammerKind.flashKit,.mdDumper])
func scanRecoversWithFreshFullyVerifiedAttempt(failedAttempts: Int, kind: ProgrammerKind) async throws {
    let devices = (0..<failedAttempts).map { _ in ScanWireDevice(.mismatch,kind:kind) } + [ScanWireDevice(.none,kind:kind)]
    let connections = ScanConnections(devices), controller = connections.controller
    let result = try await controller.scan(path:scanPath(kind),profile:.automatic,mdDumperStreaming:kind == .mdDumper,progress:{_ in})
    #expect(connections.opens == failedAttempts+1)
    #expect(connections.streaming == [kind == .mdDumper] + Array(repeating:false,count:failedAttempts))
    #expect(result.analysis?.sha256 == hash(devices.last!.rom))
    #expect(result.analysis?.scannedBytes == 65536)
    #expect(result.failures.count == failedAttempts)
    for failure in result.failures {
        #expect(failure.phase == "analyzing ROM")
        #expect(failure.mismatch?.differences.first?.offset == 0x8000)
        #expect(failure.mismatch?.firstSHA256 != failure.mismatch?.secondSHA256)
    }
    #expect(devices.last!.readOffsets == [0,0,0x8000,0x8000])
    #expect(devices.dropLast().allSatisfy { $0.resets == 1 && $0.closed })
    try await controller.disconnect()
}

@Test(arguments:[ProgrammerKind.flashKit,.mdDumper])
func scanStopsAfterThreeUnreliableAttempts(kind: ProgrammerKind) async throws {
    let connections = ScanConnections((0..<3).map { _ in ScanWireDevice(.mismatch,kind:kind) })
    let controller = connections.controller
    do {
        _ = try await controller.scan(path:scanPath(kind),profile:.automatic,progress:{_ in})
        Issue.record("Unverified scans must never be accepted")
    } catch let error as CartridgeScanFailure {
        #expect(error.failures.count == 3)
        #expect(error.localizedDescription.contains("after three scans"))
        #expect(error.failures.allSatisfy { $0.mismatch?.differences.first?.offset == 0x8000 })
    }
    #expect(connections.opens == 3 && connections.devices.allSatisfy { $0.closed })
}

@Test(arguments:[ScanWireDevice.Fault.timeout,.cancel,.cleanup,.save,.mapper],[ProgrammerKind.flashKit,.mdDumper])
private func scanDoesNotRetryTransportCancellationUncertainCleanupSaveOrMapperFailures(fault: ScanWireDevice.Fault, kind: ProgrammerKind) async throws {
    let connections = ScanConnections([ScanWireDevice(fault,kind:kind),ScanWireDevice(.none,kind:kind)])
    await #expect(throws:CartridgeScanFailure.self) {
        try await connections.controller.scan(path:scanPath(kind),profile:.automatic,progress:{_ in})
    }
    #expect(connections.opens == 1 && connections.devices[0].closed)
}

@Test(arguments:[ProgrammerKind.flashKit,.mdDumper])
func scanRecoveryRejectsChangedCartridge(kind: ProgrammerKind) async throws {
    let next = ScanWireDevice(.none,kind:kind); next.rom[0x120] = 65
    let connections = ScanConnections([ScanWireDevice(.mismatch,kind:kind),next,ScanWireDevice(.none,kind:kind)])
    do {
        _ = try await connections.controller.scan(path:scanPath(kind),profile:.automatic,progress:{_ in})
        Issue.record("Changed cartridge must stop recovery")
    } catch let error as CartridgeScanFailure {
        #expect(error.localizedDescription == "The cartridge changed. Scan again.")
    }
    #expect(connections.opens == 2 && next.closed && next.readOffsets.isEmpty)
}
