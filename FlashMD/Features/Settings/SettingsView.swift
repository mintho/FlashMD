import FlashMDCore
import SwiftUI

struct SettingsView: View {
    @Bindable var model: WorkspaceModel
    var body: some View {
        Form {
            Section("Workspace") {
                Toggle("Demo mode",isOn:$model.demoMode)
                Text("Demo mode uses sample information and cannot write to hardware.").font(.caption).foregroundStyle(.secondary)
                Text("Cartridges are configured automatically when you scan. Manual memory settings are available in Advanced Options.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Transfers") {
                Toggle("Back up affected contents before writing",isOn:$model.backupBeforeWrite)
                Toggle("Compare backups with a second read",isOn:$model.verifyBackup)
                Text("Supported flash: ST M29W320ET/EB and AMD/Spansion S29GL064N boot-sector models. Automatic ROM access is limited to 4 MiB, or to the start of header-declared SRAM. Additional mappings can be configured manually within that range.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Licensing") {
                Text("FlashMD · GNU GPLv3").font(.callout)
                Text("FlashKit protocol references: Krikzz and Joey Parrish (GPLv3). See LICENSE and NOTICE in the project.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).frame(width:520,height:430).disabled(model.isBusy)
    }
}
