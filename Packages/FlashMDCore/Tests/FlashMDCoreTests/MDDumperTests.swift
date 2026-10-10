import Foundation
import Testing
@testable import FlashMDCore

/// Models only wire behavior: slow ROM reads return 64 bytes, SRAM reads 64
/// odd-lane bytes, SRAM writes carry 32 bytes and wait for an acknowledgement.
private final class DumperWire: ByteTransport, @unchecked Sendable {
    var commands: [Data] = []
    var pending: Data?
    var closed = false
    var poweredOff = false
    var ready = Data(repeating:0,count:64)
    var flashID: (UInt8,UInt8) = (0,0)
    var identificationMode = false
    var leaveIdentificationMode = false
    var identificationWords: [Int: UInt16] = [:]
    var eraseReadTimeouts = 0
    var eraseReadFailure: FlashMDError?
    var rom: Data
    var save = Data((0..<32768).map { UInt8(truncatingIfNeeded:$0 * 7) })
    var page = 4
    var ignoresBanks = false
    var wrapBanks = false
    var shortReply = false
    var statusValue: UInt8 = 0xAA
    var programAcknowledgement: UInt8? = 0xDD
    var clearsProgrammingStatusAfterReply = false
    var streamAddress: Int?
    var staleAfterStop: Data?
    var streamingFailure: Error?
    var shortStream = false
    var corruptStream = false
    var neverStops = false
    var pier = false
    var saveControl: UInt8 = 0
    var ignoresSaveControl = false
    var ignoresSaveDisable = false
    var saveReadFailure: Error?
    var cancelOnSaveRead = false
    var saveEnables = 0
    var corruptSaveReplyOnEnable: Int?
    var saveReplyUsesROM = false
    var unstableEvenLaneFrom: Int?
    var alwaysVisibleSave = false
    var floatingVisibleLane = false
    var visibleLaneResidueBytes = 1
    var visibleLaneResidue: UInt8 = 0x40
    var changingVisibleLaneResidue = true
    var mirroredVisibleSave = false
    var readCounts: [Int:Int] = [:]
    var cancelOnROMReadFrom: Int?
    var pendingROMAddress: Int?
    init(banked: Bool = false) {
        ready.replaceSubrange(0..<6,with:Data("READY!".utf8))
        ready[20] = 2; ready[21] = 0; ready[24] = 3
        if banked {
            rom = Data()
            for bank in 0..<10 { rom.append(Data(repeating:UInt8(bank+10),count:0x80000)) }
            var header = Data(fixtureROM(save:false).prefix(512))
            header.replaceSubrange(0x100..<0x110,with:Data("SEGA SSF        ".utf8))
            header[0x1A4] = 0; header[0x1A5] = 0x4F; header[0x1A6] = 0xFF; header[0x1A7] = 0xFF
            rom.replaceSubrange(0..<512,with:header)
        } else { rom = fixtureROM() + Data(repeating:0xFF,count:0x400000-65536) }
    }
    func write(_ data: Data, timeout: TimeInterval) throws {
        #expect(data.count == 64)
        #expect(pending == nil)
        commands.append(data)
        let address = (Int(data[1]) | Int(data[2]) << 8 | Int(data[3]) << 16) * 2
        switch data[0] {
        case 0x10: pending = ready
        case 0x11:
            if data[4] == 1 { streamAddress = address }
            else {
                if streamAddress != nil {
                    staleAfterStop = Data(repeating:0xA5,count:64)
                    if !neverStops { streamAddress = nil }
                }
                pending = bus(address:address,count:64)
                pendingROMAddress = address
            }
        case 0x18:
            identificationMode = leaveIdentificationMode
            var result = Data(repeating:0,count:64); result[1] = flashID.0; result[3] = flashID.1; pending = result
        case 0x20:
            if address == 0xA130F0 {
                #expect(data[5] == 0 || data[5] == 3) // Read-only SRAM; never write-enable.
                if data[5] == 3 { saveEnables += 1 }
                if !ignoresSaveControl && !(ignoresSaveDisable && data[5] == 0) { saveControl = data[5] }
            } else {
                #expect(address == (pier ? 0xA13002 : 0xA130F8)) // Word address encoding.
                if !ignoresBanks { page = Int(data[5]) & (wrapBanks ? 7 : 63) }
            }
        case 0x12:
            saveControl = 3
            let base = (address-0x200000)/2
            pending = saveReplyUsesROM ? Data(stride(from:address+1,to:address+128,by:2).map { rom[$0] }) : Data(save[base..<base+64])
        case 0x13:
            saveControl = 3
            #expect(data[7] == 0xCC) // Never blanket-erase SRAM.
            let base = (address-0x200000)/2
            save.replaceSubrange(base..<base+32,with:data[32..<64])
            var ack = Data(repeating:0,count:64); ack[6] = statusValue; pending = ack
        case 0x15:
            rom = Data(repeating:0xFF,count:rom.count)
            var ack = Data(repeating:0,count:64); ack[0] = 0xFF; pending = ack
        case 0x65:
            var ack = Data(repeating:0,count:64); ack[6] = 0xDD; pending = ack
        case 0x14:
            let length = Int(data[4]); #expect(length > 0 && length <= 54 && length % 2 == 0)
            rom.replaceSubrange(address..<address+length,with:data[5..<5+length])
            if let programAcknowledgement {
                var ack = Data(repeating:0,count:64); ack[6] = programAcknowledgement; pending = ack
                if clearsProgrammingStatusAfterReply { self.programAcknowledgement = 0 }
            }
        default: Issue.record("Unexpected command \(data[0])")
        }
    }
    func read(count: Int, timeout: TimeInterval, cancellable: Bool) throws -> Data {
        if commands.last?.first == 0x15 {
            if eraseReadTimeouts > 0 { eraseReadTimeouts -= 1; throw FlashMDError.timeout }
            if let failure = eraseReadFailure { eraseReadFailure = nil; throw failure }
        }
        if let staleAfterStop { self.staleAfterStop = nil; return staleAfterStop }
        if let pending {
            self.pending = nil
            if let address = pendingROMAddress {
                pendingROMAddress = nil
                if let limit = cancelOnROMReadFrom, address >= limit {
                    cancelOnROMReadFrom = nil; withUnsafeCurrentTask { $0?.cancel() }
                }
            }
            if saveControl == 3 {
                if let saveReadFailure { self.saveReadFailure = nil; throw saveReadFailure }
                if cancelOnSaveRead { cancelOnSaveRead = false; withUnsafeCurrentTask { $0?.cancel() } }
            }
            return shortReply ? Data(pending.prefix(63)) : pending
        }
        if let address = streamAddress {
            if let streamingFailure { self.streamingFailure = nil; throw streamingFailure }
            let length = shortStream ? min(count,64) : count
            var result = bus(address:address,count:length)
            if corruptStream { result[0] ^= 1 }
            streamAddress = address + length
            return result
        }
        throw FlashMDError.timeout
    }
    private func bus(address: Int, count: Int) -> Data {
        if identificationMode {
            var result = Data(repeating:0x7E,count:count)
            for (offset,word) in identificationWords where offset >= address && offset+1 < address+count {
                result[offset-address] = UInt8(truncatingIfNeeded:word >> 8)
                result[offset-address+1] = UInt8(truncatingIfNeeded:word)
            }
            return result
        }
        if saveControl == 3 || alwaysVisibleSave, (0x200000..<(mirroredVisibleSave ? 0x400000 : 0x210000)).contains(address) {
            var data = Data(repeating:0xFF,count:count)
            for offset in 0..<count {
                let busAddress = address + offset
                if busAddress & 1 == 1 {
                    let saveIndex = ((busAddress - 0x200000) % 0x10000) / 2
                    data[offset] = save[saveIndex]
                }
            }
            if floatingVisibleLane, address.isMultiple(of:512) {
                readCounts[address,default:0] += 1
                let residue = changingVisibleLaneResidue && readCounts[address,default:0].isMultiple(of:2) ? UInt8(0) : visibleLaneResidue
                for index in stride(from:0,to:min(count,visibleLaneResidueBytes*2),by:2) { data[index] = residue }
            }
            if corruptSaveReplyOnEnable == saveEnables, address == 0x200000 { data[1] ^= 1 }
            return data
        }
        let window = pier ? 0x280000 : 0x200000
        let logical = (window..<window+0x80000).contains(address) && rom.count > 0x400000 ? page*0x80000+address-window : address
        var output = Data(repeating:0xFF,count:count)
        if logical < rom.count {
            let available = min(count,rom.count-logical)
            output.replaceSubrange(0..<available,with:rom[logical..<logical+available])
        }
        if let unstableEvenLaneFrom, address >= unstableEvenLaneFrom {
            readCounts[address,default:0] += 1
            output[0] ^= UInt8(truncatingIfNeeded:readCounts[address,default:0])
        }
        return output
    }
    func close() { closed = true }
    func device(streaming: Bool = false) throws -> MDDumperDevice { try MDDumperDevice(transport:self,location:"test-usb",streaming:streaming) }
}

@Test func mdDumperROMOnlyConfirmationDiscardsPreparationForTheOldSaveLimitedRange() async throws {
    let wire = DumperWire(); wire.flashID = (0x20,0xED)
    wire.save = Data(repeating:0xFF,count:32768)
    let originalROM = wire.rom, originalSave = wire.save
    let controller = ProgrammerController(makeDevice:{ _,_ in try wire.device() })
    try await controller.connect(path:"md-dumper:123")
    let scanned = try await controller.inspect(profile:.automatic)
    #expect(scanned.canConfirmNoSRAMForROMWriting && scanned.romWriteAddressLimit == 0x200000)
    // Reproduce a preparation completed before the user resolves the stale header.
    try await controller.prepareMDDumperROMWriting(scanned,progress:{_ in})
    let prepared = try await controller.continueMDDumperROMWriting(profile:.automatic,progress:{_ in})
    #expect(prepared.canWrite && prepared.romWriteLimit == 0x200000)
    let configured = try await controller.confirmROMOnlyCartridge(prepared)
    #expect(configured.geometry == nil && !configured.canWrite)
    #expect(configured.romWriteAddressLimit == 0x400000 && configured.hasExplicitROMOnlyConfiguration)
    #expect(wire.commands.filter { $0[0] == 0x18 }.count == 1)
    try await controller.prepareMDDumperROMWriting(configured,progress:{_ in})
    let ready = try await controller.continueMDDumperROMWriting(profile:configured.profile,
        override:configured.configurationOverride,progress:{_ in})
    #expect(ready.canWrite && ready.romWriteLimit == 0x400000 && ready.saveLayout == nil)
    #expect(wire.commands.filter { $0[0] == 0x18 }.count == 2)
    #expect(!wire.commands.contains { [UInt8(0x13),0x14,0x15,0x65].contains($0[0]) })
    #expect(wire.rom == originalROM && wire.save == originalSave)
}

