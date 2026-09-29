import FlashMDCore
import Foundation
import Observation

enum WorkspacePage: String, CaseIterable, Identifiable {
    case cartridge
    case activity

    var id: Self { self }
    var title: String { self == .cartridge ? "Cartridge" : "Activity" }
    var symbol: String { self == .cartridge ? "cpu" : "clock.arrow.circlepath" }
}

struct SelectedFile: Identifiable {
    let id = UUID()
    let url: URL
    let bytes: Int

    var name: String { url.lastPathComponent }

    init(url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        self.url = url
        self.bytes = size
    }
}

struct ActivityEntry: Identifiable {
    let id = UUID()
    let date = Date()
    let title: String
    let detail: String
    let symbol: String
}

@MainActor
@Observable
final class WorkspaceModel {
    var page: WorkspacePage? = .cartridge
    var direction = TransferDirection.backup
    var demoMode = false {
        didSet {
            guard oldValue != demoMode else { return }
            Task { await updateConnectionMode() }
        }
    }
    var cartridge: CartridgeSnapshot?
    var isInspecting = false
    var backupROM = true
    var backupSRAM = true
    var writeROM = true
    var writeSRAM = false
    var backupBeforeWrite = true
    var selectedROM: SelectedFile?
    var selectedSRAM: SelectedFile?
    var isImportingROM = false
    var isImportingSRAM = false
    var errorMessage: String?
    var activity: [ActivityEntry] = []
    private var inspectionID = UUID()

    func refresh() async {
        let requestID = UUID()
        inspectionID = requestID
        isInspecting = true
        cartridge = nil
        errorMessage = nil
        let service: any CartridgeService = demoMode
            ? DemoCartridgeService()
            : DisconnectedCartridgeService()
        defer { if inspectionID == requestID { isInspecting = false } }
        do {
            let result = try await service.inspect()
            guard inspectionID == requestID else { return }
            cartridge = result
            activity.insert(
                ActivityEntry(title: "Demo cartridge inspected", detail: "Sample data · no device accessed", symbol: "cpu"),
                at: 0
            )
        } catch {
            guard inspectionID == requestID else { return }
            errorMessage = error.localizedDescription
        }
    }

    func updateConnectionMode() async {
        if demoMode {
            await refresh()
        } else {
            inspectionID = UUID()
            cartridge = nil
            isInspecting = false
            errorMessage = nil
        }
    }

    func selectFile(_ result: Result<URL, Error>, forROM: Bool) {
        do {
            let file = try SelectedFile(url: result.get())
            if forROM {
                selectedROM = file
                page = .cartridge
                direction = .write
            } else {
                selectedSRAM = file
            }
            activity.insert(
                ActivityEntry(title: forROM ? "ROM selected" : "Save file selected", detail: file.name, symbol: "doc"),
                at: 0
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
