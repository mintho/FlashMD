import Foundation

public protocol CartridgeService: Sendable { func inspect() async throws -> CartridgeSnapshot }
public enum CartridgeServiceError: LocalizedError, Sendable, Equatable {
    case transportUnavailable
    public var errorDescription: String? { "Connect a FlashKit or MD Dumper via USB." }
}
public actor DisconnectedCartridgeService: CartridgeService {
    public init() {}
    public func inspect() async throws -> CartridgeSnapshot { throw CartridgeServiceError.transportUnavailable }
}
public actor DemoCartridgeService: CartridgeService {
    public init() {}
    public func inspect() async throws -> CartridgeSnapshot {
        let layout = try SRAMLayout(start:0x200001,end:0x20FFFF,lane:1)
        let metadata = ROMMetadata(console:"SEGA MEGA DRIVE",domesticTitle:"Ragnacenty",internationalTitle:"Ragnacenty",productCode:"GM DEMO-00",copyright:"(C)SEGA 1994",copyrightYear:"1994",peripherals:"J",regions:["Japan","USA","Europe"],declaredROMBytes:2097152,storedChecksum:0,saveLayout:layout,saveWarning:nil,rawHeader:Data(repeating:0,count:256))
        return .init(title:metadata.title,regions:metadata.regions,romSize:.init(bytes:2097152,source:.sample),flashCapacity:.init(bytes:2097152,source:.sample),rawSaveWindow:.init(bytes:65536,source:.sample),isDemo:true,metadata:metadata,saveLayout:layout)

    }
}
public actor ProgrammerController {
    private let makeDevice: @Sendable (String, Bool) throws -> any CartridgeDevice
    private var device: (any CartridgeDevice)?
    private var connectedPath: String?
    private var operationRunning = false
    private var pendingROMPreparation: (path: String, preparation: MDDumperWritePreparation)?
    public init() { makeDevice = Self.openDevice }
    init(makeDevice: @escaping @Sendable (String, Bool) throws -> any CartridgeDevice) {
        self.makeDevice = makeDevice
    }
    private static func openDevice(path: String, streaming: Bool) throws -> any CartridgeDevice {
        if path.hasPrefix("md-dumper:"), let location = UInt32(path.dropFirst(10)) {
            return try MDDumperDevice(transport:MDDumperUSBTransport(location:location),location:path,streaming:streaming)
        }
        return try FlashKitDevice(transport:SerialTransport(path:path),path:path)
    }
    public func ports() -> [SerialPort] { SerialPort.discover() }
    public func endpoints() -> [ProgrammerEndpoint] { ProgrammerEndpoint.discover() }
    public func supportsMDDumperStreaming() -> Bool { (device as? MDDumperDevice)?.supportsROMStreaming == true }
    public func setMDDumperStreaming(_ enabled: Bool) throws {
        guard !operationRunning else { throw FlashMDError.busy }
        (device as? MDDumperDevice)?.setROMStreaming(enabled)
    }
    public func connect(path: String, mdDumperStreaming: Bool = false) throws {
        guard !operationRunning else { throw FlashMDError.busy }
        device?.close(); device = nil; connectedPath = nil
        if pendingROMPreparation?.path != path { pendingROMPreparation = nil }
        device = try makeDevice(path,mdDumperStreaming)
        connectedPath = path
    }

    /// Retry only a content-analysis discrepancy after analyze() has proved
    /// cleanup succeeded and closed the session. Never retry save reads, writes,
    /// uncertain cleanup, transport errors or mapper qualification failures.
    public func scan(path: String, profile: CartridgeProfile, override: CartridgeConfiguration? = nil,
                     mapper: ROMMapper = .automatic, mdDumperStreaming: Bool = false,
                     progress: @escaping ProgressHandler) throws -> CartridgeScanResult {
        guard !operationRunning else { throw FlashMDError.busy }
        let limit = 3
        var failures: [ScanAttemptFailure] = []
        var original: CartridgeSnapshot?
        for attempt in 1...limit {
            try Task.checkCancellation()
            var phase = "connecting"
            do {
                progress(.init(.inspecting,0,0,detail:attempt == 1 ? "Connecting to your programmer" : "Checking the cartridge again · scan \(attempt) of \(limit)"))
                // Slow reads on recovery; the user's streaming preference remains unchanged.
                try connect(path:path,mdDumperStreaming:mdDumperStreaming && attempt == 1)
                phase = "identifying"
                let snapshot = try inspect(profile:profile,override:override,mapper:mapper)
                if let original {
                    guard snapshot.identity == original.identity, snapshot.fingerprint == original.fingerprint,
                          snapshot.mapper == original.mapper, snapshot.romReadLimit == original.romReadLimit else {
                        throw FlashMDError.invalid("The cartridge changed. Scan again.")
                    }
                } else { original = snapshot }
                phase = "analyzing ROM"
                let analysis = snapshot.canBackupROM ? try analyze(snapshot,progress:progress) : nil
                // Subsequent backups retain the user's selected mode, with independent verification.
                try setMDDumperStreaming(mdDumperStreaming)
                return .init(cartridge:snapshot,analysis:analysis,failures:failures)
            } catch {
                failures.append(.init(attempt:attempt,reader:original?.identity ?? path,phase:phase,
                    message:error.localizedDescription,mismatch:error as? ROMScanMismatch))
                if phase == "analyzing ROM", error is ROMScanMismatch, device == nil, attempt < limit {
                    continue
                }
                // analyze()/inspect() already clean up their failures. Close any
                // session left by a changed-cartridge guard before propagating it.
                try? disconnect()
                throw CartridgeScanFailure(failures:failures,underlying:error)
            }
        }
        preconditionFailure("Every scan attempt returns or throws")
    }
    public func disconnect() throws {
        guard !operationRunning else { throw FlashMDError.busy }
        device?.close(); device = nil; connectedPath = nil
    }
    public func inspect(profile: CartridgeProfile, override: CartridgeConfiguration? = nil, mapper: ROMMapper = .automatic) throws -> CartridgeSnapshot {
        guard !operationRunning, let device else { throw FlashMDError.invalid("Connect a programmer before inspecting a cartridge.") }
        do {
            let snapshot = try device.inspectConfigured(profile:profile,override:override,mapper:mapper)
            if let preparation = pendingROMPreparation, let dumper = device as? MDDumperDevice {
                pendingROMPreparation = nil
                try dumper.acceptROMWritingPreparation(preparation.preparation,cartridge:snapshot)
                return try device.inspectConfigured(profile:profile,override:override,mapper:mapper)
            }
            return snapshot
        }
        catch {
            let original = error
            do { try device.reset() }
            catch {
                device.close(); self.device = nil; connectedPath = nil
                throw FlashMDError.invalid("\(original.localizedDescription) Reader cleanup failed. Unplug USB, then reconnect before scanning.")
            }
            device.close(); self.device = nil; connectedPath = nil; throw original
        }
    }
    public func prepareMDDumperROMWriting(_ cartridge: CartridgeSnapshot, progress: @escaping ProgressHandler) throws {
        guard !operationRunning, let dumper = device as? MDDumperDevice, let path = connectedPath else { throw FlashMDError.busy }
        operationRunning = true; pendingROMPreparation = nil
        defer {
            dumper.close(); device = nil; connectedPath = nil; operationRunning = false
        }
        pendingROMPreparation = (path,try dumper.prepareROMWriting(cartridge:cartridge,progress:progress))
    }
    public func backup(_ request: BackupRequest, progress: @escaping ProgressHandler) throws -> OperationResult {
        try perform { device in try OperationRunner.backup(device:device,request:request,progress:progress) }
    }
    public func analyze(_ cartridge: CartridgeSnapshot, progress: @escaping ProgressHandler) throws -> ROMContentAnalysis {
        guard !operationRunning, let device else { throw FlashMDError.busy }
        operationRunning = true
        var cleanupAttempted = false
        defer { operationRunning = false }
        do {
            let result = try ROMContentAnalysis.read(device:device,cartridge:cartridge,progress:progress)
            cleanupAttempted = true; try device.reset()
            return result
        } catch {
            let original = error
            if !cleanupAttempted {
                do { try device.reset() }
                catch {
                    device.close(); self.device = nil; connectedPath = nil
                    throw FlashMDError.invalid("\(original.localizedDescription) Reader cleanup failed. Unplug USB, then reconnect before scanning.")
                }
            }
            device.close(); self.device = nil; connectedPath = nil
            throw original
        }
    }
    public func write(_ plan: WritePlan, progress: @escaping ProgressHandler) throws -> OperationResult {
        try perform { device in try OperationRunner.write(device:device,plan:plan,progress:progress) }
    }
    private func perform(_ work: (any CartridgeDevice) throws -> OperationResult) throws -> OperationResult {
        guard !operationRunning, let device else { throw FlashMDError.invalid("Connect and inspect the programmer first.") }
        operationRunning = true
        var cleanupAttempted = false
        defer { operationRunning = false }
        do {
            let result = try work(device)
            do { cleanupAttempted = true; try device.reset() }
            catch {
                var manifest = result.manifest
                manifest.outcome = "cleanup failed"
                manifest.error = error.localizedDescription
                if let folder = result.folder { try? OperationRunner.writeManifest(manifest,folder:folder) }
                throw OperationFailure(result:.init(folder:result.folder,manifest:manifest),message:"Transfer verification completed, but the programmer could not return to read mode. Disconnect and reconnect before another operation. \(error.localizedDescription)")
            }
            return result
        }
        catch {
            var reported: any Error = error
            if !cleanupAttempted {
                do { try device.reset() }
                catch {
                    if let failure = reported as? OperationFailure {
                        var manifest = failure.result.manifest
                        manifest.phases.append("Reader cleanup failed")
                        manifest.error = (manifest.error ?? failure.message) + " Reader cleanup failed."
                        if let folder = failure.result.folder { try? OperationRunner.writeManifest(manifest,folder:folder) }
                        reported = OperationFailure(result:.init(folder:failure.result.folder,manifest:manifest),message:failure.message + " Reader state is uncertain. Unplug USB, then reconnect before scanning.")
                    } else {
                        reported = FlashMDError.invalid("\(reported.localizedDescription) Reader cleanup failed. Unplug USB, then reconnect before scanning.")
                    }
                }
            }
            device.close(); self.device = nil; connectedPath = nil; throw reported
        }
    }
}