@Test func mdDumperSoleilFloatingUnusedLaneKeepsTwoMiBROMAndEightKiBSave() throws {
    let wire = DumperWire(), destination = try tempFolder()
    defer { try? FileManager.default.removeItem(at:destination) }
    wire.rom = fixtureROM(bytes:0x200000,title:"SOLEIL") + Data(repeating:0xFF,count:0x200000)
    wire.unstableEvenLaneFrom = 0x200000
    let originalSave = wire.save, originalROM = wire.rom
    let device = try wire.device(), snapshot = try device.inspect(profile:.automatic)
    #expect(snapshot.saveStatus == .confirmed)
    let analysis = try ROMContentAnalysis.read(device:device,cartridge:snapshot,progress:{_ in})
    #expect(analysis.suggestedBytes == 0x200000 && analysis.hasUncertainRange)
    let request = try BackupRequest(cartridge:snapshot,romBytes:analysis.suggestedBytes,saveLayout:snapshot.saveLayout,saveFormat:.packed,verify:true,destination:destination,contentAnalysis:analysis)
    let result = try OperationRunner.backup(device:device,request:request,progress:{_ in})
    #expect(result.manifest.artifacts.map(\.bytes) == [0x200000,8192])
    #expect(wire.save == originalSave && wire.rom == originalROM && wire.saveControl == 0)
    #expect(!wire.commands.contains { [UInt8(0x13),0x14,0x15,0x18].contains($0[0]) })
}

@Test func mdDumperROMReturnedAsSRAMCannotAuthorizeWritesOrShrinkTheROM() throws {
    let wire = DumperWire()
    wire.rom = fixtureROM(bytes:0x400000)
    wire.rom.replaceSubrange(0x1A4..<0x1A8,with:Data([0,0x0F,0xFF,0xFF]))
    wire.saveReplyUsesROM = true
    let device = try wire.device(), snapshot = try device.inspect(profile:.automatic)
    #expect(snapshot.saveStatus == .unconfirmed && !snapshot.canRestoreSave && !snapshot.canBackupSave)
    let analysis = try ROMContentAnalysis.read(device:device,cartridge:snapshot,progress:{_ in})
    #expect(analysis.suggestedBytes == 0x400000)
    #expect(throws:FlashMDError.self) { try device.restore(layout:try #require(snapshot.saveLayout),raw:Data(count:snapshot.saveLayout!.windowBytes)) }
    #expect(!wire.commands.contains { [UInt8(0x13),0x14,0x15,0x18].contains($0[0]) })
}

