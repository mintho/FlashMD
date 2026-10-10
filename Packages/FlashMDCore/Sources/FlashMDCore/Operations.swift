import Foundation
import CryptoKit

public struct OperationProgress: Sendable {
    public let phase: TransferPhase
    public let completed: Int
    public let total: Int
    public let detail: String
    public let cancellable: Bool
    public init(_ phase: TransferPhase, _ completed: Int = 0, _ total: Int = 0, detail: String = "", cancellable: Bool = true) {
        self.phase = phase; self.completed = completed; self.total = total; self.detail = detail; self.cancellable = cancellable
    }
}
public typealias ProgressHandler = @Sendable (OperationProgress) -> Void

public struct BackupRequest: Sendable {
    public let cartridge: CartridgeSnapshot
    public let romBytes: Int?
    public let saveLayout: SRAMLayout?
    public let includeSerialSave: Bool
    public let saveFormat: SaveFormat
    public let verify: Bool
    public let destination: URL
    public let contentAnalysis: ROMContentAnalysis?
    public let titleOverride: String?
    public init(cartridge: CartridgeSnapshot, romBytes: Int?, saveLayout: SRAMLayout?, saveFormat: SaveFormat = .raw, verify: Bool, destination: URL, contentAnalysis: ROMContentAnalysis? = nil, titleOverride: String? = nil, includeSerialSave: Bool = false) throws {
        let title = titleOverride?.trimmingCharacters(in:.whitespacesAndNewlines)
        if let title, title.isEmpty || title.count > 128 || title.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) {
            throw FlashMDError.invalid("Enter a title of up to 128 characters.")
        }
        guard romBytes != nil || saveLayout != nil || includeSerialSave else { throw FlashMDError.invalid("Choose ROM, save data, or both.") }
        if includeSerialSave {
            guard cartridge.serialSave == .pierSolar, cartridge.mapper == .pierSolar,
                  cartridge.romAccess == .banked, cartridge.canBackupSave,
                  cartridge.saveStatus == .readOnly, saveLayout == nil, saveFormat == .packed else {
                throw FlashMDError.invalid("SPI save backup requires confirmed serial access and save bytes only.")
            }
        }
        if let count = romBytes {
            if let analysis = contentAnalysis, let excluded = analysis.excludedROMStart, count > excluded {
                throw FlashMDError.invalid("Part of this ROM range could not be identified. Choose the suggested size or review Advanced Settings and scan again.")
            }
            guard cartridge.canBackupROM else { throw FlashMDError.invalid(cartridge.mapperMessage ?? "Complete ROM unavailable. Scan with a supported reader.") }
            if cartridge.mapper != .linear, count != cartridge.romReadLimit {
                guard let analysis = contentAnalysis, analysis.scannedBytes == cartridge.romReadLimit,
                      let suggested = analysis.suggestedBytes, count >= suggested,
                      let last = analysis.lastNonErasedByte, last < count else {
                    throw FlashMDError.invalid("Scan the complete bank range before exporting a shorter ROM.")
                }
            }
            guard count >= 512, count <= cartridge.romReadLimit else { throw FlashMDError.invalid("ROM backup size exceeds the supported cartridge range. Scan the cartridge or adjust its accessible capacity in Advanced Settings.") }
        }
        if saveLayout != nil {
            guard cartridge.canBackupSave, saveLayout == cartridge.saveLayout else {
                throw FlashMDError.invalid("SRAM is not confirmed. Use a manual SRAM layout in Advanced Settings to export unconfirmed memory.")
            }
        }
        if cartridge.romAccess != .linear, let saveLayout {
            guard cartridge.romAccess == .banked, cartridge.mapper == .segaSSF2,
                  cartridge.readerKind == .mdDumper, cartridge.saveLayout == saveLayout else {
                throw FlashMDError.invalid("SRAM backup is unavailable for this mapper.")
            }
        }
        self.cartridge = cartridge; self.romBytes = romBytes; self.saveLayout = saveLayout; self.includeSerialSave = includeSerialSave; self.saveFormat = saveFormat; self.verify = verify || cartridge.mapper != .linear || includeSerialSave; self.destination = destination
        self.contentAnalysis = contentAnalysis
        self.titleOverride = title
    }
}

