import SwiftUI

@main
struct FlashMDApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = WorkspaceModel()

    var body: some Scene {
        WindowGroup {
            WorkspaceView(model: model)
                .onAppear { delegate.model = model }
                .frame(minWidth: 760, minHeight: 700)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 960, height: 880)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open ROM…", systemImage: "doc.badge.plus") {
                    model.isImportingROM = true
                }
                .keyboardShortcut("o")
                .disabled(model.isBusy || model.showReview)
            }
            CommandMenu("Cartridge") {
                Button("Scan Cartridge", systemImage: "arrow.clockwise") {
                    Task { await model.refresh() }
                }
                .keyboardShortcut("r")
                .disabled(model.isBusy || model.showReview)
                Button("Activity…") { model.showHistory = true }.keyboardShortcut("h",modifiers:[.command,.shift])
                Toggle("Demo Mode", isOn: $model.demoMode).disabled(model.isBusy || model.showReview)
                Button("Back up cartridge…") { model.startBackup() }.disabled(model.isBusy || model.showReview || !model.connected || model.demoMode)
                Button("Review write…") { model.prepareWrite() }.disabled(model.isBusy || model.showReview || !model.canReviewWrite || model.demoMode)
            }
        }

        Settings {
            SettingsView(model: model)
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: WorkspaceModel?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model?.operationRunning == true else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "A cartridge operation is still running"
        alert.informativeText = "Wait for completion, or cancel and wait until the programmer reaches a safe boundary before quitting."
        alert.addButton(withTitle: "Keep FlashMD open")
        alert.runModal()
        return .terminateCancel
    }
}