@Test func mdDumperPermanentlyMappedSaveCanBeBackedUpWithoutAuthorizingWrites() throws {
    let wire = DumperWire(), destination = try tempFolder()
    defer { try? FileManager.default.removeItem(at:destination) }
    wire.rom = fixtureROM(bytes:0x200000,title:"NON OVERLAPPING SAVE") + Data(repeating:0xFF,count:0x200000)
    wire.alwaysVisibleSave = true
    wire.floatingVisibleLane = true
    let original = wire.save
    let device = try wire.device(), snapshot = try device.inspect(profile:.automatic)
    #expect(snapshot.saveStatus == .readOnly && snapshot.canBackupSave && !snapshot.canRestoreSave)
    for _ in 0..<3 { #expect(try device.inspect(profile:.automatic) == snapshot) }
    let analysis = try ROMContentAnalysis.read(device:device,cartridge:snapshot,progress:{_ in})
    #expect(analysis.suggestedBytes == 0x200000 && analysis.excludedROMStart == 0x200000)
    let layout = try #require(snapshot.saveLayout)
    let request = try BackupRequest(cartridge:snapshot,romBytes:nil,saveLayout:layout,saveFormat:.packed,verify:true,destination:destination)
    let result = try OperationRunner.backup(device:device,request:request,progress:{_ in})
    let folder = try #require(result.folder), artifact = try #require(result.manifest.artifacts.first)
    #expect(try Data(contentsOf:folder.appendingPathComponent(artifact.filename)) == original.prefix(layout.activeBytes))
    #expect(artifact.verified && wire.save == original)
    #expect(throws:FlashMDError.self) { try device.restore(layout:layout,raw:Data(count:layout.windowBytes)) }
    #expect(!wire.commands.contains { [UInt8(0x13),0x14,0x15,0x18].contains($0[0]) })
}

@Test(arguments:[UInt8(0x01),0x40,0xFE,0xBF])
func changingSingleBitBusResidueAllowsVerifiedSaveBackupOnly(residue: UInt8) throws {
    let wire = DumperWire(), destination = try tempFolder()
    defer { try? FileManager.default.removeItem(at:destination) }
    wire.rom = fixtureROM(bytes:0x200000,title:"PERMANENT SAVE") + Data(repeating:0xFF,count:0x200000)
    wire.alwaysVisibleSave = true; wire.floatingVisibleLane = true
    wire.visibleLaneResidueBytes = 16; wire.visibleLaneResidue = residue
    let original = wire.save
    let device = try wire.device(), snapshot = try device.inspect(profile:.automatic)
    #expect(snapshot.saveStatus == .readOnly && snapshot.canBackupSave && !snapshot.canStartSaveWrite)
    let request = try BackupRequest(cartridge:snapshot,romBytes:nil,saveLayout:snapshot.saveLayout,saveFormat:.packed,verify:true,destination:destination)
    let result = try OperationRunner.backup(device:device,request:request,progress:{_ in})
    let folder = try #require(result.folder), artifact = try #require(result.manifest.artifacts.first)
    let exported = try Data(contentsOf:folder.appendingPathComponent(artifact.filename))
    #expect(artifact.verified && exported == original.prefix(snapshot.saveLayout!.activeBytes))
    #expect(wire.save == original)
    #expect(!wire.commands.contains { [UInt8(0x13),0x14,0x15,0x18].contains($0[0]) })
}

@Test(arguments:[(UInt8(0x40),false),(UInt8(0x41),true)])
func stableResidueOrMultipleDataBitsCannotQualifySaveMemory(evidence: (UInt8,Bool)) throws {
    let wire = DumperWire()
    wire.rom = fixtureROM(bytes:0x200000,title:"UNCONFIRMED MEMORY") + Data(repeating:0xFF,count:0x200000)
    wire.alwaysVisibleSave = true; wire.floatingVisibleLane = true
    wire.visibleLaneResidueBytes = 16; wire.visibleLaneResidue = evidence.0
    wire.changingVisibleLaneResidue = evidence.1
    let device = try wire.device(), snapshot = try device.inspect(profile:.automatic)
    #expect(snapshot.saveStatus == .unconfirmed && !snapshot.canBackupSave && !snapshot.canStartSaveWrite)
    #expect(!wire.commands.contains { [UInt8(0x13),0x14,0x15,0x18].contains($0[0]) })
}

@Test func readOnlySingleLaneEvidenceNeverTruncatesStableROMBeyondAnIncorrectHeader() throws {
    let wire = DumperWire()
    wire.rom = fixtureROM(bytes:0x400000)
    wire.rom.replaceSubrange(0x1A4..<0x1A8,with:Data([0,0x0F,0xFF,0xFF]))
    for offset in stride(from:0x200000,to:0x210000,by:2) { wire.rom[offset] = 0 }
    wire.saveReplyUsesROM = true
    let device = try wire.device(), snapshot = try device.inspect(profile:.automatic)
    #expect(snapshot.saveStatus == .readOnly && !snapshot.canRestoreSave)
    let analysis = try ROMContentAnalysis.read(device:device,cartridge:snapshot,progress:{_ in})
    #expect(analysis.suggestedBytes == 0x400000 && analysis.excludedROMStart == nil)
    #expect(!wire.commands.contains { [UInt8(0x13),0x14,0x15,0x18].contains($0[0]) })
}

@Test func mirroredPermanentlyMappedSaveSuggestsROMBoundaryAndKeepsCompleteExportAvailable() throws {
    let wire = DumperWire(), destination = try tempFolder()
    defer { try? FileManager.default.removeItem(at:destination) }
    wire.rom = fixtureROM(bytes:0x200000,title:"MIRRORED SAVE") + Data(repeating:0xFF,count:0x200000)
    wire.alwaysVisibleSave = true; wire.mirroredVisibleSave = true
    wire.save[0x2345] ^= 0x73 // Distinguish the 64 KiB bus period from smaller repeats.
    let originalSave = wire.save
    let device = try wire.device(), snapshot = try device.inspect(profile:.automatic)
    #expect(snapshot.saveStatus == .readOnly)
    let analysis = try ROMContentAnalysis.read(device:device,cartridge:snapshot,progress:{_ in})
    #expect(analysis.scannedBytes == 0x400000 && analysis.suggestedBytes == 0x200000)
    #expect(analysis.possibleSaveMirrorStart == 0x200000 && analysis.possibleSaveMirrorBytes == 0x10000)
    #expect(analysis.excludedROMStart == nil && !analysis.hasUncertainRange)
    let short = try BackupRequest(cartridge:snapshot,romBytes:analysis.suggestedBytes,saveLayout:snapshot.saveLayout,saveFormat:.packed,verify:true,destination:destination,contentAnalysis:analysis)
    let result = try OperationRunner.backup(device:device,request:short,progress:{_ in})
    let folder = try #require(result.folder), rom = try #require(result.manifest.artifacts.first)
    #expect(try Data(contentsOf:folder.appendingPathComponent(rom.filename)) == wire.rom.prefix(0x200000))
    let complete = try BackupRequest(cartridge:snapshot,romBytes:0x400000,saveLayout:nil,verify:true,destination:destination,contentAnalysis:analysis)
    let full = try OperationRunner.backup(device:device,request:complete,progress:{_ in})
    #expect(full.manifest.artifacts.first?.bytes == 0x400000)
    #expect(wire.save == originalSave)
    #expect(!wire.commands.contains { [UInt8(0x13),0x14,0x15,0x18].contains($0[0]) })
}

@Test func mdDumperLinearSaveCleanupFailureStopsFurtherCommands() throws {
    let wire = DumperWire(); wire.ignoresSaveDisable = true
    let device = try wire.device()
    #expect(throws:FlashMDError.self) { try device.inspect(profile:.automatic) }
    #expect(wire.closed)
    let count = wire.commands.count
    #expect(throws:FlashMDError.self) { try device.readROM(offset:0,count:64) }
    #expect(wire.commands.count == count)
}

@Test func mdDumperLinearSaveCancellationRestoresROMWithoutCancellingCleanup() async throws {
    let wire = DumperWire(), device = try wire.device()
    let snapshot = try device.inspect(profile:.automatic), originalROM = wire.rom, originalSave = wire.save
    let layout = try #require(snapshot.saveLayout)
    wire.cancelOnSaveRead = true
    let task = Task { try device.readSRAM(layout:layout,offset:0,count:layout.windowBytes) }
    do { _ = try await task.value; Issue.record("Expected cancellation") } catch {}
    #expect(wire.saveControl == 0 && !wire.closed && wire.rom == originalROM && wire.save == originalSave)
    #expect(try device.readROM(offset:0,count:512) == originalROM.prefix(512))
    #expect(!wire.commands.contains { [UInt8(0x13),0x14,0x15,0x18].contains($0[0]) })
}

@Test func mdDumperBoundedROMReadsCheckCancellationBetweenUSBPackets() async throws {
    let wire = DumperWire(), device = try wire.device()
    _ = try device.inspect(profile:.automatic)
    let count = wire.commands.count
    wire.cancelOnROMReadFrom = 0x40000
    let task = Task { try device.readROM(offset:0x40000,count:4096) }
    do { _ = try await task.value; Issue.record("Expected cancellation") } catch is CancellationError {}
    #expect(wire.commands.count-count == 1)
    #expect(wire.saveControl == 0 && wire.streamAddress == nil && !wire.closed)
    #expect(try device.readROM(offset:0,count:64) == wire.rom.prefix(64))
}

@Test func mdDumperStreamingIsOptInAndFirmwareRestricted() throws {
    for (major,minor,board,requested,enabled) in [(2,0,3,false,false),(2,0,3,true,true),(2,1,3,true,false),(1,0,3,true,false),(2,0,2,true,false)] {
        let wire = DumperWire(); wire.ready[20] = UInt8(major); wire.ready[21] = UInt8(minor); wire.ready[24] = UInt8(board)
        let device = try wire.device(streaming:requested)
        #expect(device.streamingEnabled == enabled)
        #expect(device.requiresROMBackupVerification == enabled)
        #expect(wire.commands.map { $0[0] } == [0x10])
    }
}

@Test(arguments:[false,true]) func mdDumperStreamingStopsDrainsAndRestarts(short: Bool) throws {
    let wire = DumperWire(); wire.ready[21] = 0; wire.shortStream = short
    let before = wire.save, device = try wire.device(streaming:true)
    _ = try device.inspect(profile:.automatic)
    for offset in [0,61,0x80000] {
        #expect(try device.readROM(offset:offset,count:65539) == Data(wire.rom[offset..<offset+65539]))
        #expect(wire.pending == nil && wire.streamAddress == nil && wire.staleAfterStop == nil)
        #expect(try device.readROMForVerification(offset:offset,count:64) == Data(wire.rom[offset..<offset+64]))
    }
    #expect(wire.commands.filter { $0[0] == 0x11 && $0[4] == 1 }.count == 3)
    #expect(wire.save == before && wire.commands.allSatisfy { [UInt8(0x10),0x11,0x12,0x20].contains($0[0]) })
}

@Test(arguments:[false,true]) func mdDumperStreamingTimeoutOrCancellationRecovers(cancel: Bool) throws {
    let wire = DumperWire(); wire.ready[21] = 0
    let device = try wire.device(streaming:true); _ = try device.inspect(profile:.automatic)
    wire.streamingFailure = cancel ? CancellationError() : FlashMDError.timeout
    if cancel { #expect(throws:CancellationError.self) { try device.readROM(offset:0,count:65536) } }
    else { #expect(throws:FlashMDError.timeout) { try device.readROM(offset:0,count:65536) } }
    #expect(wire.streamAddress == nil && wire.pending == nil && !wire.closed)
    #expect(try device.readROM(offset:0,count:65536) == Data(wire.rom.prefix(65536)))
}

@Test func mdDumperUnstoppableStreamClosesTransport() throws {
    let wire = DumperWire(); wire.ready[21] = 0; wire.neverStops = true
    let device = try wire.device(streaming:true)
    #expect(throws:FlashMDError.self) { try device.readROM(offset:0,count:65536) }
    #expect(wire.closed)
    let commands = wire.commands.count
    #expect(throws:FlashMDError.self) { try device.reset() }
    #expect(throws:FlashMDError.self) { try device.readROM(offset:0,count:64) }
    #expect(wire.commands.count == commands)
}

@Test func mdDumperStreamingAnalysisRejectsDataThatWouldGiveAWrongSizeSuggestion() throws {
    let wire = DumperWire(); wire.ready[21] = 0; wire.corruptStream = true
    let device = try wire.device(streaming:true), snapshot = try device.inspect(profile:.automatic)
    #expect(throws:ROMScanMismatch.self) { try ROMContentAnalysis.read(device:device,cartridge:snapshot,progress:{ _ in }) }
    #expect(wire.streamAddress == nil && wire.commands.allSatisfy { [UInt8(0x10),0x11,0x12,0x20].contains($0[0]) })
}

@Test func mdDumperSSF2StreamingCrossesBanksAndRestoresPageFour() throws {
    let wire = DumperWire(banked:true); wire.ready[21] = 0
    let device = try wire.device(streaming:true), snapshot = try device.inspect(profile:.automatic)
    #expect(snapshot.canBackupROM)
    #expect(try device.readROM(offset:0x3F8000,count:0x10000) == Data(wire.rom[0x3F8000..<0x408000]))
    #expect(wire.page == 4 && wire.streamAddress == nil)
    wire.streamingFailure = FlashMDError.timeout
    #expect(throws:FlashMDError.timeout) { try device.readROM(offset:0x400000,count:0x10000) }
    #expect(wire.page == 4 && !wire.closed)
    #expect(try device.readROMForVerification(offset:0x400000,count:0x10000) == Data(wire.rom[0x400000..<0x410000]))
    #expect(wire.commands.allSatisfy { [UInt8(0x10),0x11,0x20].contains($0[0]) })
}

@Test(arguments:[false,true]) func mdDumperStreamingBackupAlwaysUsesSlowVerification(corrupt: Bool) throws {
    let wire = DumperWire(); wire.ready[21] = 0; wire.corruptStream = corrupt
    let device = try wire.device(streaming:true), snapshot = try device.inspect(profile:.automatic)
    let folder = try tempFolder(); defer { try? FileManager.default.removeItem(at:folder) }
    let request = try BackupRequest(cartridge:snapshot,romBytes:65536,saveLayout:nil,verify:false,destination:folder)
    if corrupt {
        #expect(throws:OperationFailure.self) { try OperationRunner.backup(device:device,request:request,progress:{ _ in }) }
        let files = FileManager.default.enumerator(at:folder,includingPropertiesForKeys:nil)!.allObjects.compactMap { $0 as? URL }
        #expect(!files.contains { ["bin","partial"].contains($0.pathExtension) })
    } else {
        let result = try OperationRunner.backup(device:device,request:request,progress:{ _ in })
        #expect(result.manifest.artifacts.first?.verified == true)
    }
    #expect(wire.commands.filter { $0[0] == 0x11 && $0[4] == 1 }.count == 1)
    #expect(wire.commands.allSatisfy { [UInt8(0x10),0x11,0x12,0x20].contains($0[0]) })
}

@Test func mdDumperPierSolarUsesQualifiedROMRegisterAndRestoresBankZero() throws {
    let wire = DumperWire(banked:true); wire.pier = true; wire.page = 0; wire.ready[21] = 0
    wire.rom.append(Data(repeating:25,count:0x300000))
    wire.rom.replaceSubrange(0x100..<0x110,with:Data("SEGA MEGA DRIVE ".utf8))
    wire.rom.replaceSubrange(0x150..<0x180,with:Data("PIER SOLAR".utf8) + Data(repeating:32,count:38))
    wire.rom.replaceSubrange(0x180..<0x18E,with:Data("GM T-574023-00 ".utf8))
    wire.rom.replaceSubrange(0x1B0..<0x1BC,with:Data([0x45,0x50]) + Data(count:10))
    let device = try wire.device(streaming:true), snapshot = try device.inspect(profile:.automatic)
    #expect(snapshot.mapper == .pierSolar && snapshot.canBackupROM && snapshot.romReadLimit == 0x800000)
    #expect(snapshot.saveStatus == .unsupported && !snapshot.canBackupSave)
    #expect(snapshot.mapperMessage?.contains("Use a FlashKit") == true)
    #expect(wire.page == 0 && !snapshot.canRestoreSave)
    #expect(try device.readROM(offset:0x3F8000,count:0x10000) == Data(wire.rom[0x3F8000..<0x408000]))
    #expect(wire.page == 0)
    #expect(try device.readROMForVerification(offset:0x3F8000,count:0x10000) == Data(wire.rom[0x3F8000..<0x408000]))
    #expect(wire.commands.allSatisfy { [UInt8(0x10),0x11,0x20].contains($0[0]) })
}

@Test func mdDumperProgrammingConsumesEveryReplyBeforeROMReadback() throws {
    let wire = DumperWire(), source = Data((0..<128).map { UInt8($0) })
    try MDDumperROMProgramming.write(offset:0x10000,data:source,transport:wire)
    #expect(wire.pending == nil)
    #expect(wire.commands.count == 3)
    #expect(Data(wire.rom[0x10000..<0x10080]) == source)
    var read = Data(repeating:0,count:64); read[0] = 0x11; read[2] = 0x80
    try wire.write(read,timeout:2)
    #expect(try wire.read(count:64,timeout:2,cancellable:false) == Data(source.prefix(64)))
}

@Test(arguments:[UInt8(0xDD),0]) func mdDumperProgrammingAcceptsClearedFirmwareStatusAcrossBlocks(initialStatus: UInt8) throws {
    let wire = DumperWire(), source = Data((0..<8192).map { UInt8(truncatingIfNeeded:$0*7) })
    wire.programAcknowledgement = initialStatus
    wire.clearsProgrammingStatusAfterReply = true
    for offset in stride(from:0,to:source.count,by:4096) {
        try MDDumperROMProgramming.write(offset:offset,data:Data(source[offset..<offset+4096]),transport:wire)
    }
    #expect(wire.pending == nil)
    #expect(wire.commands.count == 152)
    #expect(Data(wire.rom.prefix(source.count)) == source)
    var read = Data(repeating:0,count:64); read[0] = 0x11
    try wire.write(read,timeout:2)
    #expect(try wire.read(count:64,timeout:2,cancellable:false) == Data(source.prefix(64)))
}

@Test(arguments:[0,1,2]) func mdDumperProgrammingStopsWhenAcknowledgementFails(caseIndex: Int) throws {
    let wire = DumperWire()
    if caseIndex == 0 { wire.programAcknowledgement = nil }
    if caseIndex == 1 { wire.programAcknowledgement = 0xAA }
    if caseIndex == 2 { wire.shortReply = true }
    #expect(throws:FlashMDError.self) {
        try MDDumperROMProgramming.write(offset:0,data:Data(repeating:0x42,count:128),transport:wire)
    }
    #expect(wire.commands.count == 1)
    #expect(wire.commands.first?[0] == 0x14)
}

@Test func mdDumperHandshakeAndLinearScanAreNonDestructive() throws {
    let wire = DumperWire(), before = wire.save, device = try wire.device()
    let snapshot = try device.inspect(profile:.automatic)
    #expect(snapshot.readerKind == .mdDumper)
    #expect(snapshot.title == "TEST GAME")
    #expect(snapshot.saveLayout?.activeBytes == 8192)
    #expect(!snapshot.canWrite && snapshot.canRestoreSave)
    #expect(snapshot.romReadLimit == 0x400000 && snapshot.romWriteLimit == 0x200000)
    #expect(wire.commands.allSatisfy { [UInt8(0x10),0x11,0x12,0x20].contains($0[0]) })
    #expect(wire.save == before)
    #expect(try device.readROM(offset:61,count:130) == Data(wire.rom[61..<191]))
    #expect(try device.readROM(offset:0x400000,count:0) == Data())
    #expect(throws:FlashMDError.self) { try device.readROM(offset:0x400000,count:1) }
}

@Test func mdDumperAutomaticBackupReadsPastPlaceholderSRAMWithoutWriting() throws {
    let wire = DumperWire()
    wire.rom.replaceSubrange(0x1A4..<0x1A8,with:Data([0,0x0F,0xFF,0xFF]))
    wire.rom[0x280000] = 0x42; wire.rom[0x3FFFFF] = 0x51
    let oldROM = wire.rom, oldSave = wire.save
    let device = try wire.device(), snapshot = try device.inspect(profile:.automatic)
    let analysis = try ROMContentAnalysis.read(device:device,cartridge:snapshot,progress:{_ in})
    #expect(analysis.scannedBytes == 0x400000 && analysis.suggestedBytes == 0x400000)
    let destination = try tempFolder(); defer { try? FileManager.default.removeItem(at:destination) }
    let request = try BackupRequest(cartridge:snapshot,romBytes:analysis.suggestedBytes,saveLayout:nil,verify:true,destination:destination,contentAnalysis:analysis)
    let result = try OperationRunner.backup(device:device,request:request,progress:{_ in})
    let artifact = try #require(result.manifest.artifacts.first)
    #expect(artifact.bytes == 0x400000 && artifact.verified)
    #expect(try Data(contentsOf:try #require(result.folder).appendingPathComponent(artifact.filename)) == oldROM)
    #expect(wire.rom == oldROM && wire.save == oldSave)
    #expect(wire.commands.allSatisfy { [UInt8(0x10),0x11,0x12,0x20].contains($0[0]) })
    #expect(snapshot.applying(try .init(romCapacity:0x100000,saveLayout:nil)).romReadLimit == 0x100000)
    #expect(try device.inspect(profile:.krikzz4M).romReadLimit == 0x200000)
}

@Test(arguments: [0,1,2,3,4])
func mdDumperRejectsInvalidIdentityAndCloses(caseIndex: Int) throws {
    let wire = DumperWire()
    switch caseIndex {
    case 0: wire.ready[0] = 0
    case 1: wire.ready[20] = 9
    case 2: wire.ready[24] = 9
    case 3: wire.ready[25] = 1
    default: wire.shortReply = true
    }
    #expect(throws:FlashMDError.self) { try wire.device() }
    #expect(wire.closed)
}

@Test func mdDumperSRAMRoundTripPreservesUnselectedBytes() throws {
    let wire = DumperWire(), device = try wire.device()
    let layout = try #require(try device.inspect(profile:.automatic).saveLayout)
    let original = wire.save
    let raw = try device.readSRAM(layout:layout,offset:0,count:layout.windowBytes)
    #expect(try layout.pack(raw) == Data(original.prefix(layout.activeBytes)))
    #expect(stride(from:0,to:raw.count,by:2).allSatisfy { raw[$0] == 0 })
    #expect(try device.readSRAM(layout:layout,offset:125,count:130) == Data(raw[125..<255]))
    let replacement = Data(repeating:0x58,count:layout.activeBytes)
    try device.restore(layout:layout,raw:try layout.rawRepresentation(replacement,format:.packed))
    #expect(try layout.pack(device.readSRAM(layout:layout,offset:0,count:layout.windowBytes)) == replacement)
    #expect(Data(wire.save.dropFirst(layout.activeBytes)) == Data(original.dropFirst(layout.activeBytes)))
    #expect(!wire.commands.contains { $0[0] == 0x13 && $0[7] == 0xBB })
    let even = try SRAMLayout(start:0x200000,end:0x203FFE,lane:0)
    #expect(throws:FlashMDError.self) { try device.restore(layout:even,raw:raw) }
}

@Test(arguments: [0,1,2])
func mdDumperBankQualificationAndRestoration(mode: Int) throws {
    let wire = DumperWire(banked:true)
    wire.ignoresBanks = mode == 1; wire.wrapBanks = mode == 2
    let device = try wire.device(), snapshot = try device.inspect(profile:.automatic)
    #expect(snapshot.canBackupROM == (mode == 0))
    #expect(!snapshot.canWrite && !snapshot.canRestoreSave)
    #expect(wire.page == 4)
    #expect(!wire.commands.contains { [UInt8(0x12),0x13,0x14,0x15,0x18].contains($0[0]) })
    if mode == 0 {
        #expect(try device.readROM(offset:0x3FFFF1,count:130) == Data(wire.rom[0x3FFFF1..<0x3FFFF1+130]))
        #expect(wire.page == 4)
    } else { #expect(throws:FlashMDError.self) { try device.readROM(offset:0,count:512) } }
}

@Test(arguments:[false,true]) func mdDumperDaemonClawUsesTheSameMapperForUnknownRevisions(unknownRevision: Bool) throws {
    let wire = DumperWire(banked:true)
    for page in 10..<19 { wire.rom.append(Data(repeating:UInt8(page+10),count:page == 18 ? 0x40000 : 0x80000)) }
    wire.rom.replaceSubrange(0x100..<0x110,with:Data("SEGA DOA        ".utf8))
    wire.rom.replaceSubrange(0x120..<0x150,with:Data("DAEMON CLAW".utf8) + Data(repeating:32,count:37))
    wire.rom.replaceSubrange(0x150..<0x180,with:Data("NEOFID STUDIOS BITBEAM CANNON".utf8) + Data(repeating:32,count:19))
    wire.rom.replaceSubrange(0x1A4..<0x1A8,with:Data([0,0x3F,0xFF,0xFF]))
    wire.rom[0x18E] = 0x7B; wire.rom[0x18F] = unknownRevision ? 0x9C : 0x9B
    let before = wire.save, device = try wire.device(), snapshot = try device.inspect(profile:.automatic)
    #expect(snapshot.title == "DAEMON CLAW" && snapshot.mapper == .segaSSF2)
    #expect(snapshot.metadata?.internationalTitle == "NEOFID STUDIOS BITBEAM CANNON")
    #expect(snapshot.canBackupROM)
    #expect(snapshot.romReadLimit == 0x1000000)
    #expect(try device.readROM(offset:0x8FFFE1,count:0x4001F) == Data(wire.rom[0x8FFFE1..<0x940000]))
    #expect(try device.readROM(offset:0x940000,count:64) == Data(repeating:0xFF,count:64))
    #expect(wire.page == 4)
    #expect(throws:FlashMDError.self) { try device.readROM(offset:0x1000000,count:1) }
    #expect(wire.save == before && !snapshot.canWrite && !snapshot.canRestoreSave)
    #expect(wire.commands.allSatisfy { [UInt8(0x10),0x11,0x20].contains($0[0]) })
}

@Test func mdDumperScanNeverQueriesFlashIDsOrEnablesUnqualifiedROMWrites() throws {
    let wire = DumperWire(); wire.flashID = (0x20,0x57)
    wire.rom.replaceSubrange(0..<65536,with:fixtureROM(save:false))
    let device = try wire.device(), snapshot = try device.inspect(profile:.automatic)
    #expect(!snapshot.canWrite && snapshot.geometry == nil)
    #expect(!wire.commands.contains { [UInt8(0x18),0x14,0x15,0x65].contains($0[0]) })
    let image = try ROMImage(data:fixtureROM(save:false))
    #expect(throws:FlashMDError.self) { try WritePlan(target:snapshot,image:image,romName:"test",save:nil,saveName:nil,format:.packed,backupDestination:nil,clearUnusedROM:true) }
    #expect(throws:FlashMDError.self) { try device.program(offset:0,data:Data([1,2])) }
}

@Test func mdDumperFlashIdentifierDataCannotBecomeABackup() throws {
    let wire = DumperWire()
    let chipIDs = Data([0,1,0x22,0x7e]) + Data(repeating:0,count:28)
    wire.rom = Data(repeating:0,count:0x400000)
    for offset in stride(from:0,to:512,by:32) { wire.rom.replaceSubrange(offset..<offset+32,with:chipIDs) }
    let device = try wire.device(), snapshot = try device.inspect(profile:.automatic)
    #expect(snapshot.title == "Unreadable cartridge" && snapshot.metadata == nil)
    #expect(!snapshot.canBackupROM && !snapshot.canRestoreSave && snapshot.flashCapacity == nil)
    #expect(snapshot.mapperMessage?.contains("unplug USB") == true)
    #expect(throws:FlashMDError.self) { try device.readROM(offset:0,count:512) }
    #expect(throws:FlashMDError.self) { try BackupRequest(cartridge:snapshot,romBytes:512,saveLayout:nil,verify:true,destination:URL(fileURLWithPath:"/tmp")) }
    #expect(wire.commands.allSatisfy { [UInt8(0x10),0x11,0x12,0x20].contains($0[0]) })
}

@Test func mdDumperUnknownOrLegacyFlashNeverEnablesROMWrites() throws {
    for entry in [(UInt8(0xC2),UInt8(0xF9),UInt8(3)),(0xFF,0xFF,3),(0x20,0x57,0)] {
        let wire = DumperWire(); wire.flashID = (entry.0,entry.1); wire.ready[24] = entry.2
        wire.rom.replaceSubrange(0..<65536,with:fixtureROM(save:false))
        let device = try wire.device(), snapshot = try device.inspect(profile:.automatic)
        #expect(!snapshot.canWrite)
        #expect(throws:FlashMDError.self) { try device.program(offset:0,data:Data([1,2])) }
        #expect(!wire.commands.contains { [UInt8(0x14),0x15,0x65].contains($0[0]) })
    }
}

@Test(arguments:[0,1,2]) func mdDumperVerifiedBackupPublishesCompatibleFiles(revision:Int) throws {
    let wire = DumperWire()
    wire.rom.replaceSubrange(0x180..<0x18E,with:Data("GM 00000000-0\(revision)".utf8))
    let device = try wire.device()
    let snapshot = try device.inspect(profile:.automatic), layout = try #require(snapshot.saveLayout)
    let folder = try tempFolder(); defer { try? FileManager.default.removeItem(at:folder) }
    let request = try BackupRequest(cartridge:snapshot,romBytes:65536,saveLayout:layout,saveFormat:.packed,verify:true,destination:folder)
    let result = try OperationRunner.backup(device:device,request:request,progress:{ _ in })
    let artifact = try #require(result.manifest.artifacts.first(where: { !$0.isROM }))
    #expect(result.manifest.artifacts.allSatisfy { $0.verified })
    let outputFolder = try #require(result.folder)
    let stem = "Test Game (JP, US, EU)" + (revision == 0 ? "" : " [rev \(revision)]")
    #expect(outputFolder.lastPathComponent.hasPrefix(stem + " — "))
    #expect(result.manifest.artifacts.map(\.filename) == [stem + ".bin",stem + ".srm"])
    #expect(try Data(contentsOf:outputFolder.appendingPathComponent(stem + ".bin")) == Data(wire.rom.prefix(65536)))
    #expect(try Data(contentsOf:outputFolder.appendingPathComponent(artifact.filename)) == Data(wire.save.prefix(layout.activeBytes)))
    #expect(!wire.commands.contains { [UInt8(0x13),0x14,0x15].contains($0[0]) })
}

@Test func mdDumperWriteFailuresAndUnsupportedOverridesFailClosed() throws {
    let wire = DumperWire(), device = try wire.device()
    let snapshot = try device.inspect(profile:.automatic), layout = try #require(snapshot.saveLayout)
    let even = try SRAMLayout(start:0x200000,end:0x203FFE,lane:0)
    let override = try CartridgeConfiguration(romCapacity:0x200000,saveLayout:even)
    let modified = snapshot.applying(override)
    #expect(modified.readerKind == .mdDumper && modified.saveLayout == nil && !modified.canRestoreSave)
    wire.statusValue = 0
    #expect(throws:FlashMDError.timeout) { try device.restore(layout:layout,raw:Data(repeating:0,count:layout.windowBytes)) }
    #expect(wire.commands.filter { $0[0] == 0x13 }.count == 1)
    wire.shortReply = true
    #expect(throws:FlashMDError.self) { try device.readROM(offset:0,count:64) }
}

@Test func mdDumperStreamingCanChangeBetweenTransfersWithoutUSBReconnect() throws {
    let wire = DumperWire(banked:true); wire.ready[21] = 0
    let device = try wire.device(), snapshot = try device.inspect(profile:.automatic)
    let handshakeCount = wire.commands.filter { $0[0] == 0x10 }.count
    device.setROMStreaming(true)
    #expect(device.requiresROMBackupVerification && device.preferredROMReadBytes == 0x80000)
    #expect(try device.readROM(offset:0x3F8000,count:0x10000) == Data(wire.rom[0x3F8000..<0x408000]))
    #expect(wire.commands.contains { $0[0] == 0x11 && $0[4] == 1 })
    #expect(snapshot == (try device.inspect(profile:.automatic)))
    device.setROMStreaming(false)
    let count = wire.commands.count
    #expect(try device.readROM(offset:0x3F8000,count:0x10000) == Data(wire.rom[0x3F8000..<0x408000]))
    #expect(!wire.commands.suffix(from:count).contains { $0[0] == 0x11 && $0[4] == 1 })
    #expect(wire.commands.filter { $0[0] == 0x10 }.count == handshakeCount)
    #expect(wire.page == 4 && !wire.closed)
}

@Test func bankedSaveDeclarationDoesNotEnableUnqualifiedSaveCommands() throws {
    let wire = DumperWire(banked:true)
    wire.rom.replaceSubrange(0x1B0..<0x1BC,with:Data([0x52,0x41,0xF8,0x20,0,0x20,0,0,0,0x20,0xFF,0xFF]))
    wire.ready[21] = 1
    let before = wire.save, device = try wire.device(), snapshot = try device.inspect(profile:.automatic)
    let layout = try #require(snapshot.metadata?.saveLayout)
    #expect(layout.lane == 1 && layout.activeBytes == 32768)
    #expect(snapshot.saveLayout == nil && !snapshot.canRestoreSave)
    #expect(throws:FlashMDError.self) { try device.readSRAM(layout:layout,offset:0,count:128) }
    #expect(throws:FlashMDError.self) { try device.restore(layout:layout,raw:Data(count:65536)) }
    #expect(wire.save == before)
    #expect(wire.commands.allSatisfy { [UInt8(0x10),0x11,0x20].contains($0[0]) })
}

private func ssf2SaveWire() -> DumperWire {
    let wire = DumperWire(banked:true)
    wire.ready[21] = 0
    // F8 declares odd-lane SRAM, even when the address field starts on the bus word.
    wire.rom.replaceSubrange(0x1B0..<0x1BC,with:Data([0x52,0x41,0xF8,0x20,0,0x20,0,0,0,0x20,0xFF,0xFF]))
    return wire
}
private func saveControlPackets(_ wire: DumperWire) -> [Data] {
    wire.commands.filter { $0[0] == 0x20 && $0[1] == 0x78 && $0[2] == 0x98 && $0[3] == 0x50 }
}

@Test(arguments:[SaveFormat.packed,.raw])
func mdDumperSSF2SaveBackupIsProtectedVerifiedAndDoesNotEnableWrites(format: SaveFormat) throws {
    let wire = ssf2SaveWire(), originalSave = wire.save, originalROM = wire.rom
    let device = try wire.device(streaming:true), snapshot = try device.inspect(profile:.automatic)
    let layout = try #require(snapshot.saveLayout)
    #expect(snapshot.rawSaveWindow?.bytes == 65536)
    #expect(snapshot.mapper == .segaSSF2 && snapshot.romAccess == .banked)
    #expect(!snapshot.canRestoreSave && !snapshot.canWrite && !snapshot.saveWriteSupported)
    let folder = try tempFolder(); defer { try? FileManager.default.removeItem(at:folder) }
    let request = try BackupRequest(cartridge:snapshot,romBytes:nil,saveLayout:layout,saveFormat:format,verify:false,destination:folder)
    #expect(request.verify)
    let result = try OperationRunner.backup(device:device,request:request,progress:{ _ in })
    let artifact = try #require(result.manifest.artifacts.first)
    let data = try Data(contentsOf:try #require(result.folder).appendingPathComponent(artifact.filename))
    #expect(artifact.verified && artifact.saveFormat == format)
    #expect(data.count == (format == .packed ? 32768 : 65536))
    #expect((format == .packed ? data : try layout.pack(data)) == originalSave)
    #expect(wire.save == originalSave && wire.rom == originalROM)
    #expect(wire.saveControl == 0 && wire.page == 4)
    #expect(saveControlPackets(wire).map { $0[5] } == [3,0,3,0,3,0,3,0,3,0,3,0])
    #expect(wire.commands.allSatisfy { [UInt8(0x10),0x11,0x20].contains($0[0]) && $0[4] == 0 })
    #expect(throws:FlashMDError.self) { try device.restore(layout:layout,raw:Data(count:65536)) }
    #expect(throws:FlashMDError.self) { try WritePlan(target:snapshot,image:nil,romName:nil,save:originalSave,saveName:"save.srm",format:.packed,backupDestination:nil) }
    #expect(throws:FlashMDError.self) { try device.program(offset:0,data:Data([0,0])) }
}

@Test func mdDumperSSF2SaveReadsOffsetsAndRejectsUnqualifiedLayouts() throws {
    let wire = ssf2SaveWire(), device = try wire.device(), snapshot = try device.inspect(profile:.automatic)
    let layout = try #require(snapshot.saveLayout)
    let raw = try layout.rawRepresentation(wire.save,format:.packed)
    #expect(try device.readSRAM(layout:layout,offset:1,count:143) == raw.subdata(in:1..<144))
    let commands = wire.commands.count
    #expect(try device.readSRAM(layout:layout,offset:65536,count:0).isEmpty)
    #expect(throws:FlashMDError.self) { try device.readSRAM(layout:layout,offset:-1,count:10) }
    #expect(throws:FlashMDError.self) { try device.readSRAM(layout:layout,offset:65535,count:2) }
    let different = try SRAMLayout(start:0x200001,end:0x200FFF,lane:1)
    #expect(throws:FlashMDError.self) { try device.readSRAM(layout:different,offset:0,count:128) }
    #expect(throws:FlashMDError.self) { try BackupRequest(cartridge:snapshot,romBytes:nil,saveLayout:different,verify:true,destination:URL(fileURLWithPath:"/tmp")) }
    #expect(wire.commands.count == commands)
}

@Test func mdDumperSSF2SaveTimeoutRestoresROMAndAllowsRetry() throws {
    let wire = ssf2SaveWire(), device = try wire.device(), snapshot = try device.inspect(profile:.automatic)
    let layout = try #require(snapshot.saveLayout)
    wire.saveReadFailure = FlashMDError.timeout
    #expect(throws:FlashMDError.timeout) { try device.readSRAM(layout:layout,offset:0,count:128) }
    #expect(wire.saveControl == 0 && wire.page == 4 && !wire.closed)
    let data = try device.readSRAM(layout:layout,offset:0,count:128)
    #expect(Data(stride(from:1,to:128,by:2).map {data[$0]}) == wire.save.prefix(64))
}

@Test func mdDumperSSF2SaveCancellationRestoresAllROMWindows() async throws {
    let task = Task {
        let wire = ssf2SaveWire(), device = try wire.device(), snapshot = try device.inspect(profile:.automatic)
        let layout = try #require(snapshot.saveLayout)
        wire.cancelOnSaveRead = true
        #expect(throws:CancellationError.self) { try device.readSRAM(layout:layout,offset:0,count:32768) }
        #expect(wire.saveControl == 0 && wire.page == 4 && !wire.closed)
        #expect(saveControlPackets(wire).suffix(2).map {$0[5]} == [3,0])
    }
    try await task.value
}

@Test func mdDumperSSF2SaveCleanupFailureClosesReaderAndBlocksFurtherCommands() throws {
    let wire = ssf2SaveWire(), device = try wire.device(), snapshot = try device.inspect(profile:.automatic)
    let layout = try #require(snapshot.saveLayout)
    wire.ignoresSaveDisable = true
    #expect(throws:FlashMDError.self) { try device.readSRAM(layout:layout,offset:0,count:128) }
    #expect(wire.closed)
    let commands = wire.commands.count
    #expect(throws:FlashMDError.self) { try device.reset() }
    #expect(throws:FlashMDError.self) { try device.readSRAM(layout:layout,offset:0,count:128) }
    #expect(throws:FlashMDError.self) { try device.readROM(offset:0,count:64) }
    #expect(wire.commands.count == commands)
}

@Test func mdDumperSSF2IgnoredSaveControlCannotExportROMAsSRAM() throws {
    let wire = ssf2SaveWire(); wire.ignoresSaveControl = true
    let device = try wire.device(), snapshot = try device.inspect(profile:.automatic)
    #expect(snapshot.canBackupROM && snapshot.saveLayout == nil)
    #expect(snapshot.mapperMessage?.contains("SRAM could not be identified") == true)
    #expect(throws:FlashMDError.self) { try device.readSRAM(layout:try #require(snapshot.metadata?.saveLayout),offset:0,count:128) }
    #expect(wire.saveControl == 0 && !wire.closed)
}

@Test(arguments:[(1,0,3),(2,1,3),(2,0,2)])
func mdDumperSSF2SaveControlIsRestrictedToQualifiedFirmware(version: (Int,Int,Int)) throws {
    let wire = ssf2SaveWire(); wire.ready[20] = UInt8(version.0); wire.ready[21] = UInt8(version.1); wire.ready[24] = UInt8(version.2)
    let device = try wire.device(), snapshot = try device.inspect(profile:.automatic)
    #expect(snapshot.saveLayout == nil && !snapshot.canRestoreSave)
    #expect(saveControlPackets(wire).isEmpty)
}

@Test func mdDumperSSF2SaveVerificationFailureDoesNotPublishASaveFile() throws {
    let wire = ssf2SaveWire(), device = try wire.device(), snapshot = try device.inspect(profile:.automatic)
    let layout = try #require(snapshot.saveLayout)
    let folder = try tempFolder(); defer { try? FileManager.default.removeItem(at:folder) }
    // Reinspection, then two first-pass chunks, then the first verification chunk.
    wire.corruptSaveReplyOnEnable = wire.saveEnables + 4
    let request = try BackupRequest(cartridge:snapshot,romBytes:nil,saveLayout:layout,saveFormat:.packed,verify:false,destination:folder)
    #expect(throws:OperationFailure.self) { try OperationRunner.backup(device:device,request:request,progress:{_ in}) }
    let files = FileManager.default.enumerator(at:folder,includingPropertiesForKeys:nil)!.allObjects.compactMap {$0 as? URL}
    #expect(!files.contains {$0.pathExtension == "srm" || $0.pathExtension == "partial"})
    #expect(wire.saveControl == 0 && !wire.closed)
}

@Test func mdDumperSSF2SaveControlMustStillWorkAfterQualification() throws {
    let wire = ssf2SaveWire(), originalSave = wire.save
    let device = try wire.device(), snapshot = try device.inspect(profile:.automatic)
    let layout = try #require(snapshot.saveLayout)
    wire.ignoresSaveControl = true
    #expect(throws:FlashMDError.self) { try device.readSRAM(layout:layout,offset:0,count:128) }
    #expect(wire.save == originalSave && wire.saveControl == 0 && !wire.closed)
}

@Test func mdDumperSSF2SaveLayoutMustUseTheQualifiedWindowAndLane() throws {
    for declaration in [Data([0x52,0x41,0xF0,0x20,0,0x20,0,0,0,0x20,0xFF,0xFE]),
                        Data([0x52,0x41,0xF8,0x20,0,0x21,0,1,0,0x21,0xFF,0xFF])] {
        let wire = ssf2SaveWire(); wire.rom.replaceSubrange(0x1B0..<0x1BC,with:declaration)
        let device = try wire.device(), snapshot = try device.inspect(profile:.automatic)
        #expect(snapshot.saveLayout == nil && !snapshot.canRestoreSave)
        #expect(saveControlPackets(wire).isEmpty)
    }
}

@Test func mdDumperSSF2StreamingROMAndProtectedSaveReadsCanAlternate() throws {
    let wire = ssf2SaveWire(), originalSave = wire.save
    let device = try wire.device(streaming:true), snapshot = try device.inspect(profile:.automatic)
    let layout = try #require(snapshot.saveLayout)
    let rom = try device.readROM(offset:0x400000,count:65536)
    #expect(rom == wire.rom.subdata(in:0x400000..<0x410000))
    let save = try device.readSRAM(layout:layout,offset:0,count:65536)
    #expect(try layout.pack(save) == originalSave)
    #expect(try device.readROM(offset:0x400000,count:65536) == rom)
    #expect(wire.saveControl == 0 && wire.page == 4 && wire.streamAddress == nil)
    #expect(wire.save == originalSave)
    #expect(wire.commands.allSatisfy { [UInt8(0x10),0x11,0x20].contains($0[0]) })
}


@Test func mdDumperExplicitPreparationRequiresReconnectAndEnablesVerifiedLinearWrite() throws {
    let wire = DumperWire()
    wire.rom = fixtureROM(save:false) + Data(repeating:0xFF,count:0x400000-65536)
    wire.flashID = (0xBF,0xB7); wire.leaveIdentificationMode = true
    let original = wire.rom, save = wire.save
    let device = try wire.device(), snapshot = try device.inspect(profile:.automatic)
    let preparation = try device.prepareROMWriting(cartridge:snapshot,progress:{_ in})
    #expect(wire.closed && wire.rom == original && wire.save == save)
    #expect(throws:(any Error).self) { try device.readROM(offset:0,count:64) }
    #expect(!wire.commands.contains { [UInt8(0x14),0x15,0x65].contains($0[0]) })
    // Simulate power cycling the same reader/cartridge.
    wire.identificationMode = false; wire.closed = false
    let reconnected = try wire.device(), fresh = try reconnected.inspect(profile:.automatic)
    let reduced = try CartridgeConfiguration(romCapacity:0x80000,saveLayout:nil)
    #expect(throws:(any Error).self) { try reconnected.acceptROMWritingPreparation(preparation,cartridge:fresh.applying(reduced)) }
    try reconnected.acceptROMWritingPreparation(preparation,cartridge:fresh)
    let writable = try reconnected.inspect(profile:.automatic)
    #expect(writable.canWrite && writable.flashCapacity?.bytes == 0x100000)
    #expect(writable.geometry?.mdDumperAlgorithm == 1)
    let image = try ROMImage(data:fixtureROM(save:false,title:"NEW GAME"))
    let plan = try WritePlan(target:writable,image:image,romName:"game.bin",save:nil,saveName:nil,format:.packed,backupDestination:nil,clearUnusedROM:true)
    let result = try OperationRunner.write(device:reconnected,plan:plan,progress:{_ in})
    #expect(result.manifest.outcome == "completed")
    #expect(Data(wire.rom.prefix(image.data.count)) == image.data)
    #expect(wire.rom[image.data.count..<0x100000].allSatisfy { $0 == 0xFF })
    #expect(wire.save == save)
}

@Test func mdDumperPreparationRejectsIdentificationModeAndChangedROM() throws {
    for changed in [false,true] {
        let wire = DumperWire()
        wire.rom = fixtureROM(save:false) + Data(repeating:0xFF,count:0x400000-65536)
        wire.flashID = (0xBF,0xB7); wire.leaveIdentificationMode = true
        let device = try wire.device(), snapshot = try device.inspect(profile:.automatic)
        let preparation = try device.prepareROMWriting(cartridge:snapshot,progress:{_ in})
        if changed { wire.identificationMode = false; wire.rom[0x300000] ^= 1 }
        let reconnected = try wire.device(), fresh = try reconnected.inspect(profile:.automatic)
        #expect(throws:(any Error).self) { try reconnected.acceptROMWritingPreparation(preparation,cartridge:fresh) }
        #expect(!wire.commands.contains { [UInt8(0x14),0x15,0x65].contains($0[0]) })
    }
}

@Test func mdDumperPreparationRejectsAmbiguousEightMiBChipAndBankedCartridges() throws {
    let wire = DumperWire(); wire.flashID = (0x01,0x7E)
    let device = try wire.device(), snapshot = try device.inspect(profile:.automatic)
    #expect(throws:(any Error).self) { try device.prepareROMWriting(cartridge:snapshot,progress:{_ in}) }
    #expect(wire.closed && wire.commands.contains { $0[0] == 0x18 })
    #expect(!wire.commands.contains { [UInt8(0x14),0x15,0x65].contains($0[0]) })
    let banked = DumperWire(banked:true), bankedDevice = try banked.device()
    let bankedSnapshot = try bankedDevice.inspect(profile:.automatic)
    #expect(throws:(any Error).self) { try bankedDevice.prepareROMWriting(cartridge:bankedSnapshot,progress:{_ in}) }
    #expect(!banked.commands.contains { [UInt8(0x18),0x14,0x15,0x65].contains($0[0]) })
}

@Test func mdDumperPreparationAllowsBlankKnownChip() throws {
    let wire = DumperWire(); wire.rom = Data(repeating:0xFF,count:0x400000); wire.flashID = (0xBF,0xB7)
    let device = try wire.device(), snapshot = try device.inspect(profile:.automatic)
    #expect(!snapshot.canWrite && snapshot.canBackupROM && snapshot.title == "Blank cartridge")
    let preparation = try device.prepareROMWriting(cartridge:snapshot,progress:{_ in})
    let reconnected = try wire.device(), fresh = try reconnected.inspect(profile:.automatic)
    try reconnected.acceptROMWritingPreparation(preparation,cartridge:fresh)
    let writable = try reconnected.inspect(profile:.automatic)
    #expect(writable.title == "Blank cartridge" && writable.canWrite && writable.canBackupROM)
    #expect(writable.romReadLimit == 0x100000)
}

@Test(arguments:[false,true])
func mdDumperEraseWaitsForCompletionOrClosesAnUncertainSession(disconnect: Bool) throws {
    let wire = DumperWire(); wire.rom = Data(repeating:0xFF,count:0x400000); wire.flashID = (0x20,0xED)
    let device = try wire.device(), initial = try device.inspect(profile:.automatic)
    #expect(initial.canBackupROM && initial.title == "Blank cartridge")
    let preparation = try device.prepareROMWriting(cartridge:initial,progress:{_ in})
    let reconnected = try wire.device(), fresh = try reconnected.inspect(profile:.automatic)
    try reconnected.acceptROMWritingPreparation(preparation,cartridge:fresh)
    let writable = try reconnected.inspect(profile:.automatic)
    let sector = try #require(writable.geometry?.sectors.first)
    wire.eraseReadTimeouts = 7; wire.closed = false
    if disconnect {
        wire.eraseReadFailure = .disconnected
        #expect(throws:(any Error).self) { try reconnected.erase(sector:sector) }
        #expect(wire.closed)
        #expect(throws:(any Error).self) { try reconnected.reset() }
        let before = wire.commands.count
        #expect(throws:(any Error).self) { try reconnected.inspect(profile:.automatic) }
        #expect(wire.commands.count == before)
    } else {
        try reconnected.erase(sector:sector)
        try reconnected.program(offset:0,data:Data([0x12,0x34]))
        #expect(Data(wire.rom.prefix(2)) == Data([0x12,0x34]))
    }
    #expect(wire.commands.filter { $0.first == 0x15 }.count == 1)
    #expect(!wire.commands.contains { $0.first == 0x13 })
}

@Test(arguments:[false,true]) func mdDumperProgrammingFailureClosesSessionAndPreventsFurtherCommands(timeout: Bool) throws {
    let wire = DumperWire(); wire.rom = Data(repeating:0xFF,count:0x400000); wire.flashID = (0xBF,0xB7)
    let device = try wire.device(), initial = try device.inspect(profile:.automatic)
    let preparation = try device.prepareROMWriting(cartridge:initial,progress:{_ in})
    let reconnected = try wire.device(), fresh = try reconnected.inspect(profile:.automatic)
    try reconnected.acceptROMWritingPreparation(preparation,cartridge:fresh)
    _ = try reconnected.inspect(profile:.automatic)
    wire.closed = false; wire.programAcknowledgement = timeout ? nil : 0xAA
    #expect(throws:(any Error).self) { try reconnected.program(offset:0,data:Data(repeating:0x42,count:128)) }
    #expect(wire.closed && wire.commands.filter{$0.first == 0x14}.count == 1)
    let count = wire.commands.count
    #expect(throws:(any Error).self) { try reconnected.program(offset:0,data:Data([1,2])) }
    #expect(throws:(any Error).self) { try reconnected.inspect(profile:.automatic) }
    #expect(wire.commands.count == count)
    #expect(!wire.commands.contains{[UInt8(0x13),0x15].contains($0[0])})
}

@Test func mdDumperContinueCanRetryBeforeRestartWithoutWritingOrRepeatingChipIdentification() async throws {
    let wire = DumperWire()
    wire.rom = fixtureROM(save:false) + Data(repeating:0xFF,count:0x400000-65536)
    wire.flashID = (0xBF,0xB7); wire.leaveIdentificationMode = true
    let original = wire.rom, save = wire.save
    let controller = ProgrammerController(makeDevice:{ path,streaming in
        guard !wire.poweredOff else { throw FlashMDError.invalid("Reader is off") }
        wire.closed = false
        return try MDDumperDevice(transport:wire,location:path,streaming:streaming)
    })
    try await controller.connect(path:"md-dumper:123")
    let snapshot = try await controller.inspect(profile:.automatic)
    try await controller.prepareMDDumperROMWriting(snapshot,progress:{_ in})
    // Clicking Continue too early must retain the original preparation.
    await #expect(throws:(any Error).self) {
        try await controller.continueMDDumperROMWriting(profile:.automatic,progress:{_ in})
    }
    wire.poweredOff = true
    await #expect(throws:(any Error).self) {
        try await controller.continueMDDumperROMWriting(profile:.automatic,progress:{_ in})
    }
    wire.poweredOff = false; wire.identificationMode = false
    let writable = try await controller.continueMDDumperROMWriting(profile:.automatic,progress:{ value in
        #expect(value.phase == .inspecting)
    })
    #expect(writable.canWrite && writable.flashCapacity?.bytes == 0x100000)
    #expect(wire.commands.filter { $0[0] == 0x18 }.count == 1)
    #expect(!wire.commands.contains { [UInt8(0x13),0x14,0x15,0x65].contains($0[0]) })
    #expect(wire.rom == original && wire.save == save)
    let image = try ROMImage(data:fixtureROM(save:false,title:"NEW GAME"))
    let plan = try WritePlan(target:writable,image:image,romName:"game.bin",save:nil,saveName:nil,
                             format:.packed,backupDestination:nil,clearUnusedROM:true)
    let result = try await controller.write(plan,progress:{_ in})
    #expect(result.manifest.outcome == "completed")
    #expect(Data(wire.rom.prefix(image.data.count)) == image.data && wire.save == save)
}

@Test func mdDumperContinueRejectsChangedROMAndCancellationDiscardsPreparation() async throws {
    let wire = DumperWire()
    wire.rom = fixtureROM(save:false) + Data(repeating:0xFF,count:0x400000-65536)
    wire.flashID = (0xBF,0xB7)
    let controller = ProgrammerController(makeDevice:{ _,_ in try wire.device() })
    try await controller.connect(path:"md-dumper:123")
    let snapshot = try await controller.inspect(profile:.automatic)
    try await controller.prepareMDDumperROMWriting(snapshot,progress:{_ in})
    wire.rom[0x300000] ^= 1 // Header still matches; verify the full original range.
    await #expect(throws:(any Error).self) {
        try await controller.continueMDDumperROMWriting(profile:.automatic,progress:{_ in})
    }
    try await controller.cancelMDDumperROMWritingPreparation()
    wire.rom[0x300000] ^= 1
    await #expect(throws:(any Error).self) {
        try await controller.continueMDDumperROMWriting(profile:.automatic,progress:{_ in})
    }
    #expect(wire.commands.filter { $0[0] == 0x18 }.count == 1)
    #expect(!wire.commands.contains { [UInt8(0x13),0x14,0x15,0x65].contains($0[0]) })
}

