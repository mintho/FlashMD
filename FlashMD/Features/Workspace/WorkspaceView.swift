import FlashMDCore
import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceView: View {
    @Bindable var model: WorkspaceModel
    var body: some View {
        CartridgeWorkspaceView(model:model)
        .task { await model.initialize() }
        .background(WindowOperationGuard(busy:model.operationRunning))
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for:NSWorkspace.willSleepNotification)) { _ in model.handleSleep() }
        .fileImporter(isPresented:$model.isImportingROM,allowedContentTypes:[.data]) { model.selectFile($0,forROM:true) }
        .fileImporter(isPresented:$model.isImportingSRAM,allowedContentTypes:[.data]) { model.selectFile($0,forROM:false) }
        .sheet(isPresented:$model.showHistory) {
            VStack(spacing:0) {
                HStack { Text("Activity").font(.title2.weight(.semibold)); Spacer(); Button("Done") { model.showHistory = false }.keyboardShortcut(.cancelAction) }.padding(24)
                ActivityView(model:model)
            }.frame(width:760,height:600)
        }
        .alert(model.writeConfirmationTitle,isPresented:$model.showReview) {
            Button("Cancel",role:.cancel) { model.invalidateReview() }
            Button(model.writeActionTitle,role:.destructive) { model.confirmWrite() }
        } message: { Text(model.writeConfirmationMessage) }
        .alert("Does this cartridge have SRAM?",isPresented:$model.showSRAMQuestion) {
            Button("Cancel",role:.cancel) { model.cancelSRAMQuestion() }
            Button("This cartridge has no SRAM") { model.confirmCartridgeHasNoSRAM() }
        } message: {
            Text("The game declares SRAM, but it could not be detected. If the board has no SRAM, FlashMD can continue with ROM only. Otherwise, cancel to protect your saves.")
        }
        .alert("Couldn’t complete the action",isPresented:Binding(get:{model.errorMessage != nil},set:{if !$0 {model.errorMessage = nil}})) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .alert("Clear activity history?",isPresented:$model.showClearHistory) {
            Button("Cancel",role:.cancel) {}
            Button("Clear history",role:.destructive) { model.clearHistory() }
        } message: { Text("Backup files and cartridge contents will be kept.") }
    }
}
private struct WindowOperationGuard: NSViewRepresentable {
    var busy: Bool
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context:Context) -> NSView { NSView() }
    func updateNSView(_ view:NSView,context:Context) {
        context.coordinator.busy = busy
        DispatchQueue.main.async {
            if let window = view.window {
                if window.delegate !== context.coordinator { context.coordinator.previous = window.delegate; window.delegate = context.coordinator }
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
                window.isMovableByWindowBackground = true
                window.standardWindowButton(.closeButton)?.isEnabled = !busy
            }
        }
    }
    final class Coordinator: NSObject, NSWindowDelegate {
        var busy = false
        weak var previous: (any NSWindowDelegate)?
        func windowShouldClose(_ sender:NSWindow) -> Bool { !busy && (previous?.windowShouldClose?(sender) ?? true) }
        override func responds(to selector: Selector!) -> Bool { super.responds(to:selector) || previous?.responds(to:selector) == true }
        override func forwardingTarget(for selector:Selector!) -> Any? { previous?.responds(to:selector) == true ? previous : super.forwardingTarget(for:selector) }
    }
}
#Preview {
    WorkspaceView(model:WorkspaceModel()).frame(width:1050,height:760)
}
