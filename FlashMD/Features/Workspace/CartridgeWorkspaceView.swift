import FlashMDCore
import SwiftUI

struct CartridgeWorkspaceView: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let cartridge = model.cartridge {
                    HStack(spacing: 24) {
                        CartridgeIllustration()
                        VStack(alignment: .leading, spacing: 7) {
                            Text("MEGA DRIVE / GENESIS")
                                .font(.caption.weight(.semibold))
                                .tracking(1.3)
                                .foregroundStyle(.tint)
                            Text(cartridge.title)
                                .font(.system(size: 30, weight: .semibold, design: .rounded))
                            Text(cartridge.regions.joined(separator: " · "))
                                .foregroundStyle(.secondary)
                            Label("Demo cartridge · sample data", systemImage: "cube.transparent")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    CapacityView(cartridge: cartridge)
                } else {
                    HStack(spacing: 24) {
                        CartridgeIllustration().opacity(0.45)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Your cartridge workspace")
                                .font(.title2.weight(.semibold))
                            Text("This version does not detect USB programmers yet.")
                                .foregroundStyle(.secondary)
                            Text("Explore the interface in demo mode, or select a local ROM file.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Button("Explore demo cartridge") { model.demoMode = true }
                        }
                        Spacer(minLength: 0)
                    }
                }

                Picker("Transfer direction", selection: $model.direction) {
                    ForEach(TransferDirection.allCases) { direction in
                        Text(direction.displayName).tag(direction)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 240)

                if model.direction == .backup {
                    BackupPanel(model: model)
                } else {
                    WritePanel(model: model)
                }

                Label("Cartridge transfers are not available in this build.", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(32)
            .frame(maxWidth: 850, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(.background)
    }
}

private struct CapacityView: View {
    let cartridge: CartridgeSnapshot

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Flash capacity").fontWeight(.medium)
                    Spacer()
                    if let capacity = cartridge.flashCapacity {
                        Text(formatBytes(capacity.bytes))
                        Text(capacity.source.displayName).foregroundStyle(.secondary)
                    } else {
                        Text("Unknown").foregroundStyle(.secondary)
                    }
                }
                if let capacity = cartridge.flashCapacity, capacity.bytes > 0, let rom = cartridge.romSize {
                    ProgressView(value: Double(rom.bytes), total: Double(capacity.bytes))
                        .accessibilityLabel("Installed ROM compared to flash capacity")
                }
                HStack {
                    Text("Current ROM · \(cartridge.romSize.map { formatBytes($0.bytes) } ?? "Unknown")")
                    Spacer()
                    Text("Save window · \(cartridge.rawSaveWindow.map { formatBytes($0.bytes) } ?? "Unknown"), raw")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(8)
        }
    }
}

private struct BackupPanel: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            TransferChoice(title: "Game ROM", subtitle: "Save the game as a .bin file", symbol: "memorychip", isOn: $model.backupROM)
            Divider()
            TransferChoice(title: "Save data (SRAM)", subtitle: "Preserve an exact FlashKit raw save dump", symbol: "externaldrive", isOn: $model.backupSRAM)
            HStack {
                Text("One folder for your selected contents and backup manifest")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Choose destination…") {}
                    .buttonStyle(.borderedProminent)
                    .disabled(true)
            }
            .padding(.top, 8)
        }
    }
}

private struct WritePanel: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            TransferChoice(title: "Game ROM", subtitle: "Replace the game on this cartridge", symbol: "memorychip", isOn: $model.writeROM)
            if model.writeROM {
                FileSelectionView(file: model.selectedROM, title: "Choose a game ROM", symbol: "doc", buttonTitle: "Choose ROM…") {
                    model.isImportingROM = true
                }
                if model.selectedROM != nil {
                    Text("Capacity and ROM format must be validated before writing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Divider()
            TransferChoice(title: "Save data (SRAM)", subtitle: "Restore a separate, compatible save file", symbol: "externaldrive", isOn: $model.writeSRAM)
            if model.writeSRAM {
                FileSelectionView(file: model.selectedSRAM, title: "Choose a save file", symbol: "doc", buttonTitle: "Choose SRAM…") {
                    model.isImportingSRAM = true
                }
            }
            Toggle("Back up affected contents before writing", isOn: $model.backupBeforeWrite)
                .toggleStyle(.checkbox)
            HStack {
                Text(model.writeSRAM ? "Save format and compatibility will be checked." : "Existing SRAM bytes will be retained.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Review write…") {}
                    .buttonStyle(.borderedProminent)
                    .disabled(true)
            }
        }
    }
}

private struct TransferChoice: View {
    let title: String
    let subtitle: String
    let symbol: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).fontWeight(.medium)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.checkbox)
    }
}

private struct FileSelectionView: View {
    let file: SelectedFile?
    let title: String
    let symbol: String
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        GroupBox {
            HStack(spacing: 12) {
                Image(systemName: symbol).foregroundStyle(.tint).font(.title2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(file?.name ?? title).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                    Text(file.map { formatBytes($0.bytes) } ?? "Select a local file")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(buttonTitle, action: action)
            }
            .padding(8)
        }
    }
}

private struct CartridgeIllustration: View {
    var body: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 15)
                .fill(Color.primary.opacity(0.85))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.accentColor.gradient)
                        .padding(13)
                        .overlay {
                            VStack(spacing: 6) {
                                Text("MEGA DRIVE").font(.system(size: 10, weight: .semibold)).tracking(1)
                                Image(systemName: "waveform.path").font(.title2)
                                Text("16 BIT").font(.system(size: 10, weight: .semibold)).tracking(2)
                            }
                            .foregroundStyle(.white)
                        }
                }
                .frame(width: 112, height: 105)
            HStack(spacing: 3) {
                ForEach(0..<13) { _ in
                    Rectangle().fill(Color(red: 0.73, green: 0.57, blue: 0.29)).frame(width: 4, height: 9)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

func formatBytes(_ count: Int) -> String {
    let kibibyte = 1_024
    let mebibyte = 1_048_576
    if count >= mebibyte {
        return "\((Double(count) / Double(mebibyte)).formatted(.number.precision(.fractionLength(0...2)))) MiB"
    }
    if count >= kibibyte {
        return "\((Double(count) / Double(kibibyte)).formatted(.number.precision(.fractionLength(0...2)))) KiB"
    }
    return "\(count) bytes"
}
