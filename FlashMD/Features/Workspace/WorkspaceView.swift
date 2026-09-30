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
        .sheet(isPresented:$model.showReview) { WriteReviewView(model:model) }
        .alert("Couldn’t complete the action",isPresented:Binding(get:{model.errorMessage != nil},set:{if !$0 {model.errorMessage = nil}})) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .alert("Clear activity history?",isPresented:$model.showClearHistory) {
            Button("Cancel",role:.cancel) {}
            Button("Clear history",role:.destructive) { model.clearHistory() }
        } message: { Text("Backup files and cartridge contents will be kept.") }
    }
}
struct WriteReviewView: View {
    @Bindable var model: WorkspaceModel
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            Label("Review cartridge write",systemImage:"exclamationmark.triangle").font(.title2.weight(.semibold))
            if let plan = model.reviewPlan {
                Text(plan.target.title).font(.headline)
                Text(plan.target.identity).font(.caption).foregroundStyle(.secondary)
                LabeledContent("Configuration",value:plan.target.configurationOverride != nil ? "Manual override" : plan.target.profile.displayName)
                if let capacity = plan.target.flashCapacity { LabeledContent("Usable capacity",value:formatBytes(capacity.bytes)) }
                if plan.rom != nil {
                    LabeledContent("ROM",value:plan.romName ?? "Game ROM")
                    LabeledContent("Programmed size (including padding)",value:formatBytes(plan.requiredBytes))
                    Text("The current ROM will be replaced.")
                }
                if plan.save != nil { LabeledContent("SRAM",value:plan.saveName ?? "Save data"); Text("Existing save data will be replaced.") }
                else if plan.target.saveLayout != nil { Text("Existing SRAM bytes will be retained. They may not be compatible with a different game.").foregroundStyle(.secondary) }
                Text(plan.backupDestination == nil ? "Pre-write backup is off." : "A verified backup of affected contents will be saved before writing.")
                Text("Keep USB connected until verification finishes.").font(.callout)
            }
            HStack {
                Spacer()
                Button("Cancel") { model.showReview = false; model.reviewPlan = nil }.keyboardShortcut(.cancelAction)
                Button("Write and verify") { model.confirmWrite() }.buttonStyle(.borderedProminent)
            }
        }.padding(28).frame(width:580)
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
