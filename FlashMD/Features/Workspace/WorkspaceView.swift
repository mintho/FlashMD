import FlashMDCore
import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceView: View {
    @Bindable var model: WorkspaceModel
    var body: some View {
        NavigationSplitView {
            List(WorkspacePage.allCases,selection:$model.page) { page in Label(page.title,systemImage:page.symbol).tag(page) }
                .navigationTitle("FlashMD")
                .navigationSplitViewColumnWidth(min:180,ideal:200,max:250)
                .safeAreaInset(edge:.bottom) {
                    VStack(alignment:.leading,spacing:5) {
                        Label(model.connectionLabel,systemImage:model.demoMode ? "cube.transparent" : (model.connected ? "checkmark.circle" : "cable.connector"))
                            .font(.caption.weight(.medium))
                        Text(model.demoMode ? "Sample cartridge" : (model.connected ? URL(fileURLWithPath:model.selectedPort).lastPathComponent : "Connect FlashKit MD via USB"))
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    }.frame(maxWidth:.infinity,alignment:.leading).padding(16)
                }
        } detail: {
            Group {
                switch model.page ?? .cartridge {
                case .cartridge: CartridgeWorkspaceView(model:model)
                case .activity: ActivityView(model:model)
                }
            }
            .navigationTitle((model.page ?? .cartridge).title)
            .toolbar {
                ToolbarItemGroup {
                    Toggle(isOn:$model.demoMode) { Label("Demo",systemImage:"cube.transparent") }.disabled(model.isBusy)
                    Button { Task { await model.refresh() } } label: { Label("Refresh",systemImage:"arrow.clockwise") }.disabled(model.isBusy)
                }
            }
        }
        .task { await model.initialize() }
        .background(WindowOperationGuard(busy:model.operationRunning))
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for:NSWorkspace.willSleepNotification)) { _ in model.handleSleep() }
        .fileImporter(isPresented:$model.isImportingROM,allowedContentTypes:[.data]) { model.selectFile($0,forROM:true) }
        .fileImporter(isPresented:$model.isImportingSRAM,allowedContentTypes:[.data]) { model.selectFile($0,forROM:false) }
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
                LabeledContent("Cartridge profile",value:plan.target.profile.displayName)
                LabeledContent("Usable capacity",value:formatBytes(plan.target.flashCapacity?.bytes ?? 0))
                if plan.rom != nil {
                    LabeledContent("ROM",value:plan.romName ?? "Game ROM")
                    LabeledContent("Programmed size (including padding)",value:formatBytes(plan.requiredBytes))
                    Text("The current ROM will be replaced.")
                }
                if plan.save != nil { LabeledContent("SRAM",value:plan.saveName ?? "Save data"); Text("Existing save data will be replaced.") }
                else { Text("Existing SRAM bytes will be retained. They may not be compatible with a different game.").foregroundStyle(.secondary) }
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
