import FlashMDCore
import SwiftUI
import UniformTypeIdentifiers

struct CartridgeWorkspaceView: View {
    @Bindable var model: WorkspaceModel
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:22) {
                connectionPanel
                if let cartridge = model.cartridge {
                    HStack(spacing:24) {
                        CartridgeIllustration()
                        VStack(alignment:.leading,spacing:7) {
                            Text("MEGA DRIVE / GENESIS").font(.caption.weight(.semibold)).tracking(1.3).foregroundStyle(.tint)
                            Text(cartridge.title).font(.system(size:30,weight:.semibold,design:.rounded))
                            Text(cartridge.regions.joined(separator:" · ")).foregroundStyle(.secondary)
                            Text(cartridge.isDemo ? "Demo cartridge · sample data" : (cartridge.geometry?.name ?? "ROM cartridge · flash unidentified")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    GroupBox {
                        VStack(alignment:.leading,spacing:12) {
                            LabeledContent("Usable ROM capacity",value:cartridge.flashCapacity.map { formatBytes($0.bytes) + " · " + $0.source.displayName } ?? "Unknown")
                            if let geometry = cartridge.geometry { LabeledContent("Physical flash chip",value:formatBytes(geometry.capacity)) }
                            if let capacity = cartridge.flashCapacity, let rom = cartridge.romSize, capacity.bytes > 0 {
                                ProgressView(value:min(Double(rom.bytes),Double(capacity.bytes)),total:Double(capacity.bytes)).accessibilityLabel("Installed ROM compared to usable capacity")
                            }
                            LabeledContent("Current ROM",value:cartridge.romSize.map { formatBytes($0.bytes) + " · header" } ?? "Unknown")
                            LabeledContent("Hardware save window",value:cartridge.saveLayout.map { "\(formatBytes($0.windowBytes)) raw / \(formatBytes($0.activeBytes)) active · profile" } ?? (cartridge.profile == .linearROMOnly ? "None for selected profile" : "Choose a confirmed cartridge profile"))
                            if cartridge.profile == .linearROMOnly { Text("This profile supports ROM transfers. SRAM backup and restoration are unavailable.").font(.caption).foregroundStyle(.secondary) }
                            if let warning = cartridge.warning { Text(warning).font(.callout).foregroundStyle(.secondary) }
                        }.padding(8)
                    }
                    if let metadata = cartridge.metadata { MetadataView(metadata:metadata,checksum:nil) }
                } else {
                    ContentUnavailableView(model.connected ? "Cartridge information unavailable" : "Connect your programmer",systemImage:"cable.connector",description:Text("Connect FlashKit MD via USB, choose its serial port, and click Connect. You can inspect local ROM files without a programmer."))
                        .frame(minHeight:130)
                }
                Picker("Transfer direction",selection:$model.direction) { ForEach(TransferDirection.allCases) { Text($0.displayName).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().accessibilityLabel("Transfer direction").frame(width:240).disabled(model.isBusy)
                Group { if model.direction == .backup { backupPanel } else { writePanel } }.disabled(model.isBusy)
                if let progress = model.progress {
                    GroupBox {
                        VStack(alignment:.leading,spacing:10) {
                            HStack {
                                if progress.phase == .completed {
                                    Label(progress.detail,systemImage:"checkmark.circle.fill").foregroundStyle(.green)
                                } else { Text(progress.detail.isEmpty ? progress.phase.rawValue : progress.detail).fontWeight(.medium) }
                                Spacer()
                                if model.operationRunning {
                                    Button(progress.cancellable ? "Cancel" : "Stop after safe boundary") { model.cancel() }
                                }
                            }
                            if progress.total > 0 { ProgressView(value:Double(progress.completed),total:Double(progress.total)); Text("\(progress.completed.formatted()) / \(progress.total.formatted())").font(.caption).monospacedDigit() }
                            if let start = model.operationStart, model.operationRunning {
                                TimelineView(.periodic(from:start,by:1)) { context in Text("Elapsed \(Int(context.date.timeIntervalSince(start))) seconds").font(.caption).foregroundStyle(.secondary).monospacedDigit() }
                            }
                        }.padding(8)
                    }.accessibilityElement(children:.contain)
                }

            }.padding(28).frame(maxWidth:900,alignment:.leading).frame(maxWidth:.infinity)
        }
    }
    private var connectionPanel: some View {
        GroupBox {
            VStack(alignment:.leading,spacing:12) {
                HStack {
                    Picker("USB port",selection:$model.selectedPort) {
                        if model.ports.isEmpty { Text("No USB serial ports found").tag("") }
                        ForEach(model.ports) { Text($0.name).tag($0.path) }
                    }
                    Button("Scan") { Task { await model.scanPorts() } }
                    Button(model.connected ? "Reconnect" : "Connect") { Task { await model.connect() } }.disabled(model.selectedPort.isEmpty || model.demoMode)
                }
                Picker("Cartridge profile",selection:$model.profile) { ForEach(CartridgeProfile.allCases) { Text($0.displayName).tag($0) } }
                Text("Select the FlashKit profile only for a compatible linear flash cartridge. Other mappers remain inspect-only. Refresh after swapping cartridges.").font(.caption).foregroundStyle(.secondary)
            }.padding(8)
        }.disabled(model.isBusy || model.demoMode)
    }
    private var backupPanel: some View {
        VStack(alignment:.leading,spacing:16) {
            Toggle("Game ROM",isOn:$model.backupROM).toggleStyle(.checkbox)
            Toggle("Save data (SRAM)",isOn:$model.backupSRAM).toggleStyle(.checkbox).disabled(model.profile == .linearROMOnly)
            if model.backupROM {
                TextField("Exact ROM bytes (optional; required for invalid header)",text:$model.forcedROMSize)
                    .textFieldStyle(.roundedBorder).help("For example: 2097152 for 2 MiB. Limits are validated before reading.")
            }
            if model.backupSRAM { Picker("Save output format",selection:$model.saveFormat) { ForEach(SaveFormat.allCases) { Text($0.displayName).tag($0) } } }
            Toggle("Verify backup with a second read",isOn:$model.verifyBackup)
            HStack {
                Text("A new folder contains the selected files and a SHA-256 manifest.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Choose destination…") { model.startBackup() }.buttonStyle(.borderedProminent)
                    .disabled(model.demoMode || !model.connected || model.cartridge == nil || (!model.backupROM && !model.backupSRAM))
            }
        }
    }
    private var writePanel: some View {
        VStack(alignment:.leading,spacing:16) {
            Toggle("Write game ROM",isOn:$model.writeROM).toggleStyle(.checkbox)
            if model.writeROM {
                FileSelectionView(file:model.selectedROM,title:"Choose a game ROM",buttonTitle:"Choose ROM…") { model.isImportingROM = true }
                    .dropDestination(for:URL.self) { urls,_ in guard let url = urls.first else { return false }; model.selectFile(.success(url),forROM:true); return true }
                if let image = model.selectedROM?.image {
                    if image.metadata.saveLayout != nil, model.cartridge?.profile == .linearROMOnly {
                        Label("This game declares save data, but the selected cartridge profile has no SRAM.",systemImage:"exclamationmark.triangle").font(.callout).foregroundStyle(.secondary)
                    }
                    MetadataView(metadata:image.metadata,checksum:image.checksum)
                    ForEach(image.warnings,id:\.self) { Label($0,systemImage:"exclamationmark.triangle").font(.callout).foregroundStyle(.secondary) }
                    if let geometry = model.cartridge?.geometry, let size = try? geometry.programLength(image.data.count) {
                        let capacity = model.cartridge?.flashCapacity?.bytes ?? 0
                        Text("\(formatBytes(image.data.count)) file · \(formatBytes(size)) programmed · \(formatBytes(capacity)) usable capacity")
                            .font(.callout).foregroundStyle(size <= capacity ? Color.primary : Color.red)
                    } else { Text("Cartridge capacity must be known before writing.").font(.caption).foregroundStyle(.secondary) }
                }
            }
            Divider()
            Toggle("Write save data (SRAM)",isOn:$model.writeSRAM).toggleStyle(.checkbox).disabled(model.profile == .linearROMOnly)
            if model.writeSRAM {
                FileSelectionView(file:model.selectedSRAM,title:"Choose a compatible save",buttonTitle:"Choose SRAM…") { model.isImportingSRAM = true }
                    .dropDestination(for:URL.self) { urls,_ in guard let url = urls.first else { return false }; model.selectFile(.success(url),forROM:false); return true }
                Picker("Input save format",selection:$model.saveFormat) { ForEach(SaveFormat.allCases) { Text($0.displayName).tag($0) } }
            }
            Toggle("Back up affected contents before writing",isOn:$model.backupBeforeWrite).toggleStyle(.checkbox)
            HStack {
                Text(model.writeSRAM ? "Exact save length and byte lane will be validated." : "Existing save bytes are retained; compatibility with a new game is not guaranteed.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Review write…") { model.prepareWrite() }.buttonStyle(.borderedProminent)
                    .disabled(model.demoMode || model.cartridge?.canWrite != true || (!model.writeROM && !model.writeSRAM))
            }
        }
    }
}
struct MetadataView: View {
    let metadata: ROMMetadata
    let checksum: UInt16?
    var body: some View {
        DisclosureGroup("ROM metadata") {
            Grid(alignment:.leading,horizontalSpacing:20,verticalSpacing:9) {
                row("International title",metadata.internationalTitle)
                row("Domestic title",metadata.domesticTitle)
                row("System",metadata.console)
                row("Product / version",metadata.productCode)
                row("Copyright",metadata.copyright)
                row("Copyright year",metadata.copyrightYear ?? "Unknown")
                row("Regions",metadata.regions.joined(separator:" · "))
                row("Header ROM size",metadata.declaredROMBytes.map(formatBytes) ?? "Unknown")
                row("Game save layout",metadata.saveLayout.map { "\(formatBytes($0.activeBytes)) active, \($0.lane.map { $0 == 1 ? "odd lane" : "even lane" } ?? "16-bit")" } ?? metadata.saveWarning ?? "None declared")
                row("Input support",metadata.peripherals)
                row("Header checksum",String(format:"%04X",metadata.storedChecksum))
                if let checksum { row("Calculated checksum",String(format:"%04X",checksum) + (checksum == metadata.storedChecksum ? " · matches" : " · differs")) }
            }.font(.callout).padding(.top,10).textSelection(.enabled)
        }
    }
    private func row(_ title:String,_ value:String) -> some View { GridRow { Text(title).foregroundStyle(.secondary); Text(value.isEmpty ? "Unknown" : value).frame(maxWidth:.infinity,alignment:.leading) } }
}
private struct FileSelectionView: View {
    let file: SelectedFile?
    let title: String
    let buttonTitle: String
    let action: () -> Void
    var body: some View {
        GroupBox {
            HStack(spacing:12) {
                Image(systemName:"doc").font(.title2).foregroundStyle(.tint)
                VStack(alignment:.leading,spacing:4) {
                    Text(file?.name ?? title).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                    Text(file.map { formatBytes($0.bytes) } ?? "Drop a local file here or choose one").font(.caption).foregroundStyle(.secondary)
                }; Spacer(); Button(buttonTitle,action:action)
            }.padding(8)
        }
    }
}
private struct CartridgeIllustration: View {
    var body: some View {
        VStack(spacing:0) {
            RoundedRectangle(cornerRadius:15).fill(Color.primary.opacity(0.85))
                .overlay { RoundedRectangle(cornerRadius:6).fill(Color.accentColor.gradient).padding(13)
                    .overlay { VStack(spacing:6) { Text("MEGA DRIVE").font(.system(size:10,weight:.semibold)).tracking(1); Image(systemName:"waveform.path").font(.title2); Text("16 BIT").font(.system(size:10,weight:.semibold)).tracking(2) }.foregroundStyle(.white) } }.frame(width:112,height:105)
            HStack(spacing:3) { ForEach(0..<13) { _ in Rectangle().fill(Color(red:0.73,green:0.57,blue:0.29)).frame(width:4,height:9) } }
        }.accessibilityHidden(true)
    }
}
func formatBytes(_ count:Int) -> String {
    if count >= 1048576 { return "\((Double(count)/1048576).formatted(.number.precision(.fractionLength(0...2)))) MiB" }
    if count >= 1024 { return "\((Double(count)/1024).formatted(.number.precision(.fractionLength(0...2)))) KiB" }
    return "\(count) bytes"
}
