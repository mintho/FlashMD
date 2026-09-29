import SwiftUI

@main
struct FlashMDApp: App {
    @State private var model = WorkspaceModel()

    var body: some Scene {
        WindowGroup {
            WorkspaceView(model: model)
                .frame(minWidth: 820, minHeight: 650)
        }
        .defaultSize(width: 1050, height: 760)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open ROM…", systemImage: "doc.badge.plus") {
                    model.isImportingROM = true
                }
                .keyboardShortcut("o")
            }
            CommandMenu("Cartridge") {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await model.refresh() }
                }
                .keyboardShortcut("r")
                .disabled(model.isInspecting || !model.demoMode)
                Toggle("Demo Mode", isOn: $model.demoMode)
            }
        }

        Settings {
            SettingsView(model: model)
        }
    }
}
