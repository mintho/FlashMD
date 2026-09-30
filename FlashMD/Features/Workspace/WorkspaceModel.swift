import FlashMDCore
import Foundation
import Observation
import AppKit
import IOKit.pwr_mgt

enum ROMBackupLength: String, CaseIterable, Identifiable {
    case automatic, full, custom
    var id: Self { self }
    var title: String { switch self { case .automatic: "Game size (automatic)"; case .full: "All accessible ROM"; case .custom: "Custom byte count" } }
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
    var direction = TransferDirection.backup
    var demoMode = false { didSet { guard oldValue != demoMode else { return }; invalidateReview(); Task { await updateConnectionMode() } } }
    var profile: CartridgeProfile = .automatic { didSet { configurationChanged() } }
    var manualConfiguration = false { didSet { configurationChanged() } }
    var capacityChoice = 0x400000 { didSet { configurationChanged() } }
    var manualSave = false { didSet { configurationChanged() } }
    var saveStart = "200001" { didSet { configurationChanged() } }
    var saveEnd = "20FFFF" { didSet { configurationChanged() } }
    var saveLane = 1 { didSet { configurationChanged() } }
    var portOverride = false
    var showHistory = false
    var scanStep = "Connecting to your programmer"
    var backupLength = ROMBackupLength.automatic
    var configurationPending = false
    var configurationOverride: CartridgeConfiguration? {
        get throws {
            guard manualConfiguration else { return nil }
            var layout: SRAMLayout?
            if manualSave {
                guard let start = Int(saveStart,radix:16), let end = Int(saveEnd,radix:16) else { throw FlashMDError.invalid("Enter SRAM start and end addresses in hexadecimal, such as 200001 and 20FFFF.") }
                layout = try SRAMLayout(start:start,end:end,lane:saveLane == 2 ? nil : saveLane)
            }
            return try .init(romCapacity:capacityChoice,saveLayout:layout)
        }
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
    var operationTitle = ""
    var operationCartridge: CartridgeSnapshot?
    var operationResult: OperationResult?
    var operationEnd: Date?
    var operationStart: Date?
    var operationRunning = false
    var loadingFile = false
    var isBusy: Bool { isInspecting || operationRunning || loadingFile }
    var canBackup: Bool { !isBusy && !configurationPending && !demoMode && connected && cartridge != nil && (backupROM || backupSRAM) }
    var canReviewWrite: Bool {
        guard !isBusy, !configurationPending, !demoMode, connected, let cartridge, writeROM || writeSRAM else { return false }
        return (!writeROM || (cartridge.canWrite && selectedROM != nil)) && (!writeSRAM || (cartridge.canRestoreSave && selectedSRAM != nil))
    }
    var backupSizeDescription: String {
        switch backupLength {
        case .automatic: return (cartridge?.romSize ?? cartridge?.flashCapacity).map { formatBytes($0.bytes) } ?? "Size not yet known"
        case .full: return cartridge?.flashCapacity.map { formatBytes($0.bytes) + " · full range" } ?? "Capacity unknown"
        case .custom: return Int(forcedROMSize).map { formatBytes($0) + " · custom" } ?? "Set size in Advanced Options"
        }
    }
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
        backupBeforeWrite = UserDefaults.standard.object(forKey:"backupBeforeWrite") as? Bool ?? true
        verifyBackup = UserDefaults.standard.object(forKey:"verifyBackup") as? Bool ?? true
    }
    func initialize() async {
        guard !initialized else { return }; initialized = true
        await scanPorts()
    }
    func scanPorts() async {
        ports = await controller.ports()
        if !ports.contains(where: { $0.path == selectedPort }) { selectedPort = ports.first?.path ?? "" }
    }
    // All scan entry points share this flow, including reconnect and the menu shortcut.
    func refresh() async {
        guard !isBusy else { return }
        isInspecting = true; errorMessage = nil; clearOperationPresentation(); cartridge = nil; invalidateReview()
        defer { isInspecting = false }
        if demoMode {
            scanStep = "Reading sample cartridge"
            try? await Task.sleep(for:.milliseconds(900))
            cartridge = try? await DemoCartridgeService().inspect()
            record(.init(title:"Demo cartridge inspected",detail:"Sample data · no device access",demo:true)); return
        }
        scanStep = "Finding your FlashKit programmer"
        await scanPorts()
        let candidates = portOverride ? ports.filter { $0.path == selectedPort } : ports
        guard !candidates.isEmpty else { connected = false; errorMessage = "No FlashKit USB device was found. Connect your programmer, then scan again."; return }
        var lastError: Error?
        for port in candidates {
            do {
                scanStep = "Connecting to your programmer"
                selectedPort = port.path
                try await controller.connect(path:port.path)
                connected = true
                scanStep = "Identifying flash and reading game information"
                let snapshot = try await controller.inspect(profile:profile,override:configurationOverride)
                cartridge = snapshot
                configurationPending = false
                backupSRAM = snapshot.saveLayout != nil
                if !snapshot.canWrite { writeROM = false }
                if snapshot.saveLayout == nil { writeSRAM = false }
                record(.init(title:"Cartridge inspected",detail:snapshot.title))
                return
            } catch { lastError = error; connected = false }
        }
        errorMessage = lastError?.localizedDescription ?? "The programmer could not be connected. Try another USB port."
    }
    func configurationChanged() {
        invalidateReview()
        configurationPending = cartridge != nil
    }
    func useDetectedConfiguration() {
        guard let cartridge else { return }
        // Preserve the detected values when opening the override editor.
        capacityChoice = cartridge.flashCapacity?.bytes ?? 0x400000
        manualSave = cartridge.saveLayout != nil
        if let layout = cartridge.saveLayout {
            saveStart = String(layout.start,radix:16).uppercased(); saveEnd = String(layout.end,radix:16).uppercased()
            saveLane = layout.lane ?? 2
        }
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
                    if forROM { selectedROM = file; writeROM = true; direction = .write } else { selectedSRAM = file; writeSRAM = true }
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
        guard !isBusy, !configurationPending, !demoMode, connected, let cartridge else { return }
        do {
            let override = forcedROMSize.trimmingCharacters(in: .whitespacesAndNewlines)
            if backupROM, backupLength == .custom, !override.isEmpty, Int(override) == nil { throw FlashMDError.invalid("Enter a whole ROM byte count.") }
            let count: Int?
            if !backupROM { count = nil }
            else {
                switch backupLength {
                case .automatic: count = cartridge.romSize?.bytes ?? cartridge.flashCapacity?.bytes
                case .full: count = cartridge.flashCapacity?.bytes
                case .custom: count = Int(override)
                }
            }
            if backupROM, count == nil { throw FlashMDError.invalid("Choose a ROM backup length in Advanced Options. This cartridge has no usable size information.") }
            if backupSRAM, cartridge.saveLayout == nil { throw FlashMDError.invalid("No SRAM range was detected. Choose ROM only or configure save memory in Advanced Options.") }
            guard let destination = chooseDestination(prompt:"Choose backup destination") else { return }
            let request = try BackupRequest(cartridge:cartridge,romBytes:count,saveLayout:backupSRAM ? cartridge.saveLayout : nil,saveFormat:saveFormat,verify:verifyBackup,destination:destination)
            beginOperation(title:"Cartridge backup") { controller,progress in try await controller.backup(request,progress:progress) }
        } catch { errorMessage = error.localizedDescription }
    }
    func prepareWrite() {
        guard !isBusy, !configurationPending, !demoMode, connected, let cartridge else { return }
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
        operationTitle = title; operationCartridge = cartridge; operationResult = nil; operationEnd = nil
        operationRunning = true; operationStart = eventDate; completionMessage = nil; errorMessage = nil
        progress = .init(.inspecting,detail:"Checking target cartridge")
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,IOPMAssertionLevel(kIOPMAssertionLevelOn),"FlashMD cartridge transfer" as CFString,&sleepAssertion)
        record(.init(title:title,detail:"Started; an app exit before completion leaves this operation interrupted.",outcome:"started",id:eventID,date:eventDate))
        let identifier = UUID()
        progressID = identifier
        operationTask = Task {
            defer {
                progressID = nil; operationEnd = Date(); operationRunning = false; operationTask = nil
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
                operationResult = result
                record(.init(title:title,detail:result.manifest.phases.joined(separator:" · "),outcome:result.manifest.outcome,result:result,id:eventID,date:eventDate))
                completionMessage = title == "Cartridge backup" ? (verifyBackup ? "Backup completed and compared with a second read." : "Backup completed. A second-read verification was not requested.") : "Write completed. All written contents passed readback verification."
                progress = .init(.completed,detail:completionMessage ?? "Completed")
                cartridge = try? await controller.inspect(profile:profile,override:configurationOverride)
            } catch {
                let failure = error as? OperationFailure
                record(.init(title:title,detail:error.localizedDescription,outcome:failure?.result.manifest.outcome ?? "failed",result:failure?.result,id:eventID,date:eventDate))
                progressID = nil
                operationResult = failure?.result
                let cancelled = error is CancellationError || failure?.result.manifest.outcome == "cancelled"
                progress = .init(cancelled ? .cancelled : .failed,detail:error.localizedDescription)
                connected = false; cartridge = nil
            }
        }
    }
    func clearOperationPresentation() {
        guard !operationRunning else { return }
        progress = nil; completionMessage = nil; operationResult = nil; operationCartridge = nil
        operationStart = nil; operationEnd = nil; operationTitle = ""
    }
    func newTransfer() {
        guard !isBusy else { return }
        clearOperationPresentation()
        if !connected || cartridge == nil { Task { await refresh() } }
    }
    func revealOperationFolder() {
        if let folder = operationResult?.folder { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
    }
    func revealArtifact(_ artifact: BackupArtifact) {
        if let folder = operationResult?.folder {
            NSWorkspace.shared.activateFileViewerSelecting([folder.appendingPathComponent(artifact.filename)])
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