public struct WritePlan: Sendable {
    public let target: CartridgeSnapshot
    public let rom: Data?
    public let originalROMLength: Int?
    public let romName: String?
    public let save: Data?
    public let saveName: String?
    public let saveLayout: SRAMLayout?
    public let backupDestination: URL?
    public let fingerprint: String
    public let inputs: [TransferInput]
    public var requiredBytes: Int { rom?.count ?? 0 }
    public init(target: CartridgeSnapshot, image: ROMImage?, romName: String?, save: Data?, saveName: String?, format: SaveFormat, backupDestination: URL?, clearUnusedROM: Bool = false) throws {
        guard !target.isDemo else { throw FlashMDError.invalid("Demo cartridges cannot be written.") }
        guard image != nil || save != nil else { throw FlashMDError.invalid("Choose a ROM and/or save file to write.") }
        guard target.serialSave == nil else { throw FlashMDError.invalid("Writing is not supported for cartridges with SPI save memory.") }
        if image != nil, !target.canWrite { throw FlashMDError.invalid("ROM writing requires a supported flash programming algorithm and known accessible capacity.") }
        if image != nil, target.metadata?.saveWarning != nil {
            throw FlashMDError.invalid("This cartridge declares an unsupported save type. ROM writing could erase its saves.")
        }
        if image != nil, target.saveLayout != nil, target.saveStatus != .confirmed, !target.canCheckSaveWriting {
            throw FlashMDError.invalid("SRAM has not been confirmed. ROM writing cannot safely preserve existing saves.")
        }
        if image != nil, target.geometry?.mdDumperAlgorithm != nil, !clearUnusedROM, image?.data.count != target.romWriteLimit {
            throw FlashMDError.invalid("This reader clears the whole ROM chip. Enable Clear unused cartridge ROM to continue.")
        }
        if save != nil, !target.canStartSaveWrite { throw FlashMDError.invalid("No writable SRAM layout is configured. Adjust Advanced Settings.") }
        var representation: Data?
        if let image, let geometry = target.geometry {
            guard image.data.count <= geometry.capacity, image.data.count <= target.romWriteLimit else { throw FlashMDError.invalid("The ROM file exceeds cartridge capacity.") }
            guard (image.metadata.declaredROMBytes ?? 0) <= image.data.count else { throw FlashMDError.invalid("The ROM file is shorter than its header declares. Check that the backup is complete.") }
            guard ROMMapper.detect(image.metadata) == .linear else { throw FlashMDError.invalid("This game needs bank switching. Writing it to a linear cartridge is not supported.") }
            if image.metadata.saveWarning != nil { throw FlashMDError.invalid("The game uses an unsupported save type.") }
            let length = try geometry.programLength(clearUnusedROM ? target.romWriteLimit : image.data.count)
            guard length <= (target.flashCapacity?.bytes ?? 0) else { throw FlashMDError.invalid("The aligned ROM exceeds accessible flash capacity.") }
            if let layout = target.saveLayout {
                guard length <= layout.base, geometry.sectors.filter({ $0.offset < length }).allSatisfy({ $0.offset + $0.bytes <= layout.base }) else {
                    throw FlashMDError.invalid("ROM erase/programming would overlap the SRAM address range. Correct the cartridge configuration before writing.")
                }
            }
            representation = image.data + Data(repeating: 0xFF, count: length - image.data.count)
        }
        var rawSave: Data?, layout: SRAMLayout?
        if let save {
            let incoming = image?.metadata.saveLayout ?? target.metadata?.saveLayout ?? target.saveLayout
            guard let incoming, let hardware = target.saveLayout,
                  incoming.base == hardware.base, incoming.lane == hardware.lane, incoming.windowBytes <= hardware.windowBytes else {
                throw FlashMDError.invalid("The game save layout does not match the selected cartridge profile.")
            }
            let fullWindow = save.count == (format == .raw ? hardware.windowBytes : hardware.activeBytes)
            let selectedLayout = fullWindow ? hardware : incoming
            rawSave = try selectedLayout.rawRepresentation(save, format: format); layout = selectedLayout
        }
        var inputs = [TransferInput]()
        if let image { inputs.append(.init(filename:romName ?? "ROM",bytes:image.data.count,sha256:hash(image.data),saveFormat:nil)) }
        if let save { inputs.append(.init(filename:saveName ?? "SRAM",bytes:save.count,sha256:hash(save),saveFormat:format)) }
        self.inputs = inputs
        self.target = target; self.rom = representation; self.originalROMLength = image?.data.count; self.romName = romName
        self.save = rawSave; self.saveName = saveName; self.saveLayout = layout; self.backupDestination = backupDestination; self.fingerprint = target.fingerprint
    }
}