@Test(arguments:[0xBFB7,0x98C2])
func mdDumperPreparedROMCapacityDoesNotBlockSeparateSRAMQualification(chip: Int) async throws {
    let wire = DumperWire()
    wire.flashID = (UInt8(chip >> 8),UInt8(truncatingIfNeeded:chip))
    wire.leaveIdentificationMode = true
    let originalROM = wire.rom, originalSave = wire.save
    let controller = ProgrammerController(makeDevice:{ _,_ in try wire.device() })
    try await controller.connect(path:"md-dumper:123")
    let snapshot = try await controller.inspect(profile:.automatic)
    #expect(snapshot.saveStatus == .confirmed)
    try await controller.prepareMDDumperROMWriting(snapshot,progress:{_ in})
    wire.identificationMode = false
    let writable = try await controller.continueMDDumperROMWriting(profile:.automatic,progress:{_ in})
    #expect(writable.canWrite && writable.canBackupSave && writable.canStartSaveWrite)
    #expect(writable.saveStatus == .confirmed && writable.saveLayout == snapshot.saveLayout)
    #expect(writable.romReadLimit == (chip == 0xBFB7 ? 0x100000 : 0x200000))
    // The wider SRAM probe must not grant ROM export access beyond the chip.
    let invalid = try BackupRequest(cartridge:writable,romBytes:writable.romReadLimit,saveLayout:nil,
                                    verify:true,destination:tempFolder())
    #expect(invalid.romBytes == writable.romReadLimit)
    #expect(throws:(any Error).self) {
        try BackupRequest(cartridge:writable,romBytes:writable.romReadLimit+64,saveLayout:nil,
                          verify:true,destination:tempFolder())
    }
    #expect(wire.rom == originalROM && wire.save == originalSave)
    #expect(!wire.commands.contains { [UInt8(0x13),0x14,0x15,0x65].contains($0[0]) })
}

