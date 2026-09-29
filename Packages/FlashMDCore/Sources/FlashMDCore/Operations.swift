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
    public let saveFormat: SaveFormat
    public let verify: Bool
    public let destination: URL
    public init(cartridge: CartridgeSnapshot, romBytes: Int?, saveLayout: SRAMLayout?, saveFormat: SaveFormat = .raw, verify: Bool, destination: URL) throws {
        guard romBytes != nil || saveLayout != nil else { throw FlashMDError.invalid("Choose ROM, SRAM, or both.") }
        if let count = romBytes {
            guard count >= 512, count <= (cartridge.flashCapacity?.bytes ?? 0x400000) else { throw FlashMDError.invalid("ROM backup size exceeds the accessible cartridge range.") }
        }
        self.cartridge = cartridge; self.romBytes = romBytes; self.saveLayout = saveLayout; self.saveFormat = saveFormat; self.verify = verify; self.destination = destination
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
    public init(target: CartridgeSnapshot, image: ROMImage?, romName: String?, save: Data?, saveName: String?, format: SaveFormat, backupDestination: URL?) throws {
        guard !target.isDemo else { throw FlashMDError.invalid("Demo cartridges cannot be written.") }
        guard image != nil || save != nil else { throw FlashMDError.invalid("Choose a ROM and/or save file to write.") }
        guard target.canWrite, let geometry = target.geometry else { throw FlashMDError.invalid("Writing requires a recognized supported flash chip and the confirmed Krikzz cartridge profile.") }
        var representation: Data?
        if let image {
            guard image.data.count <= geometry.capacity, image.metadata.declaredROMBytes == image.data.count else { throw FlashMDError.invalid("The ROM file/header length is inconsistent or exceeds cartridge capacity.") }
            if image.metadata.saveWarning != nil { throw FlashMDError.invalid("The game uses an unsupported save type.") }
            let length = try geometry.programLength(image.data.count)
            guard length <= (target.flashCapacity?.bytes ?? 0) else { throw FlashMDError.invalid("The aligned ROM exceeds accessible flash capacity.") }
            representation = image.data + Data(repeating: 0xFF, count: length - image.data.count)
        }
        var rawSave: Data?, layout: SRAMLayout?
        if let save {
            let incoming = image?.metadata.saveLayout ?? target.metadata?.saveLayout
            guard let incoming, let hardware = target.saveLayout,
                  incoming.base == hardware.base, incoming.lane == hardware.lane, incoming.windowBytes <= hardware.windowBytes else {
                throw FlashMDError.invalid("The game save layout does not match the selected cartridge profile.")
            }
            let fullWindow = save.count == (format == .raw ? hardware.windowBytes : hardware.activeBytes)
            let selectedLayout = fullWindow ? hardware : incoming
            rawSave = try selectedLayout.rawRepresentation(save, format: format); layout = selectedLayout
        }
        if backupDestination != nil, image != nil, target.romSize == nil { throw FlashMDError.invalid("Back up the current cartridge manually with an exact ROM size, then disable pre-write backup to program a blank/invalid cartridge.") }
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
}
public struct TransferInput: Codable, Sendable {
    public let filename: String
    public let bytes: Int
    public let sha256: String
    public let saveFormat: SaveFormat?
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
    public var programmedROMBytes: Int? = nil
    public var restoredActiveSaveBytes: Int? = nil
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
    public static func backup(device: any CartridgeDevice, request: BackupRequest, progress: ProgressHandler) throws -> OperationResult {
        let folder = request.destination.appendingPathComponent("FlashMD-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8))", isDirectory: true)
        var manifest = makeManifest(request.cartridge)
        do {
            let fresh = try device.inspect(profile: request.cartridge.profile)
            guard fresh.identity == request.cartridge.identity, fresh.fingerprint == request.cartridge.fingerprint else { throw FlashMDError.invalid("The cartridge changed. Refresh and choose the backup again.") }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            if let count = request.romBytes {
                let digest = try streamROMBackup(device, count: count, verify: request.verify,
                    destination: folder.appendingPathComponent("game.bin"), progress: progress)
                manifest.artifacts.append(.init(filename: "game.bin", bytes: count, sha256: digest, verified: request.verify, saveFormat: nil))
                manifest.phases.append("ROM backup completed")
                try writeManifest(manifest, folder: folder)
            }
            if let layout = request.saveLayout {
                let raw = try readSave(device, layout: layout, progress: progress)
                if request.verify {
                    let second = try readSave(device, layout: layout, progress: { value in progress(.init(.verifying, value.completed,value.total,detail: "Comparing SRAM backup")) })
                    try compare(try layout.pack(raw), try layout.pack(second))
                }
                let data = request.saveFormat == .raw ? raw : try layout.pack(raw)
                try publish(data, to: folder.appendingPathComponent("save.srm"))
                manifest.artifacts.append(.init(filename: "save.srm", bytes: data.count, sha256: hash(data), verified: request.verify, saveFormat: request.saveFormat))
                manifest.phases.append("SRAM backup completed")
            }
            manifest.outcome = "completed"; try writeManifest(manifest, folder: folder)
            return .init(folder: folder, manifest: manifest)
        } catch {
            manifest.outcome = (error is CancellationError || error as? FlashMDError == .cancelled) ? "cancelled" : (manifest.artifacts.isEmpty ? "failed" : "partial")
            manifest.error = error.localizedDescription
            try? writeManifest(manifest, folder: folder)
            throw OperationFailure(result: .init(folder: FileManager.default.fileExists(atPath:folder.path) ? folder : nil, manifest: manifest), message: "\(error.localizedDescription) Completed backup files, if any, remain in \(folder.lastPathComponent).")
        }
    }
    public static func write(device: any CartridgeDevice, plan: WritePlan, progress: ProgressHandler) throws -> OperationResult {
        var manifest = makeManifest(plan.target), folder: URL?, changed = false
        manifest.inputs = plan.inputs
        manifest.programmedROMBytes = plan.rom?.count
        manifest.restoredActiveSaveBytes = plan.saveLayout?.activeBytes
        do {
            let fresh = try device.inspect(profile: plan.target.profile)
            guard fresh == plan.target else { throw FlashMDError.invalid("The target cartridge or capacity changed after review. Refresh and review again.") }
            if let destination = plan.backupDestination {
                let backup = try BackupRequest(cartridge: fresh, romBytes: plan.rom == nil ? nil : max(fresh.romSize?.bytes ?? 0, plan.requiredBytes), saveLayout: plan.save == nil ? nil : fresh.saveLayout, verify: true, destination: destination)
                let result = try self.backup(device: device, request: backup, progress: progress)
                folder = result.folder; manifest.artifacts = result.manifest.artifacts
                manifest.phases.append("Pre-write backup verified")
            }
            try Task.checkCancellation()
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
            manifest.outcome = "completed"
            if let folder { try writeManifest(manifest, folder: folder) }
            progress(.init(.completed,detail:"Write and readback verification completed"))
            return .init(folder: folder, manifest: manifest)
        } catch {
            if let failure = error as? OperationFailure { throw failure }
            manifest.outcome = (error is CancellationError || error as? FlashMDError == .cancelled) ? "cancelled" : "failed"; manifest.error = error.localizedDescription
            if let folder { try? writeManifest(manifest, folder: folder) }
            let message = error.localizedDescription + (changed ? " Cartridge contents may be incomplete. Refresh and program again from the original files; reconnecting will not resume this write." : " No cartridge contents were changed.")
            throw OperationFailure(result: .init(folder: folder, manifest: manifest), message: message)
        }
    }
    private static func streamROMBackup(_ device: any CartridgeDevice, count: Int, verify: Bool,
                                        destination: URL, progress: ProgressHandler) throws -> String {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).partial")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
            throw FlashMDError.invalid("The temporary backup file could not be created.")
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let file = try FileHandle(forUpdating: temporary)
        defer { try? file.close() }
        var digest = SHA256(), hasContent = false
        for offset in stride(from: 0, to: count, by: 32768) {
            try Task.checkCancellation()
            let length = min(32768, count - offset)
            let block = try device.readROM(offset: offset, count: length)
            guard block.count == length else { throw FlashMDError.invalid("The programmer returned a short ROM read.") }
            try file.write(contentsOf: block)
            digest.update(data: block)
            hasContent = hasContent || block.contains { $0 != 0xFF }
            progress(.init(.readingROM, offset + length, count, detail: "Reading ROM"))
        }
        guard hasContent else { throw FlashMDError.invalid("The ROM read returned only FF bytes. Check cartridge compatibility and contacts.") }
        try file.synchronize()
        if verify {
            try file.seek(toOffset: 0)
            for offset in stride(from: 0, to: count, by: 32768) {
                try Task.checkCancellation()
                let length = min(32768, count - offset)
                let expected = try file.read(upToCount: length) ?? Data()
                let actual = try device.readROM(offset: offset, count: length)
                do { try compare(expected, actual) }
                catch FlashMDError.mismatch(let byte) { throw FlashMDError.mismatch(offset + byte) }
                progress(.init(.verifying, offset + length, count, detail: "Comparing ROM byte for byte"))
            }
        }
        try Task.checkCancellation()
        try file.close()
        try FileManager.default.moveItem(at: temporary, to: destination)
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
    private static func publish(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).partial")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .atomic)
        try FileManager.default.moveItem(at: temporary,to: destination)
    }
    private static func makeManifest(_ cartridge: CartridgeSnapshot) -> OperationManifest {
        .init(schemaVersion:1,date:Date(),device:cartridge.identity,cartridgeTitle:cartridge.title,profile:cartridge.profile,rawHeader:cartridge.rawHeader,romSize:cartridge.romSize,flashCapacity:cartridge.flashCapacity,saveLayout:cartridge.saveLayout,outcome:"in progress",artifacts:[],phases:[],error:nil)
    }
    private static func writeManifest(_ manifest: OperationManifest, folder: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to:folder.appendingPathComponent("manifest.json"),options:.atomic)
    }
}