public struct BackupArtifact: Codable, Sendable, Equatable {
    public let filename: String
    public let bytes: Int
    public let sha256: String
    public let verified: Bool
    public let saveFormat: SaveFormat?
    public var isROM: Bool { saveFormat == nil }
}
public struct TransferInput: Codable, Sendable {
    public let filename: String
    public let bytes: Int
    public let sha256: String
    public let saveFormat: SaveFormat?
}
public struct ReadDifference: Codable, Sendable, Equatable {
    public let memory: String
    public let offset: Int
    public let expected: UInt8
    public let actual: UInt8
    public var lane: Int { offset & 1 }
}
private struct ReadbackFailure: LocalizedError {
    let difference: ReadDifference
    var errorDescription: String? { "\(difference.memory) reads did not match at 0x\(String(difference.offset,radix:16).uppercased()). No unverified file was saved." }
}
public struct OperationManifest: Codable, Sendable {
    public let schemaVersion: Int
    public let date: Date
    public let device: String
    public let cartridgeTitle: String
    public let profile: CartridgeProfile
    public let rawHeader: Data?
    public let romSize: MemoryMeasurement?
    public let flashCapacity: MemoryMeasurement?
    public let saveLayout: SRAMLayout?
    public var outcome: String
    public var artifacts: [BackupArtifact]
    public var phases: [String]
    public var error: String?
    public var inputs: [TransferInput]? = nil
    public var configurationOverride: CartridgeConfiguration? = nil
    public var programmedROMBytes: Int? = nil
    public var restoredActiveSaveBytes: Int? = nil
    public var contentAnalysis: ROMContentAnalysis? = nil
    public var preservedSaveSHA256: String? = nil
    public var mapper: ROMMapper? = nil
    public var romAccess: ROMAccess? = nil
    public var mappedROMBytes: Int? = nil
    public var saveStatus: SaveMemoryStatus? = nil
    public var backupScope: String? = nil
    public var limitations: [String]? = nil
    public var unusedSaveLaneFill: Int? = nil
    public var recoveryJournal: String? = nil
    public var readDifference: ReadDifference? = nil
    public var serialSave: SerialSaveConfiguration? = nil
}
public struct OperationResult: Sendable {
    public let folder: URL?
    public let manifest: OperationManifest
}
public struct OperationFailure: LocalizedError, Sendable {
    public let result: OperationResult
    public let message: String
    public var errorDescription: String? { message }
}