@Test func mdDumperSpansionExtendedIDsEnableFourMiBWritingWithoutPretendingTheChipIsFourMiB() throws {
    let wire = DumperWire()
    wire.rom = fixtureROM(bytes:0x200000,save:false) + Data(repeating:0xA5,count:0x600000)
    wire.flashID = (0x01,0x7E); wire.leaveIdentificationMode = true
    wire.identificationWords = [0:0x0001,2:0x227E,0x1C:0x2210,0x1E:0x2200]
    let original = wire.rom, originalSave = wire.save
    let device = try wire.device(), initial = try device.inspect(profile:.linearROMOnly)
    let preparation = try device.prepareROMWriting(cartridge:initial,progress:{_ in})
    #expect(preparation.chip.capacity == 0x800000 && preparation.bytes == 0x400000)
    #expect(wire.rom == original && wire.save == originalSave && wire.closed)
    #expect(!wire.commands.contains { [UInt8(0x13),0x14,0x15,0x65].contains($0[0]) })
    wire.identificationMode = false; wire.closed = false
    let reconnected = try wire.device(), fresh = try reconnected.inspect(profile:.linearROMOnly)
    try reconnected.acceptROMWritingPreparation(preparation,cartridge:fresh)
    let writable = try reconnected.inspectConfigured(profile:.linearROMOnly,override:nil,mapper:.automatic)
    #expect(writable.canWrite && writable.geometry?.capacity == 0x800000)
    #expect(writable.romReadLimit == 0x400000 && writable.romWriteLimit == 0x400000)
    let image = try ROMImage(data:fixtureROM(bytes:0x200000,save:false,title:"NEW GAME"))
    let plan = try WritePlan(target:writable,image:image,romName:"game.bin",save:nil,saveName:nil,
                             format:.packed,backupDestination:nil,clearUnusedROM:true)
    #expect(plan.rom?.count == 0x400000)
    let result = try testWrite(device:reconnected,plan:plan,progress:{_ in})
    #expect(result.manifest.outcome == "completed")
    #expect(result.manifest.physicalFlashBytes == 0x800000 && result.manifest.erasedFlashBytes == 0x800000)
    #expect(result.manifest.programmedROMBytes == 0x400000 && result.manifest.unverifiedErasedFlashBytes == 0x400000)
    #expect(Data(wire.rom.prefix(image.data.count)) == image.data)
    #expect(wire.rom[image.data.count...].allSatisfy { $0 == 0xFF } && wire.save == originalSave)
    #expect(wire.commands.first { $0[0] == 0x15 }?[1] == 3)
    #expect(wire.commands.first { $0[0] == 0x65 }?[4] == 4)
    #expect(throws:(any Error).self) { try reconnected.program(offset:0x400000,data:Data([0,0])) }
    #expect(throws:(any Error).self) { try BackupRequest(cartridge:writable,romBytes:0x800000,saveLayout:nil,verify:true,destination:tempFolder()) }
}

