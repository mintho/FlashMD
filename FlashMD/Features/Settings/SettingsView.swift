import FlashMDCore
import SwiftUI

struct SettingsView: View {
    @Bindable var model: WorkspaceModel
    var body: some View {
        Form {
            Section("Workspace") {
                Toggle("Demo mode",isOn:$model.demoMode)
                Text("Preview with sample data. No hardware access.").font(.caption).foregroundStyle(.secondary)
                Text("Scan to detect your cartridge. Manual configuration is in Advanced Settings.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Backup") {
                Toggle("Verify backup",isOn:$model.verifyBackup)
                Text("Reads twice and compares the results.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Writing") {
                Toggle("Clear unused ROM space",isOn:$model.clearUnusedROM)
                Text("Erases cartridge ROM beyond the new game.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Licensing") {
                Text("FlashMD · GNU GPLv3").font(.callout)
                Text("FlashKit protocol references: Krikzz and Joey Parrish (GPLv3). See LICENSE and NOTICE in the project.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).frame(width:520,height:430).disabled(model.isBusy)
    }
}