public enum OperationRunner {
    public static func backup(device: any CartridgeDevice, request: BackupRequest, progress: ProgressHandler, allowBlank: Bool = false) throws -> OperationResult {
        let name = backupName(for:request.titleOverride ?? request.cartridge.metadata?.title ?? "Cartridge Backup",regions:request.cartridge.regions,revision:request.cartridge.metadata?.revision)
        let date = DateFormatter()
        date.locale = Locale(identifier:"en_US_POSIX"); date.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let folder = request.destination.appendingPathComponent("\(name) — \(date.string(from:Date())) — \(UUID().uuidString.prefix(8))", isDirectory: true)
        let romFilename = name + ".bin", saveFilename = name + ".srm"
        var manifest = makeManifest(request.cartridge,titleOverride:request.titleOverride)
        manifest.mapper = request.cartridge.mapper; manifest.romAccess = request.cartridge.romAccess; manifest.mappedROMBytes = request.cartridge.mappedROMBytes
        manifest.configurationOverride = request.cartridge.configurationOverride
        manifest.contentAnalysis = request.contentAnalysis
        if let limitation = request.contentAnalysis?.limitation { manifest.limitations?.append(limitation) }
        do {
            let fresh = try device.inspectConfigured(profile:request.cartridge.profile,override:request.cartridge.configurationOverride,mapper:request.cartridge.mapperSelection)
            guard fresh == request.cartridge else { throw FlashMDError.invalid("The cartridge changed. Refresh and choose the backup again.") }
            if let count = request.romBytes, count < fresh.romReadLimit, let analysis = request.contentAnalysis {
                if let excluded = analysis.excludedROMStart {
                    guard count <= excluded else { throw FlashMDError.invalid("The requested ROM includes unconfirmed memory. Scan again.") }
                    let current = try ROMContentAnalysis.read(device:device,cartridge:fresh,progress:progress)
                    guard current.excludedROMStart == excluded, current.sha256 == analysis.sha256 else {
                        throw FlashMDError.invalid("The ROM mapping changed. Scan again before backing up.")
                    }
                } else {
                if analysis.scannedBytes == fresh.romReadLimit,
                   let suggested = analysis.suggestedBytes, count >= suggested,
                   let last = analysis.lastNonErasedByte, last < count {
                    // Recheck every omitted byte through the independent slow path.
                    // Changes inside the export are captured and verified below.
                    for offset in stride(from:count,to:fresh.romReadLimit,by:32768) {
                        try Task.checkCancellation()
                        let length = min(32768,fresh.romReadLimit-offset)
                        let tail = try device.readROMForVerification(offset:offset,count:length)
                        guard tail.count == length, tail.allSatisfy({ $0 == 0xFF }) else {
                            throw FlashMDError.invalid("New data was found beyond the suggested size. Scan again or back up the complete ROM.")
                        }
                        progress(.init(.verifying,offset+length-count,fresh.romReadLimit-count,detail:"Checking unused ROM space"))
                    }
                } else {
                    let current = try ROMContentAnalysis.read(device:device,cartridge:fresh,progress:progress)
                    guard current.scannedBytes == analysis.scannedBytes, current.sha256 == analysis.sha256 else {
                        throw FlashMDError.invalid("ROM contents changed since the size suggestion. Scan again before exporting a shorter ROM.")
                    }
                }
                }
            }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            if let count = request.romBytes {
                let verified = request.verify || device.requiresROMBackupVerification
                let digest = try streamROMBackup(device, count: count, verify: verified,
                    destination: folder.appendingPathComponent(romFilename), progress: progress, allowBlank:allowBlank)
                manifest.artifacts.append(.init(filename: romFilename, bytes: count, sha256: digest, verified: verified, saveFormat: nil))
                manifest.phases.append("ROM backup completed")
                try writeManifest(manifest, folder: folder)
            }
            if let layout = request.saveLayout {
                let raw = try readSave(device, layout: layout, progress: progress)
                if request.verify {
                    let second = try readSave(device, layout: layout, progress: { value in progress(.init(.verifying, value.completed,value.total,detail: "Comparing SRAM backup")) })
                    try compareReadback(try layout.pack(raw),try layout.pack(second),offset:layout.start,memory:"SRAM",addressStride:layout.lane == nil ? 1 : 2)
                }
                let data = request.saveFormat == .raw ? raw : try layout.pack(raw)
                try publish(data, to: folder.appendingPathComponent(saveFilename))
                manifest.artifacts.append(.init(filename: saveFilename, bytes: data.count, sha256: hash(data), verified: request.verify, saveFormat: request.saveFormat))
                manifest.phases.append("SRAM backup completed")
            }
            if request.includeSerialSave, let configuration = fresh.serialSave {
                let first = try readSerialSave(device,configuration:configuration,progress:progress)
                let second = try readSerialSave(device,configuration:configuration,progress:{ value in
                    progress(.init(.verifying,value.completed,value.total,detail:"Comparing SPI save backup"))
                })
                try compareReadback(first,second,offset:0,memory:"SPI save")
                try publish(first,to:folder.appendingPathComponent(saveFilename))
                manifest.artifacts.append(.init(filename:saveFilename,bytes:first.count,sha256:hash(first),verified:true,saveFormat:.packed))
                manifest.phases.append("SPI save backup completed")
            }
            manifest.outcome = "completed"; try writeManifest(manifest, folder: folder)
            return .init(folder: folder, manifest: manifest)
        } catch {
            manifest.outcome = (error is CancellationError || error as? FlashMDError == .cancelled) ? "cancelled" : (manifest.artifacts.isEmpty ? "failed" : "partial")
            manifest.error = error.localizedDescription
            manifest.readDifference = (error as? ReadbackFailure)?.difference
            try? writeManifest(manifest, folder: folder)
            let saved = manifest.artifacts.isEmpty ? " No backup files were saved." : " Saved files remain in \(folder.lastPathComponent)."
            throw OperationFailure(result: .init(folder: FileManager.default.fileExists(atPath:folder.path) ? folder : nil, manifest: manifest), message: error.localizedDescription + saved)
        }
    }
    public static func write(device: any CartridgeDevice, plan: WritePlan, progress: ProgressHandler, recoveryDirectory: URL = SaveRecoveryJournal.directory) throws -> OperationResult {
        var manifest = makeManifest(plan.target), folder: URL?, changed = false
        var recovery: URL?
        manifest.configurationOverride = plan.target.configurationOverride
        manifest.inputs = plan.inputs
        manifest.programmedROMBytes = plan.rom?.count
        manifest.restoredActiveSaveBytes = plan.saveLayout?.activeBytes
        do {
            let fresh = try device.inspectConfigured(profile:plan.target.profile,override:plan.target.configurationOverride,mapper:plan.target.mapperSelection)
            guard fresh == plan.target else { throw FlashMDError.invalid("The target cartridge or capacity changed after review. Refresh and review again.") }
            let preservedLayout = plan.rom != nil && plan.save == nil ? fresh.saveLayout : nil
            var preservedSave: Data?
            var checkedSave: Data?
            if let layout = preservedLayout ?? (fresh.canCheckSaveWriting ? fresh.saveLayout : nil) {
                let first = try readSave(device,layout:layout,progress:progress)
                let second = try readSave(device,layout:layout,progress:progress)
                try compare(try layout.pack(first),try layout.pack(second))
                if preservedLayout != nil { preservedSave = first }
                checkedSave = first
                manifest.phases.append("Existing SRAM captured and verified")
                if plan.rom != nil || fresh.canCheckSaveWriting {
                    let rom = plan.rom.map { Data($0.prefix(plan.originalROMLength ?? $0.count)) }
                    recovery = try SaveRecoveryJournal.create(raw:first,layout:layout,target:fresh,rom:rom,directory:recoveryDirectory)
                    manifest.recoveryJournal = recovery?.path
                }
            }
            if let destination = plan.backupDestination {
                let backup = try BackupRequest(cartridge: fresh, romBytes: plan.rom == nil ? nil : fresh.romReadLimit, saveLayout: plan.save != nil || plan.rom != nil ? fresh.saveLayout : nil, verify: true, destination: destination)
                let result = try self.backup(device: device, request: backup, progress: progress, allowBlank:true)
                folder = result.folder; manifest.artifacts = result.manifest.artifacts
                manifest.phases.append("Pre-write backup verified")
            }
            try Task.checkCancellation()
            if fresh.canCheckSaveWriting, let layout = fresh.saveLayout, let original = checkedSave {
                // The user's write confirmation authorizes this temporary check.
                // Journal creation must succeed before any save byte is touched.
                guard recovery != nil else { throw FlashMDError.invalid("Save recovery files could not be created.") }
                progress(.init(.verifying,detail:"Checking SRAM write access",cancellable:false))
                changed = true
                try device.checkSRAMWriting(layout:layout,originalRaw:original)
                manifest.phases.append("SRAM write access checked; original saves restored")
                try Task.checkCancellation()
            }
            if let rom = plan.rom, let geometry = plan.target.geometry {
                let sectors = geometry.sectors.filter { $0.offset < rom.count }
                for (index, sector) in sectors.enumerated() {
                    try Task.checkCancellation()
                    progress(.init(.erasing,index,sectors.count,detail: "Erasing sector \(index+1) of \(sectors.count)",cancellable:false))
                    changed = true; try device.erase(sector: sector)
                }
                manifest.phases.append("ROM erased")
                for offset in stride(from: 0, to: rom.count, by: 4096) {
                    try Task.checkCancellation()
                    progress(.init(.programmingROM,offset,rom.count,detail:"Programming ROM",cancellable:false))
                    try device.program(offset: offset, data: Data(rom[offset..<min(offset+4096,rom.count)]))
                }
                manifest.phases.append("ROM programmed")
                try verifyROM(device, expected: rom, progress: progress)
                manifest.phases.append("ROM verified")
            }
            if let raw = plan.save, let layout = plan.saveLayout {
                try Task.checkCancellation(); changed = true
                progress(.init(.restoringSRAM,0,raw.count,detail:"Restoring active save bytes"))
                try device.restore(layout: layout, raw: raw)
                manifest.phases.append("SRAM restored")
                let back = try readSave(device, layout: layout, progress: { value in progress(.init(.verifying,value.completed,value.total,detail:"Verifying SRAM")) })
                try compare(try layout.pack(raw), try layout.pack(back))
                manifest.phases.append("SRAM verified")
            }
            if let original = preservedSave, let layout = preservedLayout {
                var after = try readSave(device,layout:layout,progress:{ value in progress(.init(.verifying,value.completed,value.total,detail:"Checking existing save data")) })
                if try layout.pack(after) != layout.pack(original) {
                    guard fresh.canStartSaveWrite else { throw FlashMDError.invalid("Existing saves changed and cannot be restored with these SRAM settings. Recover them from a backup.") }
                    try device.restore(layout:layout,raw:original)
                    after = try readSave(device,layout:layout,progress:progress)
                    manifest.phases.append("Existing SRAM recovered")
                }
                try compare(try layout.pack(original),try layout.pack(after))
                manifest.preservedSaveSHA256 = hash(try layout.pack(after))
                manifest.phases.append("Existing SRAM preserved and verified")
            }
            manifest.outcome = "completed"
            if let recovery {
                do { try FileManager.default.removeItem(at:recovery); manifest.recoveryJournal = nil }
                catch { manifest.limitations?.append("Verified save recovery files remain at \(recovery.path).") }
            }
            if let folder { try writeManifest(manifest, folder: folder) }
            progress(.init(.completed,detail:"Write and readback verification completed"))
            return .init(folder: folder, manifest: manifest)
        } catch {
            if let failure = error as? OperationFailure {
                if let recovery, !changed { try? FileManager.default.removeItem(at:recovery) }
                throw failure
            }
            manifest.outcome = (error is CancellationError || error as? FlashMDError == .cancelled) ? "cancelled" : "failed"; manifest.error = error.localizedDescription
            if let folder { try? writeManifest(manifest, folder: folder) }
            let message = error.localizedDescription + (changed ? " Cartridge contents may be incomplete. Scan again and rewrite from the original files." : " Cartridge contents were not changed.")
            if let recovery, !changed {
                try? FileManager.default.removeItem(at:recovery); manifest.recoveryJournal = nil
            }
            let recoveryMessage = manifest.recoveryJournal.map { " Preserved saves are available at \($0)." } ?? ""
            throw OperationFailure(result: .init(folder: folder, manifest: manifest), message: message + recoveryMessage)
        }
    }
    private static func streamROMBackup(_ device: any CartridgeDevice, count: Int, verify: Bool,
                                        destination: URL, progress: ProgressHandler, allowBlank: Bool) throws -> String {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent("FlashMD-\(UUID().uuidString).partial")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
            throw FlashMDError.invalid("The temporary backup file could not be created.")
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let file = try FileHandle(forUpdating: temporary)
        defer { try? file.close() }
        var digest = SHA256(), hasContent = false
        let chunkBytes = device.preferredROMReadBytes
        for offset in stride(from: 0, to: count, by: chunkBytes) {
            try Task.checkCancellation()
            let length = min(chunkBytes, count - offset)
            let block = try device.readROM(offset: offset, count: length)
            guard block.count == length else { throw FlashMDError.invalid("The programmer returned a short ROM read.") }
            try file.write(contentsOf: block)
            digest.update(data: block)
            hasContent = hasContent || block.contains { $0 != 0xFF }
            progress(.init(.readingROM, offset + length, count, detail: "Reading ROM"))
        }
        guard hasContent || allowBlank else { throw FlashMDError.invalid("The ROM read returned only FF bytes. Check cartridge compatibility and contacts.") }
        try file.synchronize()
        if verify {
            try file.seek(toOffset: 0)
            for offset in stride(from: 0, to: count, by: 32768) {
                try Task.checkCancellation()
                let length = min(32768, count - offset)
                let expected = try file.read(upToCount: length) ?? Data()
                let actual = try device.readROMForVerification(offset: offset, count: length)
                try compareReadback(expected,actual,offset:offset,memory:"ROM")
                progress(.init(.verifying, offset + length, count, detail: "Comparing ROM byte for byte"))
            }
        }
        try Task.checkCancellation()
        try file.close()
        try publishFile(temporary, to: destination)
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private static func readSave(_ device: any CartridgeDevice, layout: SRAMLayout, progress: ProgressHandler) throws -> Data {
        var data = Data()
        for offset in stride(from: 0, to: layout.windowBytes, by: 32768) {
            try Task.checkCancellation()
            let length = min(32768,layout.windowBytes-offset), block = try device.readSRAM(layout: layout,offset: offset,count:length)
            guard block.count == length else { throw FlashMDError.invalid("The programmer returned a short SRAM read.") }
            data.append(block); progress(.init(.readingSRAM,data.count,layout.windowBytes,detail:"Reading SRAM"))
        }
        return data
    }
    private static func readSerialSave(_ device: any CartridgeDevice, configuration: SerialSaveConfiguration, progress: ProgressHandler) throws -> Data {
        var data = Data()
        for offset in stride(from:0,to:configuration.addressBytes,by:256) {
            try Task.checkCancellation()
            let count = min(256,configuration.addressBytes-offset)
            let block = try device.readSerialSave(offset:offset,count:count)
            guard block.count == count else { throw FlashMDError.invalid("Incomplete SPI save read. No save file was created.") }
            data.append(block)
            progress(.init(.readingSRAM,data.count,configuration.addressBytes,detail:"Reading SPI save memory"))
        }
        return data
    }
    private static func verifyROM(_ device: any CartridgeDevice, expected: Data, progress: ProgressHandler) throws {
        for offset in stride(from: 0, to: expected.count, by: 32768) {
            try Task.checkCancellation()
            let count = min(32768,expected.count-offset), block = try device.readROM(offset:offset,count:count)
            do { try compare(Data(expected[offset..<offset+count]),block) }
            catch FlashMDError.mismatch(let byte) { throw FlashMDError.mismatch(offset+byte) }
            progress(.init(.verifying,offset+count,expected.count,detail:"Comparing ROM byte for byte"))
        }
    }
    public static func compare(_ expected: Data, _ actual: Data) throws {
        guard expected.count == actual.count else { throw FlashMDError.invalid("Readback length differs from the intended data.") }
        if let offset = expected.indices.first(where: { expected[$0] != actual[$0] }) { throw FlashMDError.mismatch(offset) }
    }
    private static func compareReadback(_ expected: Data, _ actual: Data, offset: Int, memory: String, addressStride: Int = 1) throws {
        guard expected.count == actual.count else { throw FlashMDError.invalid("Incomplete \(memory) verification read. No unverified file was saved.") }
        if let byte = expected.indices.first(where:{ expected[$0] != actual[$0] }) {
            throw ReadbackFailure(difference:.init(memory:memory,offset:offset+byte*addressStride,expected:expected[byte],actual:actual[byte]))
        }
    }
    private static func publish(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent("FlashMD-\(UUID().uuidString).partial")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .atomic)
        let file = try FileHandle(forWritingTo:temporary)
        defer { try? file.close() }
        try file.synchronize(); try file.close()
        try publishFile(temporary, to: destination)
    }
    private static func publishFile(_ temporary: URL, to destination: URL) throws {
        // File providers can asynchronously mark dot-prefixed staging files as hidden.
        // Use a regular .partial name, and ensure the final name is visible after moving it.
        var visible = temporary, values = URLResourceValues()
        values.isHidden = false
        try? visible.setResourceValues(values)
        try FileManager.default.moveItem(at: temporary,to: destination)
        visible = destination
        try? visible.setResourceValues(values)
    }
    static func backupName(for title: String, regions: [String] = [], revision: Int? = nil) -> String {
        let invalid = CharacterSet(charactersIn:"/\\:*?\"<>|").union(.controlCharacters)
        let cleaned = title.precomposedStringWithCanonicalMapping.unicodeScalars.map {
            invalid.contains($0) ? " " : String($0)
        }.joined().split(whereSeparator: { $0.isWhitespace }).joined(separator:" ")
        let minorWords: Set<String> = ["a", "an", "and", "as", "at", "but", "by", "for", "from", "in", "into", "nor", "of", "on", "or", "per", "the", "to", "via", "vs", "with"]
        let romanNumerals: Set<String> = ["I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X", "XI", "XII", "XIII", "XIV", "XV", "XVI"]
        let locale = Locale(identifier:"en_US_POSIX")
        let trimmed = cleaned.trimmingCharacters(in:CharacterSet(charactersIn:" .-"))
        let words = trimmed.split(separator:" ").enumerated().map { index, word in
            let lower = word.lowercased(with:locale)
            let letters = lower.trimmingCharacters(in:CharacterSet.letters.inverted)
            if index > 0, minorWords.contains(letters) { return lower }
            if romanNumerals.contains(String(word).uppercased(with:locale)) { return String(word).uppercased(with:locale) }
            return String(word).capitalized(with:locale)
        }
        let titleCase = words.isEmpty ? "Untitled Cartridge" : words.joined(separator:" ")
        let regionSet = Set(regions)
        let tags = [("Japan", "JP"), ("USA", "US"), ("Europe", "EU")]
            .compactMap { regionSet.contains($0.0) ? $0.1 : nil }
        let regionSuffix = tags.isEmpty ? "" : " (\(tags.joined(separator:", ")))"
        let revisionSuffix = revision.flatMap { (1...99).contains($0) ? " [rev \($0)]" : nil } ?? ""
        let suffix = regionSuffix + revisionSuffix
        var name = ""
        for character in titleCase {
            guard name.utf8.count + String(character).utf8.count + suffix.utf8.count <= 120 else { break }
            name.append(character)
        }
        name = name.trimmingCharacters(in:CharacterSet(charactersIn:" .-"))
        return name + suffix
    }
    private static func makeManifest(_ cartridge: CartridgeSnapshot, titleOverride: String? = nil) -> OperationManifest {
        var manifest = OperationManifest(schemaVersion:2,date:Date(),device:cartridge.identity,cartridgeTitle:titleOverride ?? cartridge.title,profile:cartridge.profile,rawHeader:cartridge.rawHeader,romSize:cartridge.romSize,flashCapacity:cartridge.flashCapacity,saveLayout:cartridge.saveLayout,outcome:"in progress",artifacts:[],phases:[],error:nil)
        manifest.serialSave = cartridge.serialSave
        manifest.saveStatus = cartridge.saveStatus
        manifest.backupScope = "Selected ROM and/or save bytes; additional cartridge hardware storage is not included."
        manifest.limitations = ["Repeated reads verify consistency, not cartridge completeness."]
        if cartridge.serialSave != nil { manifest.limitations?.append("SPI capture covers the 64 KiB serial address range; physical chip capacity is not inferred. SPI writing is unsupported.") }
        if cartridge.mapper == .linear { manifest.limitations?.append("Linear ROM access is assumed. Undeclared bank switching cannot be ruled out.") }
        if cartridge.saveLayout != nil, cartridge.saveStatus != .confirmed { manifest.limitations?.append(cartridge.saveStatus.explanation) }
        if cartridge.readerKind == .mdDumper, cartridge.saveLayout != nil { manifest.unusedSaveLaneFill = 0 }
        return manifest
    }
    static func writeManifest(_ manifest: OperationManifest, folder: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to:folder.appendingPathComponent("manifest.json"),options:.atomic)
    }
}