@Test(arguments:[0xBF6B,0x20ED,0xC2CB,0xC2C9,0xC2FC])
func mdDumperDocumentedEightMiBChipsCanUseABoundedLinearRange(id: Int) throws {
    let wire = DumperWire(); wire.rom = fixtureROM(save:false) + Data(repeating:0xFF,count:0x400000-65536)
    wire.flashID = (UInt8(id >> 8),UInt8(truncatingIfNeeded:id)); wire.leaveIdentificationMode = true
    let configuration = try CartridgeConfiguration(romCapacity:65536,saveLayout:nil)
    let device = try wire.device(), initial = try device.inspectConfigured(profile:.automatic,override:configuration,mapper:.automatic)
    let preparation = try device.prepareROMWriting(cartridge:initial,progress:{_ in})
    #expect(preparation.chip.capacity == 0x800000)
    wire.identificationMode = false
    let reconnected = try wire.device(), fresh = try reconnected.inspectConfigured(profile:.automatic,override:configuration,mapper:.automatic)
    try reconnected.acceptROMWritingPreparation(preparation,cartridge:fresh)
    let writable = try reconnected.inspectConfigured(profile:.automatic,override:configuration,mapper:.automatic)
    #expect(writable.canWrite && writable.romWriteLimit == 65536 && writable.geometry?.capacity == 0x800000)
    let image = try ROMImage(data:fixtureROM(save:false,title:"NEW GAME"))
    let plan = try WritePlan(target:writable,image:image,romName:"game.bin",save:nil,saveName:nil,
                             format:.packed,backupDestination:nil,clearUnusedROM:true)
    #expect(try testWrite(device:reconnected,plan:plan,progress:{_ in}).manifest.outcome == "completed")
    #expect(Data(wire.rom.prefix(65536)) == image.data)
    #expect(throws:(any Error).self) { try reconnected.program(offset:65536,data:Data([0,0])) }
}

