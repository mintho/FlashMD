import FlashMDCore
import SwiftUI

struct SettingsView: View {
    @Bindable var model: WorkspaceModel
    var body: some View {
        Form {
            Section("Workspace") {
                Toggle("Demo mode",isOn:$model.demoMode)
                Text("Demo mode uses sample information and cannot write to hardware.").font(.caption).foregroundStyle(.secondary)
                Picker("Cartridge profile",selection:$model.profile) { ForEach(CartridgeProfile.allCases) { Text($0.displayName).tag($0) } }
            }
            Section("Transfers") {
                Toggle("Back up affected contents before writing",isOn:$model.backupBeforeWrite)
                Toggle("Compare backups with a second read",isOn:$model.verifyBackup)
                Text("Supported flash: ST M29W320ET/EB and AMD/Spansion S29GL064N boot-sector models. The initial mapper profile exposes up to 4 MiB.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Licensing") {
                Text("FlashMD · GNU GPLv3").font(.callout)
                Text("FlashKit protocol references: Krikzz and Joey Parrish (GPLv3). See LICENSE and NOTICE in the project.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).frame(width:520,height:430).disabled(model.isBusy)
    }
}
