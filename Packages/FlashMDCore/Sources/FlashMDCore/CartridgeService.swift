import Foundation

public protocol CartridgeService: Sendable { func inspect() async throws -> CartridgeSnapshot }
public enum CartridgeServiceError: LocalizedError, Sendable, Equatable {
    case transportUnavailable
    public var errorDescription: String? { "Connect a FlashKit MD programmer and choose its USB serial port." }
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
    private var device: (any CartridgeDevice)?
    private var connectedPath: String?
    private var operationRunning = false
    public init() {}
    public func ports() -> [SerialPort] { SerialPort.discover() }
    public func connect(path: String) throws {
        guard !operationRunning else { throw FlashMDError.busy }
        device?.close(); device = nil; connectedPath = nil
        let transport = try SerialTransport(path: path)
        device = try FlashKitDevice(transport: transport,path:path); connectedPath = path
    }
    public func disconnect() throws {
        guard !operationRunning else { throw FlashMDError.busy }
        device?.close(); device = nil; connectedPath = nil
    }
    public func inspect(profile: CartridgeProfile, override: CartridgeConfiguration? = nil, mapper: ROMMapper = .automatic) throws -> CartridgeSnapshot {
        guard !operationRunning, let device else { throw FlashMDError.invalid("Connect a programmer before inspecting a cartridge.") }
        do { return try device.inspect(profile:profile,mapper:mapper).applying(override) }
        catch { device.close(); self.device = nil; connectedPath = nil; throw error }
    }
    public func backup(_ request: BackupRequest, progress: @escaping ProgressHandler) throws -> OperationResult {
        try perform { device in try OperationRunner.backup(device:device,request:request,progress:progress) }
    }
    public func analyze(_ cartridge: CartridgeSnapshot, progress: @escaping ProgressHandler) throws -> ROMContentAnalysis {
        guard !operationRunning, let device else { throw FlashMDError.busy }
        operationRunning = true
        defer { operationRunning = false; try? device.reset() }
        return try ROMContentAnalysis.read(device:device,cartridge:cartridge,progress:progress)
    }
    public func write(_ plan: WritePlan, progress: @escaping ProgressHandler) throws -> OperationResult {
        try perform { device in try OperationRunner.write(device:device,plan:plan,progress:progress) }
    }
    private func perform(_ work: (any CartridgeDevice) throws -> OperationResult) throws -> OperationResult {
        guard !operationRunning, let device else { throw FlashMDError.invalid("Connect and inspect the programmer first.") }
        operationRunning = true
        defer { operationRunning = false }
        do {
            let result = try work(device)
            do { try device.reset() }
            catch {
                var manifest = result.manifest
                manifest.outcome = "cleanup failed"
                manifest.error = error.localizedDescription
                throw OperationFailure(result:.init(folder:result.folder,manifest:manifest),message:"Transfer verification completed, but the programmer could not return to read mode. Disconnect and reconnect before another operation. \(error.localizedDescription)")
            }
            return result
        }
        catch { try? device.reset(); device.close(); self.device = nil; connectedPath = nil; throw error }
    }
}
