import SwiftUI

struct SettingsView: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        Form {
            Section("Workspace") {
                Toggle("Demo mode", isOn: $model.demoMode)
                Text("Use sample cartridge information without accessing a programmer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Writing") {
                Toggle("Back up affected contents before writing", isOn: $model.backupBeforeWrite)
            }
        }
        .formStyle(.grouped)
        .frame(width: 430, height: 260)
    }
}