@Test(arguments:[UInt16(0x2200),0x2201,0x2221,0xFFFF])
func mdDumperSharedSpansionIDRequiresAnUnambiguousSupportedModel(bootID: UInt16) throws {
    let wire = DumperWire(); wire.rom = fixtureROM(save:false) + Data(repeating:0xFF,count:0x400000-65536)
    wire.flashID = (0x01,0x7E); wire.leaveIdentificationMode = true
    wire.identificationWords = [0:0x0001,2:0x227E,0x1C:0x2210,0x1E:bootID]
    let device = try wire.device(), initial = try device.inspect(profile:.automatic)
    if bootID == 0x2200 || bootID == 0x2201 {
        #expect(try device.prepareROMWriting(cartridge:initial,progress:{_ in}).chip.capacity == 0x800000)
    } else {
        #expect(throws:(any Error).self) { try device.prepareROMWriting(cartridge:initial,progress:{_ in}) }
    }
    #expect(wire.closed && !wire.commands.contains { [UInt8(0x13),0x14,0x15,0x65].contains($0[0]) })
}

@Test func mdDumperWholeFlashErasePreservesSeparateConfirmedSRAM() throws {
    let wire = DumperWire(); wire.flashID = (0x20,0xED); wire.leaveIdentificationMode = true
    let saved = wire.save
    let device = try wire.device(), initial = try device.inspect(profile:.automatic)
    #expect(initial.saveStatus == .confirmed)
    let preparation = try device.prepareROMWriting(cartridge:initial,progress:{_ in})
    wire.identificationMode = false
    let reconnected = try wire.device(), fresh = try reconnected.inspect(profile:.automatic)
    try reconnected.acceptROMWritingPreparation(preparation,cartridge:fresh)
    let writable = try reconnected.inspectConfigured(profile:.automatic,override:nil,mapper:.automatic)
    #expect(writable.geometry?.capacity == 0x800000 && writable.romWriteLimit == 0x200000)
    let image = try ROMImage(data:fixtureROM(title:"NEW GAME"))
    let plan = try WritePlan(target:writable,image:image,romName:"game.bin",save:nil,saveName:nil,
                             format:.packed,backupDestination:nil,clearUnusedROM:true)
    let result = try testWrite(device:reconnected,plan:plan,progress:{_ in})
    #expect(result.manifest.outcome == "completed" && result.manifest.preservedSaveSHA256 == hash(Data(saved.prefix(writable.saveLayout!.activeBytes))))
    #expect(wire.save == saved)
    #expect(!wire.commands.contains { $0[0] == 0x13 })
}

