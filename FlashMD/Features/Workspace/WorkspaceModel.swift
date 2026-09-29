import FlashMDCore
import Foundation
import Observation
import AppKit
import IOKit.pwr_mgt

public enum WorkspacePage: String, CaseIterable, Identifiable {
    case cartridge, activity
    public var id: Self { self }
    var title: String { self == .cartridge ? "Cartridge" : "Activity" }
    var symbol: String { self == .cartridge ? "cpu" : "clock.arrow.circlepath" }
}
struct SelectedFile: Sendable, Identifiable {
    let id = UUID()
    let url: URL
    let data: Data
    let image: ROMImage?
    var bytes: Int { data.count }
    var name: String { url.lastPathComponent }
    init(url: URL, rom: Bool) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= (rom ? 16 * 1024 * 1024 : 65536) else { throw FlashMDError.invalid("Select a regular file within the supported size limit.") }
        self.url = url; self.data = try Data(contentsOf:url); self.image = rom ? try ROMImage(data:data) : nil
    }
}

@MainActor @Observable final class WorkspaceModel {
    var page: WorkspacePage? = .cartridge
    var direction = TransferDirection.backup
    var demoMode = false { didSet { guard oldValue != demoMode else { return }; invalidateReview(); Task { await updateConnectionMode() } } }
    var profile: CartridgeProfile = .automatic {
        didSet { UserDefaults.standard.set(profile.rawValue,forKey:"profile"); invalidateReview(); if connected { Task { await refresh() } } }
    }
    var ports: [SerialPort] = []
    var selectedPort = "" {
        didSet {
            invalidateReview()
            if oldValue != selectedPort, connected { connected = false; cartridge = nil }
        }
    }
    var connected = false
    var cartridge: CartridgeSnapshot?
    var isInspecting = false
    var backupROM = true
    var backupSRAM = true
    var writeROM = true { didSet { invalidateReview() } }
    var writeSRAM = false { didSet { invalidateReview() } }
    var backupBeforeWrite = true { didSet { UserDefaults.standard.set(backupBeforeWrite,forKey:"backupBeforeWrite"); invalidateReview() } }
    var verifyBackup = true { didSet { UserDefaults.standard.set(verifyBackup,forKey:"verifyBackup") } }
    var saveFormat: SaveFormat = .raw { didSet { invalidateReview() } }
    var forcedROMSize = ""
    var selectedROM: SelectedFile? { didSet { invalidateReview() } }
    var selectedSRAM: SelectedFile? { didSet { invalidateReview() } }
    var isImportingROM = false
    var isImportingSRAM = false
    var errorMessage: String?
    var completionMessage: String?
    var activity: [HistoryRecord] = []
    var reviewPlan: WritePlan?
    var showReview = false
    var showClearHistory = false
    var progress: OperationProgress?
    var operationStart: Date?
    var operationRunning = false
    var loadingFile = false
    var isBusy: Bool { isInspecting || operationRunning || loadingFile }
    var connectionLabel: String { demoMode ? "Demo mode" : (connected ? "Programmer connected" : "No programmer connected") }
    private let controller = ProgrammerController()
    private let history: HistoryStore
    private var operationTask: Task<Void,Never>?
    private var sleepAssertion: IOPMAssertionID = 0
    private var initialized = false
    private var progressID: UUID?
    init() {
        let folder = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("FlashMD",isDirectory:true)
        history = HistoryStore(url:folder.appendingPathComponent("history.json"))
        activity = history.load()
        if let raw = UserDefaults.standard.string(forKey:"profile"), let value = CartridgeProfile(rawValue:raw) { profile = value }
        backupBeforeWrite = UserDefaults.standard.object(forKey:"backupBeforeWrite") as? Bool ?? true
        verifyBackup = UserDefaults.standard.object(forKey:"verifyBackup") as? Bool ?? true
    }
    func initialize() async {
        guard !initialized else { return }; initialized = true
        await scanPorts()
        // Only auto-handshake when there is a single USB serial candidate. No ROM/SRAM writes are performed.
        if ports.count == 1 { selectedPort = ports[0].path; await connect() }
    }
    func scanPorts() async { ports = await controller.ports(); if !ports.contains(where: { $0.path == selectedPort }) { selectedPort = ports.first?.path ?? "" } }
    func connect() async {
        guard !isBusy, !demoMode, !selectedPort.isEmpty else { return }
        isInspecting = true; errorMessage = nil; cartridge = nil; invalidateReview()
        do {
            try await controller.connect(path:selectedPort); connected = true
            cartridge = try await controller.inspect(profile:profile)
            record(.init(title:"Cartridge inspected",detail:cartridge?.title ?? "Unknown cartridge"))
        } catch { connected = false; errorMessage = error.localizedDescription }
        isInspecting = false
    }
    func refresh() async {
        guard !isBusy else { return }
        if demoMode {
            cartridge = try? await DemoCartridgeService().inspect()
            record(.init(title:"Demo cartridge inspected",detail:"Sample data · no device access",demo:true)); return
        }
        if !connected { await scanPorts(); await connect(); return }
        isInspecting = true; invalidateReview()
        do { cartridge = try await controller.inspect(profile:profile); record(.init(title:"Cartridge inspected",detail:cartridge?.title ?? "Unknown")) }
        catch { connected = false; cartridge = nil; errorMessage = error.localizedDescription }
        isInspecting = false
    }
    func updateConnectionMode() async {
        guard !operationRunning else { return }
        try? await controller.disconnect(); connected = false; cartridge = nil
        if demoMode { await refresh() } else { await scanPorts() }
    }
    func selectFile(_ result: Result<URL,Error>, forROM: Bool) {
        guard !isBusy else { return }
        do {
            let url = try result.get(); loadingFile = true
            Task {
                defer { loadingFile = false }
                do {
                    let file = try await Task.detached(priority:.userInitiated) { try SelectedFile(url:url,rom:forROM) }.value
                    if forROM { selectedROM = file; page = .cartridge; direction = .write } else { selectedSRAM = file }
                    record(.init(title:forROM ? "ROM inspected" : "Save selected",detail:file.name))
                } catch { errorMessage = error.localizedDescription }
            }
        } catch { if (error as NSError).code != NSUserCancelledError { errorMessage = error.localizedDescription } }
    }
    func chooseDestination(prompt: String) -> URL? {
        let panel = NSOpenPanel(); panel.title = prompt; panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
    func startBackup() {
        guard !isBusy, !demoMode, connected, let cartridge else { return }
        do {
            let override = forcedROMSize.trimmingCharacters(in: .whitespacesAndNewlines)
            if backupROM, !override.isEmpty, Int(override) == nil { throw FlashMDError.invalid("Enter a whole ROM byte count.") }
            let count = backupROM ? (override.isEmpty ? cartridge.romSize?.bytes : Int(override)) : nil
            if backupROM, count == nil { throw FlashMDError.invalid("Set an exact ROM byte count for this invalid/blank header.") }
            if backupSRAM, cartridge.saveLayout == nil { throw FlashMDError.invalid("Choose a confirmed cartridge profile before backing up SRAM.") }
            guard let destination = chooseDestination(prompt:"Choose backup destination") else { return }
            let request = try BackupRequest(cartridge:cartridge,romBytes:count,saveLayout:backupSRAM ? cartridge.saveLayout : nil,saveFormat:saveFormat,verify:verifyBackup,destination:destination)
            beginOperation(title:"Cartridge backup") { controller,progress in try await controller.backup(request,progress:progress) }
        } catch { errorMessage = error.localizedDescription }
    }
    func prepareWrite() {
        guard !isBusy, !demoMode, connected, let cartridge else { return }
        do {
            if writeROM, selectedROM == nil { throw FlashMDError.invalid("Choose the ROM to write.") }
            if writeSRAM, selectedSRAM == nil { throw FlashMDError.invalid("Choose a separate save file to restore.") }
            let destination = backupBeforeWrite ? chooseDestination(prompt:"Choose pre-write backup destination") : nil
            if backupBeforeWrite, destination == nil { return }
            reviewPlan = try WritePlan(target:cartridge,image:writeROM ? selectedROM?.image : nil,romName:selectedROM?.name,
                save:writeSRAM ? selectedSRAM?.data : nil,saveName:selectedSRAM?.name,format:saveFormat,backupDestination:destination)
            showReview = true
        } catch { errorMessage = error.localizedDescription }
    }
    func confirmWrite() {
        guard !isBusy, !demoMode, let plan = reviewPlan else { return }
        showReview = false; reviewPlan = nil
        beginOperation(title:"Cartridge write") { controller,progress in try await controller.write(plan,progress:progress) }
    }
    private func beginOperation(title: String, work: @escaping @Sendable (ProgrammerController,@escaping ProgressHandler) async throws -> OperationResult) {
        invalidateReview()
        let eventID = UUID(), eventDate = Date()
        operationRunning = true; operationStart = eventDate; completionMessage = nil; errorMessage = nil
        progress = .init(.inspecting,detail:"Checking target cartridge")
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,IOPMAssertionLevel(kIOPMAssertionLevelOn),"FlashMD cartridge transfer" as CFString,&sleepAssertion)
        record(.init(title:title,detail:"Started; an app exit before completion leaves this operation interrupted.",outcome:"started",id:eventID,date:eventDate))
        let identifier = UUID()
        progressID = identifier
        operationTask = Task {
            defer {
                progressID = nil; operationRunning = false; operationTask = nil
                if sleepAssertion != 0 { IOPMAssertionRelease(sleepAssertion); sleepAssertion = 0 }
            }
            do {
                let model = self
                let result = try await work(controller) { [weak model] value in
                    Task { @MainActor [weak model] in
                        if model?.progressID == identifier { model?.progress = value }
                    }
                }
                progressID = nil
                record(.init(title:title,detail:result.manifest.phases.joined(separator:" · "),outcome:result.manifest.outcome,result:result,id:eventID,date:eventDate))
                completionMessage = title == "Cartridge backup" ? (verifyBackup ? "Backup completed and compared with a second read." : "Backup completed. A second-read verification was not requested.") : "Write completed. All written contents passed readback verification."
                progress = .init(.completed,detail:completionMessage ?? "Completed")
                cartridge = try? await controller.inspect(profile:profile)
            } catch {
                let failure = error as? OperationFailure
                record(.init(title:title,detail:error.localizedDescription,outcome:failure?.result.manifest.outcome ?? "failed",result:failure?.result,id:eventID,date:eventDate))
                progressID = nil
                errorMessage = error.localizedDescription
                let cancelled = error is CancellationError || failure?.result.manifest.outcome == "cancelled"
                progress = .init(cancelled ? .cancelled : .failed,detail:error.localizedDescription)
                connected = false; cartridge = nil
            }
        }
    }
    func cancel() { operationTask?.cancel(); progress = .init(progress?.phase ?? .cancelled,detail:"Stopping at the next safe boundary…",cancellable:false) }
    func handleSleep() { if operationRunning { cancel() } }
    func invalidateReview() { reviewPlan = nil; showReview = false }
    func record(_ record: HistoryRecord) {
        activity.removeAll { $0.id == record.id }
        activity.insert(record,at:0)
        do { try history.save(activity) } catch { errorMessage = "Activity could not be saved: \(error.localizedDescription)" }
    }
    func clearHistory() {
        do { try history.clear(); activity = [] } catch { errorMessage = error.localizedDescription }
    }
}
