import FlashMDCore
import Foundation
import Observation
import AppKit
import IOKit.pwr_mgt

enum ROMBackupLength: String, CaseIterable, Identifiable {
    case suggested, complete, header, custom
    var id: Self { self }
    var title: String { switch self { case .suggested: "Suggested size"; case .complete: "Complete ROM"; case .header: "Header size"; case .custom: "Custom size" } }
}
enum SaveImportFormat: String, CaseIterable, Identifiable {
    case automatic, packed, raw
    var id: Self { self }
    var title: String { switch self { case .automatic: "Automatic"; case .packed: SaveFormat.packed.displayName; case .raw: SaveFormat.raw.displayName } }
    var explanation: String { switch self {
        case .automatic: "Matches the file size to the cartridge's SRAM layout."
        case .packed: "Contains only the SRAM save data."
        case .raw: "Includes both byte lanes and unused bytes."
    } }
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

enum ROMWritingPreparationStage { case preparing, restart, reconnecting }

@MainActor @Observable final class WorkspaceModel {
    var direction = TransferDirection.backup
    var demoMode = false { didSet { guard oldValue != demoMode else { return }; invalidateReview(); Task { await updateConnectionMode() } } }
    var mapper = ROMMapper.automatic { didSet { configurationChanged() } }
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
    var backupLength = ROMBackupLength.suggested
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
    var ports: [ProgrammerEndpoint] = []
    var connectedProgrammer: ProgrammerKind?
    var selectedPort = "" {
        didSet {
            invalidateReview()
            if oldValue != selectedPort, connected { connected = false; cartridge = nil; contentAnalysis = nil; clearTitleOverride() }
        }
    }
    var connected = false
    var cartridge: CartridgeSnapshot?
    var contentAnalysis: ROMContentAnalysis?
    private(set) var titleOverride: String?
    private var titleOverrideKey: String?
    private let titleOverridesDefaultsKey = "cartridgeTitleOverrides"
    func displayTitle(for snapshot: CartridgeSnapshot) -> String {
        titleOverride ?? snapshot.title
    }
    func setCartridgeTitle(_ title: String?) {
        guard !isBusy, !showReview, let cartridge else { return }
        let trimmed = title?.trimmingCharacters(in:.whitespacesAndNewlines)
        if let trimmed, trimmed.isEmpty || trimmed.count > 128 || trimmed.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) { return }
        titleOverride = trimmed == cartridge.title ? nil : trimmed
        if let key = titleOverrideKey {
            var titles = UserDefaults.standard.dictionary(forKey:titleOverridesDefaultsKey) as? [String:String] ?? [:]
            titles[key] = titleOverride
            UserDefaults.standard.set(titles,forKey:titleOverridesDefaultsKey)
        }
    }
    private func clearTitleOverride() {
        titleOverride = nil; titleOverrideKey = nil
    }
    private func loadTitleOverride(from analysis: ROMContentAnalysis?) {
        // A generic header alone cannot distinguish games built with the same SDK.
        titleOverrideKey = analysis.map { "rom:\($0.identitySHA256 ?? $0.sha256)" }
        titleOverride = titleOverrideKey.flatMap { key in
            let titles = UserDefaults.standard.dictionary(forKey:titleOverridesDefaultsKey) as? [String:String]
            return titles?[key] ?? analysis.flatMap { titles?["rom:\($0.sha256)"] }
        }
    }
    var isInspecting = false
    var backupROM = true
    var backupSRAM = true
    var writeROM = true { didSet { invalidateReview() } }
    var writeSRAM = false { didSet { invalidateReview() } }
    var clearUnusedROM = true { didSet { invalidateReview() } }
    var verifyBackup = true { didSet { UserDefaults.standard.set(verifyBackup,forKey:"verifyBackup") } }
    var mdDumperStreaming = false {
        didSet {
            UserDefaults.standard.set(mdDumperStreaming,forKey:"mdDumperStreaming")
        }
    }
    var mdDumperStreamingSupported = false
    private(set) var romWritingPreparation: ROMWritingPreparationStage?
    private(set) var romPreparationMessage: String?
    private var canPrepareMDDumperROMWriting: Bool {
        !isBusy && connected && !configurationPending && !demoMode && mdDumperStreamingSupported &&
        cartridge?.readerKind == .mdDumper && cartridge?.mapper == .linear && cartridge?.canWrite != true
    }
    var canSelectROMForWriting: Bool { cartridge?.canWrite == true || canPrepareMDDumperROMWriting }
    private func prepareMDDumperROMWriting(_ cartridge: CartridgeSnapshot) {
        invalidateReview(); errorMessage = nil; romPreparationMessage = nil
        romWritingPreparation = .preparing; operationRunning = true
        operationTitle = "Prepare ROM writing"; operationCartridge = cartridge
        operationStart = Date(); operationEnd = nil; operationResult = nil
        progress = .init(.inspecting,detail:"Checking cartridge ROM")
        let identifier = UUID(); progressID = identifier
        operationTask = Task {
            defer { operationRunning = false; operationTask = nil; progressID = nil }
            do {
                let model = self
                try await controller.prepareMDDumperROMWriting(cartridge) { [weak model] value in
                    Task { @MainActor [weak model] in
                        if model?.progressID == identifier { model?.progress = value }
                    }
                }
                try Task.checkCancellation()
                romWritingPreparation = .restart
                record(.init(title:"ROM writing prepared",detail:"Flash identified; reader restart required. No ROM or SRAM written."))
            } catch {
                try? await controller.cancelMDDumperROMWritingPreparation()
                romWritingPreparation = nil
                progress = .init(error is CancellationError ? .cancelled : .failed,
                    detail:error is CancellationError ? "Preparation cancelled. No ROM or SRAM written. Restart the MD Dumper before scanning." : error.localizedDescription)
                operationEnd = Date(); self.cartridge = nil
                record(.init(title:"ROM writing preparation",detail:error.localizedDescription,outcome:"failed"))
            }
            connected = false
        }
    }
    func continueROMWritingPreparation() {
        guard romWritingPreparation == .restart, !operationRunning else { return }
        romWritingPreparation = .reconnecting; romPreparationMessage = nil; operationRunning = true
        progress = .init(.inspecting,detail:"Connecting to MD Dumper")
        let identifier = UUID(); progressID = identifier
        operationTask = Task {
            defer { operationRunning = false; operationTask = nil; progressID = nil }
            do {
                let model = self
                let snapshot = try await controller.continueMDDumperROMWriting(profile:profile,override:configurationOverride,
                    mapper:mapper,mdDumperStreaming:mdDumperStreaming) { [weak model] value in
                    Task { @MainActor [weak model] in
                        if model?.progressID == identifier { model?.progress = value }
                    }
                }
                try Task.checkCancellation()
                guard snapshot.canWrite else { throw FlashMDError.invalid("ROM writing is unavailable with this cartridge configuration. Cancel and scan again.") }
                cartridge = snapshot; connected = true; connectedProgrammer = .mdDumper
                contentAnalysis = nil; configurationPending = false
                romWritingPreparation = nil; operationRunning = false; progressID = nil
                clearOperationPresentation()
                record(.init(title:"Cartridge ready for ROM writing",detail:"Original ROM verified after restart; flash capacity confirmed."))
                prepareWrite()
            } catch {
                connected = false
                if error is CancellationError {
                    try? await controller.cancelMDDumperROMWritingPreparation()
                    romWritingPreparation = nil; cartridge = nil; operationEnd = Date()
                    progress = .init(.cancelled,detail:"ROM writing cancelled. No ROM or SRAM written. Restart the MD Dumper before scanning.")
                    record(.init(title:"ROM writing cancelled",detail:"Cartridge check cancelled; no ROM or SRAM written.",outcome:"cancelled"))
                } else {
                    romWritingPreparation = .restart
                    romPreparationMessage = error.localizedDescription
                    record(.init(title:"ROM writing paused",detail:error.localizedDescription,outcome:"paused"))
                }
            }
        }
    }
    func cancelROMWritingPreparation() {
        guard romWritingPreparation == .restart, !operationRunning else { return }
        operationRunning = true
        operationTask = Task {
            defer { operationRunning = false; operationTask = nil }
            do { try await controller.cancelMDDumperROMWritingPreparation() }
            catch { errorMessage = error.localizedDescription }
            romWritingPreparation = nil; romPreparationMessage = nil; connected = false; cartridge = nil
            progress = .init(.cancelled,detail:"ROM writing cancelled. No ROM or SRAM written. Restart the MD Dumper before scanning.")
            operationEnd = Date()
            record(.init(title:"ROM writing cancelled",detail:"Preparation discarded; no ROM or SRAM written.",outcome:"cancelled"))
        }
    }
    var pendingSaveRecovery = SaveRecoveryJournal.pendingFolders()
    func showSaveRecovery() { NSWorkspace.shared.open(SaveRecoveryJournal.directory) }
    var backupVerificationRequired: Bool {
        guard let cartridge else { return false }
        return cartridge.mapper != .linear || cartridge.readerKind == .mdDumper && mdDumperStreaming && mdDumperStreamingSupported
    }
    var backupWillBeVerified: Bool { verifyBackup || backupVerificationRequired }
    var savePanelTitle: String { cartridge?.serialSave != nil ? "SPI save data" : "SRAM data" }
    var backupSaveSubtitle: String {
        guard let cartridge else { return "Save backup not supported yet" }
        if let serial = cartridge.serialSave {
            return cartridge.canBackupSave ? formatBytes(serial.addressBytes) + " address range · backup only" : "Save backup unavailable on this reader"
        }
        guard cartridge.canBackupSave, let layout = cartridge.saveLayout else { return cartridge.saveStatus.explanation }
        let note = cartridge.saveStatus == .confirmed || cartridge.canCheckSaveWriting ? " of save data" : cartridge.saveStatus == .readOnly ? " · backup only" : " · unconfirmed SRAM"
        return formatBytes(layout.activeBytes) + note
    }
    var saveFormat: SaveFormat = .packed
    var saveImportFormat: SaveImportFormat = .automatic { didSet { invalidateReview() } }
    var backupLengthExplanation: String { switch backupLength {
        case .suggested: "Uses the size suggested by the scan."
        case .complete: "Includes all accessible ROM, even unused space."
        case .header: "Uses the game's declared size. May miss data."
        case .custom: "Reads the number of bytes you enter."
    } }
    func saveFormatTitle(_ format: SaveFormat) -> String {
        format == .raw && cartridge?.readerKind == .mdDumper ? "Padded bus format" : format.displayName
    }
    var saveFormatExplanation: String {
        if saveFormat == .raw, cartridge?.readerKind == .mdDumper { return "Stores SRAM with zero padding on the unused lane." }
        return saveFormat == .packed ? SaveImportFormat.packed.explanation : SaveImportFormat.raw.explanation
    }
    var mapperExplanation: String { switch mapper {
        case .automatic: "Uses mapper hints and checks bank switching."
        case .linear: "Reads ROM directly, without bank switching."
        case .segaSSF2: "Checks Sega SSF2-style bank switching."
        case .pierSolar: "Checks Pier Solar’s 8 MiB bank switching."
    } }
    var memoryConfigurationUnavailable: Bool { cartridge.map { $0.romAccess != .linear } ?? false }
    var profileExplanation: String {
        if memoryConfigurationUnavailable { return "Not available for this ROM mapper." }
        if manualConfiguration { return "Replaced by the memory settings below." }
        switch profile {
        case .automatic: return "Uses scanned ROM capacity and header SRAM."
        case .krikzz4M: return "Limits ROM to 2 MiB; uses 32 KiB odd-lane SRAM."
        case .linearROMOnly: return "Allows up to 4 MiB ROM; disables SRAM."
        }
    }
    var memoryOverrideExplanation: String {
        if memoryConfigurationUnavailable { return "Not available for this ROM mapper." }
        return manualConfiguration ? "Uses the capacity and SRAM settings below." : "Uses the selected cartridge configuration."
    }
    var saveLaneExplanation: String { switch saveLane {
        case 0: "Reads even-address bytes; writing is unsupported."
        case 2: "Uses both lanes: even start, odd end."
        default: "Uses odd-address bytes for 8-bit SRAM."
    } }
    var programmerExplanation: String {
        if ports.isEmpty { return "Connect a supported USB programmer." }
        return selectedPort.isEmpty ? "Select the programmer to use." : "Uses this programmer for the next connection."
    }
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
    var isBusy: Bool { isInspecting || operationRunning || loadingFile || romWritingPreparation != nil }
    var canBackup: Bool { !isBusy && !configurationPending && !demoMode && connected && cartridge != nil && (backupROM || backupSRAM) && (!backupROM || cartridge?.canBackupROM == true) && (!backupSRAM || cartridge?.canBackupSave == true) }
    var canReviewWrite: Bool {
        guard !isBusy, !configurationPending, !demoMode, connected, let cartridge, writeROM || writeSRAM else { return false }
        return (!writeROM || (canSelectROMForWriting && selectedROM != nil)) && (!writeSRAM || (cartridge.canStartSaveWrite && selectedSRAM != nil))
    }
    var backupSizeDescription: String {
        if let cartridge, !cartridge.canBackupROM { return "ROM backup unavailable" }
        switch backupLength {
        case .complete: return cartridge.map { formatBytes($0.romReadLimit) + " · full scan range" } ?? "Size not yet known"
        case .suggested:
            if let bytes = contentAnalysis?.suggestedBytes { return formatBytes(bytes) + " · suggested export" }
            return cartridge.map { formatBytes($0.romReadLimit) + " · size unconfirmed" } ?? "Scan to analyze contents"
        case .header: return cartridge?.romSize.map { formatBytes($0.bytes) + " · header only" } ?? "No valid header size"
        case .custom: return Int(forcedROMSize).map { formatBytes($0) + " · custom" } ?? "Set size in Advanced Settings"
        }
    }
    var connectionLabel: String { demoMode ? "Demo mode" : (connected ? "\(connectedProgrammer?.displayName ?? "Programmer") connected" : "No programmer connected") }
    private let controller: ProgrammerController
    private let history: HistoryStore
    private var operationTask: Task<Void,Never>?
    private var sleepAssertion: IOPMAssertionID = 0
    private var initialized = false
    private var progressID: UUID?
    init(controller: ProgrammerController = ProgrammerController(), historyURL: URL? = nil) {
        self.controller = controller
        let folder = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("FlashMD",isDirectory:true)
        history = HistoryStore(url:historyURL ?? folder.appendingPathComponent("history.json"))
        activity = history.load()
        verifyBackup = UserDefaults.standard.object(forKey:"verifyBackup") as? Bool ?? true
        mdDumperStreaming = UserDefaults.standard.bool(forKey:"mdDumperStreaming")
    }
    func initialize() async {
        guard !initialized else { return }; initialized = true
        await scanPorts()
    }
    func scanPorts() async {
        ports = await controller.endpoints()
        if !ports.contains(where: { $0.id == selectedPort }) { selectedPort = ports.first?.id ?? "" }
    }
    // All scan entry points share this flow, including reconnect and the menu shortcut.
    func refresh() async {
        guard !isBusy else { return }
        isInspecting = true; errorMessage = nil; clearOperationPresentation(); cartridge = nil; contentAnalysis = nil; invalidateReview()
        clearTitleOverride()
        defer { isInspecting = false }
        if demoMode {
            scanStep = "Reading sample cartridge"
            try? await Task.sleep(for:.milliseconds(900))
            cartridge = try? await DemoCartridgeService().inspect()
            record(.init(title:"Demo cartridge inspected",detail:"Sample data · no device access",demo:true)); return
        }
        scanStep = "Finding your USB programmer"
        await scanPorts()
        let candidates = portOverride ? ports.filter { $0.id == selectedPort } : ports
        guard !candidates.isEmpty else { connected = false; errorMessage = "No programmer found. Connect a FlashKit or MD Dumper, then scan again."; return }
        var lastError: Error?
        for port in candidates {
            do {
                scanStep = "Connecting to your programmer"
                selectedPort = port.id
                let model = self
                let scan = try await controller.scan(path:port.id,profile:profile,override:configurationOverride,
                    mapper:mapper,mdDumperStreaming:mdDumperStreaming) { [weak model] value in
                    Task { @MainActor [weak model] in
                        guard model?.isInspecting == true else { return }
                        model?.scanStep = value.total > 0 ? "Analyzing ROM contents · \(value.completed * 100 / value.total)%" : value.detail
                    }
                }
                for failure in scan.failures {
                    record(.init(title:"Scan repeated",detail:failure.diagnosticText,outcome:"retried"))
                }
                let snapshot = scan.cartridge, analysis = scan.analysis
                mdDumperStreamingSupported = await controller.supportsMDDumperStreaming()
                connected = true; connectedProgrammer = port.kind
                cartridge = snapshot
                contentAnalysis = analysis
                loadTitleOverride(from:analysis)
                configurationPending = false
                backupSRAM = snapshot.canBackupSave
                if !canSelectROMForWriting { writeROM = false }
                if !snapshot.canStartSaveWrite { writeSRAM = false }
                record(.init(title:"Cartridge inspected",detail:snapshot.title))
                return
            } catch {
                lastError = error; connected = false
                if let failure = error as? CartridgeScanFailure {
                    for attempt in failure.failures {
                        record(.init(title:"Scan failed",detail:attempt.diagnosticText,outcome:"failed"))
                    }
                } else {
                    record(.init(title:"Scan failed",detail:"\(port.kind.displayName): \(error.localizedDescription)",outcome:"failed"))
                }
                if Task.isCancelled || (error as? CartridgeScanFailure)?.underlying is CancellationError { break }
            }
        }
        errorMessage = lastError?.localizedDescription ?? "The programmer could not be connected. Try another USB port."
    }
    func configurationChanged() {
        invalidateReview()
        contentAnalysis = nil
        configurationPending = cartridge != nil
    }
    func useDetectedConfiguration() {
        guard let cartridge else { return }
        // Preserve the detected values when opening the override editor.
        capacityChoice = cartridge.romReadLimit
        manualSave = cartridge.saveLayout != nil
        if let layout = cartridge.saveLayout {
            saveStart = String(layout.start,radix:16).uppercased(); saveEnd = String(layout.end,radix:16).uppercased()
            saveLane = layout.lane ?? 2
        }
    }
    func updateConnectionMode() async {
        guard !operationRunning else { return }
        try? await controller.disconnect(); connected = false; cartridge = nil; contentAnalysis = nil
        clearTitleOverride()
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
                case .complete: count = cartridge.romReadLimit
                case .suggested: count = contentAnalysis?.suggestedBytes ?? cartridge.romReadLimit
                case .header: count = cartridge.romSize?.bytes
                case .custom: count = Int(override)
                }
            }
            if backupROM, count == nil { throw FlashMDError.invalid("Choose a ROM backup length in Advanced Settings. This cartridge has no usable size information.") }
            if backupSRAM, cartridge.saveLayout == nil, cartridge.serialSave == nil { throw FlashMDError.invalid("No SRAM range was detected. Choose ROM only or configure save memory in Advanced Settings.") }
            guard let destination = chooseDestination(prompt:"Choose backup destination") else { return }
            let serial = backupSRAM && cartridge.serialSave != nil
            let request = try BackupRequest(cartridge:cartridge,romBytes:count,saveLayout:backupSRAM ? cartridge.saveLayout : nil,saveFormat:serial ? .packed : saveFormat,verify:backupWillBeVerified,destination:destination,contentAnalysis:contentAnalysis,titleOverride:titleOverride,includeSerialSave:serial)
            beginOperation(title:"Cartridge backup") { controller,progress in try await controller.backup(request,progress:progress) }
        } catch { errorMessage = error.localizedDescription }
    }
    func prepareWrite() {
        guard !isBusy, !configurationPending, !demoMode, connected, let cartridge else { return }
        do {
            if writeROM, selectedROM == nil { throw FlashMDError.invalid("Choose the ROM to write.") }
            if writeSRAM, selectedSRAM == nil { throw FlashMDError.invalid("Choose a separate save file to restore.") }
            let image = writeROM ? selectedROM?.image : nil
            let save = writeSRAM ? selectedSRAM?.data : nil
            if let image, canPrepareMDDumperROMWriting {
                guard ROMMapper.detect(image.metadata) == .linear else { throw FlashMDError.invalid("This game needs bank switching. Writing it to a linear cartridge is not supported.") }
                let readRange = min(cartridge.flashCapacity?.bytes ?? 0x400000,cartridge.saveLayout?.base ?? 0x400000,cartridge.metadata?.saveLayout?.base ?? 0x400000)
                guard image.data.count <= readRange else { throw FlashMDError.invalid("The ROM file exceeds the cartridge's accessible range.") }
                guard (image.metadata.declaredROMBytes ?? 0) <= image.data.count else { throw FlashMDError.invalid("The ROM file is shorter than its header declares. Check that the backup is complete.") }
                guard image.metadata.saveWarning == nil, cartridge.metadata?.saveWarning == nil else { throw FlashMDError.invalid("This game or cartridge uses an unsupported save type.") }
                prepareMDDumperROMWriting(cartridge)
                return
            }
            func plan(_ format: SaveFormat, save: Data?) throws -> WritePlan {
                try WritePlan(target:cartridge,image:image,romName:writeROM ? selectedROM?.name : nil,
                    save:save,saveName:writeSRAM ? selectedSRAM?.name : nil,format:format,backupDestination:nil,clearUnusedROM:clearUnusedROM)
            }
            // Validate ROM independently so an invalid ROM is never reported as a save-format problem.
            if image != nil { _ = try plan(.packed,save:nil) }
            if let save, saveImportFormat == .automatic {
                let candidates = SaveFormat.allCases.compactMap { try? plan($0,save:save) }
                guard let first = candidates.first else { throw FlashMDError.invalid("This save file does not match the cartridge. Check the save format and SRAM settings in Advanced Settings.") }
                guard candidates.allSatisfy({ $0.save == first.save && $0.saveLayout == first.saveLayout }) else {
                    throw FlashMDError.invalid("The SRAM format is ambiguous. Choose an SRAM file format in Advanced Settings.")
                }
                reviewPlan = first
            } else {
                reviewPlan = try plan(saveImportFormat == .raw ? .raw : .packed,save:save)
            }
            showReview = true
        } catch { errorMessage = error.localizedDescription }
    }
    var writeActionTitle: String {
        guard let plan = reviewPlan else { return "Write" }
        if plan.rom != nil && plan.save != nil { return "Write Both" }
        return plan.rom != nil ? "Write ROM" : "Write Saves"
    }
    var writeConfirmationTitle: String {
        guard let plan = reviewPlan else { return "Write to cartridge?" }
        if plan.rom != nil && plan.save != nil { return "Replace game and saves?" }
        return plan.rom != nil ? "Replace cartridge ROM?" : "Replace cartridge saves?"
    }
    var writeConfirmationMessage: String {
        guard let plan = reviewPlan else { return "" }
        let change: String
        if plan.rom != nil && plan.save != nil { change = "The existing game and saves will be overwritten." }
        else if plan.rom != nil { change = "The existing game will be overwritten." + (plan.target.saveLayout != nil ? " SRAM saves will be preserved." : "") }
        else { change = "Existing cartridge saves will be overwritten." }
        let check = plan.target.canCheckSaveWriting ? "\n\nFlashMD will first check SRAM write access and restore the test bytes." : ""
        return "\(displayTitle(for:plan.target))\n\n\(change)\(check)\n\nThis cannot be undone without a backup."
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
                progressID = nil; pendingSaveRecovery = SaveRecoveryJournal.pendingFolders()
                operationEnd = Date(); operationRunning = false; operationTask = nil
                if sleepAssertion != 0 { IOPMAssertionRelease(sleepAssertion); sleepAssertion = 0 }
            }
            do {
                let model = self
                try await controller.setMDDumperStreaming(mdDumperStreaming)
                let result = try await work(controller) { [weak model] value in
                    Task { @MainActor [weak model] in
                        if model?.progressID == identifier { model?.progress = value }
                    }
                }
                progressID = nil
                operationResult = result
                record(.init(title:title,detail:result.manifest.phases.joined(separator:" · "),outcome:result.manifest.outcome,result:result,id:eventID,date:eventDate))
                completionMessage = title == "Cartridge backup" ? (result.manifest.artifacts.allSatisfy(\.verified) ? "Files read and verified." : "Files saved. Verification was off.") : "Written and verified."
                if title == "Cartridge backup", result.manifest.contentAnalysis?.hasUncertainRange == true { completionMessage = (completionMessage ?? "Files saved.") + " Part of the ROM range remains unconfirmed." }
                if title == "Cartridge backup", result.manifest.serialSave == nil, result.manifest.artifacts.contains(where:{ !$0.isROM }), result.manifest.saveStatus != .confirmed {
                    completionMessage = (completionMessage ?? "Files saved.") + " SRAM memory type is unconfirmed."
                }
                if result.manifest.preservedSaveSHA256 != nil { completionMessage = "ROM written and verified. Existing saves preserved." }
                progress = .init(.completed,detail:completionMessage ?? "Completed")
                cartridge = try? await controller.inspect(profile:profile,override:configurationOverride,mapper:mapper)
                if title == "Cartridge write" { contentAnalysis = nil }
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
