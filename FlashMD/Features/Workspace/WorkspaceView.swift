import FlashMDCore
import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceView: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        NavigationSplitView {
            List(WorkspacePage.allCases, selection: $model.page) { page in
                Label(page.title, systemImage: page.symbol)
                    .tag(page)
            }
            .navigationTitle("FlashMD")
            .navigationSplitViewColumnWidth(min: 170, ideal: 195, max: 240)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 9) {
                    Image(systemName: model.demoMode ? "cube.transparent" : "cable.connector")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.demoMode ? "Demo mode" : "USB support not enabled")
                            .font(.caption.weight(.medium))
                        Text(model.demoMode ? "Sample cartridge" : "Unavailable in this build")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(16)
            }
        } detail: {
            Group {
                switch model.page ?? .cartridge {
                case .cartridge: CartridgeWorkspaceView(model: model)
                case .activity: ActivityView(entries: model.activity)
                }
            }
            .navigationTitle((model.page ?? .cartridge).title)
            .toolbar {
                ToolbarItemGroup {
                    Toggle(isOn: $model.demoMode) {
                        Label("Demo", systemImage: "cube.transparent")
                    }
                    .help("Explore a sample cartridge without accessing hardware")
                    Button {
                        Task { await model.refresh() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isInspecting || !model.demoMode)
                }
            }
        }
        .fileImporter(isPresented: $model.isImportingROM, allowedContentTypes: [.data]) { result in
            model.selectFile(result, forROM: true)
        }
        .fileImporter(isPresented: $model.isImportingSRAM, allowedContentTypes: [.data]) { result in
            model.selectFile(result, forROM: false)
        }
        .alert("Couldn’t complete the action", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

#Preview("Workspace") {
    let model = WorkspaceModel()
    WorkspaceView(model: model)
        .frame(width: 1050, height: 760)
        .task {
            model.demoMode = true
        }
}