@Test func mdDumperReusedROMOnlyBoardCanIgnoreAnUnconfirmedOldSRAMDeclaration() throws {
    let wire = DumperWire(); wire.flashID = (0x20,0xED); wire.leaveIdentificationMode = true
    wire.save = Data(repeating:0xFF,count:32768)
    let configuration = try CartridgeConfiguration(romCapacity:0x400000,saveLayout:nil)
    let device = try wire.device(), scanned = try device.inspect(profile:.automatic)
    #expect(scanned.saveStatus == .unconfirmed && scanned.romWriteLimit == 0x200000)
    let originalROM = wire.rom
    let preparation = try device.prepareROMWriting(cartridge:scanned.applying(configuration),progress:{_ in})
    #expect(preparation.bytes == 0x400000)
    wire.identificationMode = false
    let reconnected = try wire.device(), fresh = try reconnected.inspectConfigured(profile:.automatic,override:configuration,mapper:.automatic)
    try reconnected.acceptROMWritingPreparation(preparation,cartridge:fresh)
    let writable = try reconnected.inspectConfigured(profile:.automatic,override:configuration,mapper:.automatic)
    #expect(writable.canWrite && writable.hasExplicitROMOnlyConfiguration && writable.romWriteLimit == 0x400000)
    let image = try ROMImage(data:fixtureROM(bytes:0x300000,save:false))
    let plan = try WritePlan(target:writable,image:image,romName:"game.bin",save:nil,saveName:nil,
                             format:.packed,backupDestination:nil,clearUnusedROM:true)
    #expect(plan.rom?.count == 0x400000 && wire.rom == originalROM)
    #expect(!wire.commands.contains { [UInt8(0x13),0x14,0x15,0x65].contains($0[0]) })
}

@Test func mdDumperRejectsOddManualCapacityBeforeIdentificationOrErasure() throws {
    let wire = DumperWire(); wire.rom = fixtureROM(save:false) + Data(repeating:0xFF,count:0x400000-65536)
    wire.flashID = (0xBF,0xB7)
    let device = try wire.device(), scanned = try device.inspect(profile:.automatic)
    let configured = scanned.applying(try .init(romCapacity:65537,saveLayout:nil))
    #expect(throws:(any Error).self) { try device.prepareROMWriting(cartridge:configured,progress:{_ in}) }
    #expect(!wire.commands.contains { [UInt8(0x18),0x14,0x15,0x65].contains($0[0]) })
    let geometry = try #require(MDDumperFlash.lookup(manufacturer:0xBF,chip:0xB7)).geometry
    #expect(throws:(any Error).self) { try geometry.programLength(512,accessibleCapacity:513) }
}

@Test func mdDumperCapacityCannotExpandAfterPreparationWithoutANewVerifiedBaseline() throws {
    let wire = DumperWire(); wire.rom = fixtureROM(save:false) + Data(repeating:0xFF,count:0x400000-65536)
    wire.flashID = (0x20,0xED)
    let small = try CartridgeConfiguration(romCapacity:65536,saveLayout:nil)
    let larger = try CartridgeConfiguration(romCapacity:131072,saveLayout:nil)
    let device = try wire.device(), initial = try device.inspectConfigured(profile:.automatic,override:small,mapper:.automatic)
    let preparation = try device.prepareROMWriting(cartridge:initial,progress:{_ in})
    let reconnected = try wire.device(), changed = try reconnected.inspectConfigured(profile:.automatic,override:larger,mapper:.automatic)
    #expect(throws:(any Error).self) { try reconnected.acceptROMWritingPreparation(preparation,cartridge:changed) }
    let original = try reconnected.inspectConfigured(profile:.automatic,override:small,mapper:.automatic)
    try reconnected.acceptROMWritingPreparation(preparation,cartridge:original)
    _ = try reconnected.inspectConfigured(profile:.automatic,override:small,mapper:.automatic)
    #expect(throws:(any Error).self) { try reconnected.inspectConfigured(profile:.automatic,override:larger,mapper:.automatic) }
    #expect(!wire.commands.contains { [UInt8(0x13),0x14,0x15,0x65].contains($0[0]) })
}
