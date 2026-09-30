import FlashMDCore
import SwiftUI
import UniformTypeIdentifiers

private let flashViolet = Color(red:0.57,green:0.35,blue:1)
private let flashMint = Color(red:0.41,green:0.92,blue:0.84)

struct CartridgeWorkspaceView: View {
    @Bindable var model: WorkspaceModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var advanced = false
    @State private var pendingAdvancedScroll = false
    @State private var details = false
    @State private var fileDetails = false
    @State private var analysisDetails = false

    var body: some View {
        ZStack {
            backdrop
            VStack(spacing:0) {
                if model.demoMode {
                    HStack {
                        Spacer()
                        Text("DEMO · SAMPLE DATA").font(.caption.weight(.semibold)).tracking(1).foregroundStyle(.secondary)
                    }.padding(.horizontal,32).padding(.top,24).padding(.bottom,8)
                }
                GeometryReader { viewport in
                ScrollViewReader { scroll in
                ScrollView {
                    VStack(spacing:20) {
                        if let cartridge = model.cartridge ?? model.operationCartridge, !model.isInspecting {
                            cartridgeSummary(cartridge,compact:viewport.size.height < 720)
                            Group {
                                if model.progress != nil { progressPanel }
                                else { transferPanel }
                            }.id("transferPanel")
                        } else { scanWelcome }
                        if advanced {
                            advancedPanel
                                .frame(minHeight:max(0,viewport.size.height - 24),alignment:.top)
                                .id("advanced")
                                .background {
                                    GeometryReader { panel in
                                        Color.clear.task(id:panel.size.height) {
                                            guard panel.size.height > 0, pendingAdvancedScroll else { return }
                                            // The insertion transition changes the scroll document size.
                                            // Wait for that transition before resolving its new target frame.
                                            do { try await Task.sleep(for:.milliseconds(reduceMotion ? 50 : 300)) }
                                            catch { return }
                                            guard advanced, !Task.isCancelled else { return }
                                            pendingAdvancedScroll = false
                                            withAnimation(reduceMotion ? nil : .easeInOut(duration:0.3)) {
                                                scroll.scrollTo("advanced",anchor:.top)
                                            }
                                        }
                                    }
                                }
                                .transition(.opacity)
                        }
                    }.overlay(alignment:.top) { Color.clear.frame(height:1).id("workspaceTop") }.padding(.horizontal,36).padding(.top,12).padding(.bottom,24)
                        .frame(minHeight:viewport.size.height,alignment:advanced ? .top : .center)
                        .frame(maxWidth:880).frame(maxWidth:.infinity)
                }
                .onChange(of:advanced) { _,expanded in
                    if !expanded { pendingAdvancedScroll = false; scroll.scrollTo("workspaceTop",anchor:.top) }
                }
                .onChange(of:model.operationRunning) { _,running in
                    if running {
                        advanced = false; pendingAdvancedScroll = false
                        scroll.scrollTo("workspaceTop",anchor:.top)
                    }
                }
                .onChange(of:model.isInspecting) { _,scanning in
                    if scanning { scroll.scrollTo("workspaceTop",anchor:.top) }
                }
                }
                }
                footer
            }
        }
        .tint(flashViolet)
        .animation(reduceMotion ? nil : .easeInOut(duration:0.25),value:model.isInspecting)
        .animation(reduceMotion ? nil : .easeInOut(duration:0.25),value:advanced)
    }

    private var backdrop: some View {
        GeometryReader { proxy in
            ZStack {
                (scheme == .dark ? Color(red:0.055,green:0.045,blue:0.12) : Color(red:0.96,green:0.95,blue:0.99))
                RadialGradient(colors:[flashViolet.opacity(scheme == .dark ? 0.32 : 0.16),.clear],center:.init(x:0.35,y:0.18),startRadius:10,endRadius:proxy.size.width * 0.7)
                RadialGradient(colors:[Color.blue.opacity(scheme == .dark ? 0.14 : 0.06),.clear],center:.bottomTrailing,startRadius:0,endRadius:proxy.size.width * 0.7)
            }.ignoresSafeArea()
        }.allowsHitTesting(false).accessibilityHidden(true)
    }

    private var scanWelcome: some View {
        VStack(spacing:22) {
            Spacer(minLength:22)
            ZStack {
                Ellipse().fill(flashViolet.opacity(0.25)).frame(width:290,height:40).blur(radius:30).offset(y:120)
                CartridgeArtwork(scanning:model.isInspecting).frame(width:240,height:230)
            }.padding(.bottom,6)
            VStack(spacing:12) {
                Text(model.isInspecting ? "Getting to know your cartridge" : "Meet your cartridge.")
                    .font(.system(size:36,weight:.medium,design:.rounded)).multilineTextAlignment(.center)
                Text(model.isInspecting ? model.scanStep : "Connect FlashKit via USB, insert a cartridge,\nand scan to get started.")
                    .font(.system(size:15)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(minHeight:42)
            }
            scanButton(large:true).padding(.top,10)
            Text(model.isInspecting ? "Cartridge contents are kept intact." : "Read games. Preserve saves. Write something new.")
                .font(.caption).foregroundStyle(.secondary).padding(.top,4)
            if model.selectedROM != nil {
                Text("Your imported ROM is ready. Scan a cartridge to continue.").font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength:22)
        }.frame(maxWidth:.infinity).frame(minHeight:570)
    }

    private func scanButton(large:Bool) -> some View {
        Button { Task { await model.refresh() } } label: {
            HStack(spacing:10) {
                if model.isInspecting { ProgressView().controlSize(.small).tint(.white) }
                Text(model.isInspecting ? "Scanning…" : "Scan Cartridge").font(.system(size:large ? 17 : 13,weight:.semibold))
            }
            .foregroundStyle(.white).padding(.horizontal,large ? 34 : 20).padding(.vertical,large ? 19 : 12)
            .background(LinearGradient(colors:[flashViolet,Color(red:0.36,green:0.22,blue:0.82)],startPoint:.topLeading,endPoint:.bottomTrailing),in:Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.25),lineWidth:1))
            .shadow(color:flashViolet.opacity(large ? 0.4 : 0.15),radius:large ? 25 : 12,y:8)
            .contentShape(Capsule())
        }.buttonStyle(.plain).disabled(model.isBusy).opacity(model.isBusy && !model.isInspecting ? 0.45 : 1).help("Find the programmer, reconnect, and inspect the inserted cartridge")
            .accessibilityIdentifier("scanCartridge")
    }

    private func cartridgeSummary(_ cartridge:CartridgeSnapshot,compact:Bool) -> some View {
        VStack(spacing:compact ? 12 : 22) {
            HStack(spacing:24) {
                CartridgeArtwork(scanning:false).frame(width:compact ? 85 : 125,height:compact ? 92 : 135)
                VStack(alignment:.leading,spacing:8) {
                    Text("MEGA DRIVE / GENESIS").font(.system(size:10,weight:.bold)).tracking(2).foregroundStyle(flashViolet)
                    Text(cartridge.title).font(.system(size:compact ? 24 : 28,weight:.semibold,design:.rounded)).fixedSize(horizontal:false,vertical:true)
                    HStack(spacing:8) {
                        Text(cartridge.regions.isEmpty ? "No game region detected" : cartridge.regions.joined(separator:" · ")).foregroundStyle(.secondary)
                        if cartridge.metadata != nil {
                            Button("Game Details") { details = true }.buttonStyle(.plain).foregroundStyle(flashViolet)
                                .popover(isPresented:$details) {
                                    MetadataView(metadata:cartridge.metadata!,checksum:nil).padding(24).frame(width:480)
                                }
                        }
                    }.font(.caption)
                }
                Spacer(minLength:0)
                scanButton(large:false)
            }
            HStack(spacing:0) {
                metric("ROM CAPACITY",cartridge.flashCapacity.map { formatBytes($0.bytes) } ?? "Unknown",note:cartridge.isDemo ? "Sample data" : (cartridge.configurationOverride != nil || cartridge.profile != .automatic ? "Manual configuration" : "Automatically configured"))
                Rectangle().fill(Color.primary.opacity(0.1)).frame(width:1,height:42)
                metric("HEADER ROM SIZE",cartridge.romSize.map { formatBytes($0.bytes) } ?? "No valid header",note:"Declared by the game; may be incomplete")
                    .help("Declared by the game. Backups use the scan's suggested size unless you choose complete ROM.")
                Rectangle().fill(Color.primary.opacity(0.1)).frame(width:1,height:42)
                metric("SAVE MEMORY",cartridge.saveLayout.map { formatBytes($0.activeBytes) + " SRAM" } ?? "None declared",note:cartridge.saveLayout == nil ? "Override in Advanced Settings" : (cartridge.configurationOverride == nil && cartridge.profile == .automatic ? "From the game header" : "Manual configuration"))
            }.padding(.vertical,compact ? 12 : 18).background(Color.primary.opacity(scheme == .dark ? 0.035 : 0.025),in:RoundedRectangle(cornerRadius:18))
        }.padding(.top,4)
    }
    private func metric(_ label:String,_ value:String,note:String) -> some View {
        VStack(alignment:.leading,spacing:6) {
            Text(label).font(.system(size:9,weight:.semibold)).tracking(1.5).foregroundStyle(.secondary)
            Text(value).font(.system(size:20,weight:.medium,design:.rounded))
            Text(note).font(.system(size:10)).foregroundStyle(.secondary)
        }.frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,20)
    }

    private var transferPanel: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {
                HStack(spacing:4) {
                    directionButton(.backup)
                    directionButton(.write)
                }.padding(4).background(Color.primary.opacity(0.055),in:Capsule())
                Spacer()
                Text(model.direction == .backup ? "CARTRIDGE → MAC" : "MAC → CARTRIDGE")
                    .font(.system(size:9,weight:.semibold)).tracking(1.5).foregroundStyle(.secondary)
            }
            // Both panels determine the shared height, so switching tabs never
            // moves the cartridge summary or the tab controls.
            ZStack(alignment:.topLeading) {
                if model.direction == .backup { backupPanel }
                else { backupPanel.hidden().allowsHitTesting(false).accessibilityHidden(true) }
                if model.direction == .write { writePanel }
                else { writePanel.hidden().allowsHitTesting(false).accessibilityHidden(true) }
            }
            if model.configurationPending {
                Text("Configuration changed. Apply it in Advanced Settings before transferring.").font(.callout).foregroundStyle(.orange)
            }
        }.padding(22).background(panelBackground)
    }
    private func directionButton(_ direction:TransferDirection) -> some View {
        Button { model.direction = direction } label: {
            Text(direction == .backup ? "Backup" : "Write").font(.system(size:14,weight:.semibold))
                .frame(width:96,height:34)
                .background(model.direction == direction ? flashViolet.opacity(scheme == .dark ? 0.4 : 0.13) : .clear,in:Capsule())
                .foregroundStyle(model.direction == direction ? Color.primary : Color.secondary)
        }.buttonStyle(.plain).disabled(model.isBusy)
            .accessibilityAddTraits(model.direction == direction ? .isSelected : [])
    }

    private var backupPanel: some View {
        VStack(alignment:.leading,spacing:20) {
            VStack(alignment:.leading,spacing:5) {
                Text("Keep a copy of your cartridge.").font(.system(size:19,weight:.medium,design:.rounded))
                Text("Choose what to save to your Mac.").font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing:12) {
                selectionCard("Game ROM",subtitle:model.backupSizeDescription,symbol:"gamecontroller",selected:$model.backupROM,enabled:true)
                selectionCard("Save data",subtitle:model.cartridge?.saveLayout.map { formatBytes($0.activeBytes) + " of SRAM" } ?? "No SRAM configured",symbol:"externaldrive",selected:$model.backupSRAM,enabled:model.cartridge?.saveLayout != nil)
            }
            if model.backupROM, let analysis = model.contentAnalysis, let suggested = analysis.suggestedBytes {
                HStack(spacing:12) {
                    VStack(alignment:.leading,spacing:3) {
                        Text("Suggested export · \(formatBytes(suggested))").font(.caption.weight(.semibold))
                        Text("Estimated from the scan.").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength:0)
                    Button("Details") { analysisDetails = true }.buttonStyle(.plain).foregroundStyle(flashViolet)
                        .popover(isPresented:$analysisDetails) { analysisSummary(analysis).padding(24).frame(width:420) }
                    Toggle("Back Up Complete ROM",isOn:Binding(get:{model.backupLength == .complete},set:{model.backupLength = $0 ? .complete : .suggested}))
                        .toggleStyle(.switch).controlSize(.mini).fixedSize()
                }.font(.caption)
            }
            HStack(alignment:.center) {
                Text(model.verifyBackup ? "Files are verified after reading." : "Backup verification is off.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Back Up…") { model.startBackup() }.buttonStyle(FlashActionStyle()).disabled(!model.canBackup)
            }
        }.disabled(model.isBusy)
    }

    private func analysisSummary(_ analysis:ROMContentAnalysis) -> some View {
        VStack(alignment:.leading,spacing:14) {
            Text("ROM Content Analysis").font(.title2.weight(.semibold))
            LabeledContent("Scanned range",value:formatBytes(analysis.scannedBytes))
            LabeledContent("Header declaration",value:analysis.headerBytes.map(formatBytes) ?? "Unknown")
            if let suggested = analysis.suggestedBytes { LabeledContent("Suggested export",value:"\(suggested.formatted()) bytes") }
            LabeledContent("Erased end area (FF)",value:formatBytes(analysis.trailingErasedBytes))
            if let period = analysis.possibleMirrorBytes { LabeledContent("Possible repeated block",value:formatBytes(period)) }
            Text(analysis.explanation).font(.callout)
            Text("An estimate: old data may look like game data. Complete ROM includes every accessible byte.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var writePanel: some View {
        VStack(alignment:.leading,spacing:14) {
            Text(model.writeROM && !model.writeSRAM && model.cartridge?.saveLayout != nil ? "Write a game. Keep your existing saves." : "Choose what to write to your cartridge.").font(.callout).foregroundStyle(.secondary)
            HStack(spacing:12) {
                writeFileCard("Game ROM",file:model.selectedROM,selected:$model.writeROM,enabled:model.cartridge?.canWrite == true,forROM:true)
                writeFileCard("Save data",file:model.selectedSRAM,selected:$model.writeSRAM,enabled:model.cartridge?.canRestoreSave == true,forROM:false)
            }
            if model.writeROM, let image = model.selectedROM?.image {
                if let geometry = model.cartridge?.geometry, let bytes = try? geometry.programLength(model.clearUnusedROM ? (model.cartridge?.romReadLimit ?? image.data.count) : image.data.count) {
                    let capacity = model.cartridge?.flashCapacity?.bytes ?? 0
                    Text("\(formatBytes(image.data.count)) ROM · \(formatBytes(capacity)) available")
                        .font(.caption).foregroundStyle(bytes <= capacity ? Color.secondary : Color.red)
                }
                if image.metadata.saveLayout != nil, model.cartridge?.saveLayout == nil {
                    Text("This game expects save memory, but no SRAM is configured.").font(.caption).foregroundStyle(.orange)
                }
            }
            HStack {
                Text("All writes are verified.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Write…") { model.prepareWrite() }.buttonStyle(FlashActionStyle()).disabled(!model.canReviewWrite)
            }
            if model.cartridge?.canWrite != true {
                Text("ROM writing is not supported for this cartridge. Backup is available.").font(.caption).foregroundStyle(.secondary)
            }
        }.disabled(model.isBusy)
    }

    private func writeFileCard(_ title:String,file:SelectedFile?,selected:Binding<Bool>,enabled:Bool,forROM:Bool) -> some View {
        VStack(alignment:.leading,spacing:10) {
            Button { selected.wrappedValue.toggle() } label: {
                HStack {
                    Text(title).font(.callout.weight(.semibold))
                    Spacer()
                    Image(systemName:selected.wrappedValue ? "checkmark.circle.fill" : "circle").foregroundStyle(selected.wrappedValue ? flashViolet : .secondary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Write " + title).accessibilityValue(selected.wrappedValue ? "Selected" : "Not selected")
            VStack(alignment:.leading,spacing:4) {
                Text(file?.name ?? (enabled ? "Drop a file or choose one" : "Unavailable for this cartridge")).font(.caption).lineLimit(1).truncationMode(.middle)
                if let file { Text(formatBytes(file.bytes)).font(.caption2).foregroundStyle(.secondary) }
            }.frame(height:30,alignment:.top).foregroundStyle(.secondary)
            HStack {
                Button(forROM ? "Choose ROM…" : "Choose Save…") {
                    if forROM { model.isImportingROM = true } else { model.isImportingSRAM = true }
                }.controlSize(.small).disabled(!selected.wrappedValue)
                Spacer(minLength:0)
                if let image = file?.image {
                    Button("Details") { fileDetails = true }.buttonStyle(.plain).foregroundStyle(flashViolet)
                        .popover(isPresented:$fileDetails) {
                            VStack(alignment:.leading,spacing:14) {
                                MetadataView(metadata:image.metadata,checksum:image.checksum)
                                ForEach(image.warnings,id:\.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                            }.padding(24).frame(width:480)
                        }
                }
            }.font(.caption)
        }.padding(14).frame(maxWidth:.infinity,alignment:.leading)
            .background(selected.wrappedValue && enabled ? flashViolet.opacity(0.09) : Color.primary.opacity(0.025),in:RoundedRectangle(cornerRadius:14))
            .overlay(RoundedRectangle(cornerRadius:14).strokeBorder(selected.wrappedValue && enabled ? flashViolet.opacity(0.5) : Color.primary.opacity(contrast == .increased ? 0.35 : 0.08),lineWidth:1))
            .disabled(!enabled).opacity(enabled ? 1 : 0.5)
            .dropDestination(for:URL.self) { urls,_ in
                guard enabled, !model.isBusy, let url = urls.first else { return false }
                model.selectFile(.success(url),forROM:forROM); return true
            }
    }

    private func selectionCard(_ title:String,subtitle:String,symbol:String,selected:Binding<Bool>,enabled:Bool) -> some View {
        Button { selected.wrappedValue.toggle() } label: {
            HStack(spacing:12) {
                Image(systemName:symbol).font(.system(size:22,weight:.light)).foregroundStyle(selected.wrappedValue && enabled ? flashViolet : .secondary)
                VStack(alignment:.leading,spacing:5) {
                    Text(title).font(.system(size:14,weight:.semibold))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                }
                Spacer(minLength:0)
                Image(systemName:selected.wrappedValue && enabled ? "checkmark.circle.fill" : "circle").foregroundStyle(selected.wrappedValue && enabled ? flashViolet : Color.secondary.opacity(0.5))
            }.padding(16).frame(maxWidth:.infinity,minHeight:76,alignment:.leading)
                .background(selected.wrappedValue && enabled ? flashViolet.opacity(0.09) : Color.primary.opacity(0.025),in:RoundedRectangle(cornerRadius:14))
                .overlay(RoundedRectangle(cornerRadius:14).strokeBorder(selected.wrappedValue && enabled ? flashViolet.opacity(0.5) : Color.primary.opacity(contrast == .increased ? 0.35 : 0.08),lineWidth:1))
                .contentShape(RoundedRectangle(cornerRadius:14))
        }.buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.5)
            .accessibilityLabel(title).accessibilityValue(selected.wrappedValue && enabled ? "Selected" : "Not selected").accessibilityHint(subtitle)
    }

    private var advancedPanel: some View {
        VStack(alignment:.leading,spacing:16) {
            Text("Advanced Settings").font(.title3.weight(.semibold))
            VStack(alignment:.leading,spacing:8) {
                Text("Cartridge configuration").font(.headline)
                Text(model.manualConfiguration ? "Use the memory settings for your cartridge board." : "Detected during scanning. Override if your board needs different settings.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                Picker("Configuration",selection:$model.profile) { ForEach(CartridgeProfile.allCases) { Text($0.displayName).tag($0) } }
                    .disabled(model.manualConfiguration)
                Toggle("Override memory configuration",isOn:Binding(get:{model.manualConfiguration},set:{ value in if value { model.useDetectedConfiguration() }; model.manualConfiguration = value }))
                if model.manualConfiguration {
                    Picker("Accessible ROM capacity",selection:$model.capacityChoice) {
                        ForEach([0x10000,0x20000,0x40000,0x80000,0x100000,0x200000,0x300000,0x400000],id:\.self) { Text(formatBytes($0)).tag($0) }
                        if ![0x10000,0x20000,0x40000,0x80000,0x100000,0x200000,0x300000,0x400000].contains(model.capacityChoice) { Text(formatBytes(model.capacityChoice)).tag(model.capacityChoice) }
                    }
                    Text("Choose the ROM capacity accessible on your board. Maximum 4 MiB.").font(.caption).foregroundStyle(.secondary)
                    Toggle("Cartridge has SRAM",isOn:$model.manualSave)
                    if model.manualSave {
                        HStack(spacing:14) {
                            VStack(alignment:.leading,spacing:5) { Text("Start address (hex)").font(.caption); TextField("200001",text:$model.saveStart).textFieldStyle(.roundedBorder).accessibilityLabel("SRAM start address in hexadecimal") }
                            VStack(alignment:.leading,spacing:5) { Text("End address (hex, inclusive)").font(.caption); TextField("20FFFF",text:$model.saveEnd).textFieldStyle(.roundedBorder).accessibilityLabel("SRAM inclusive end address in hexadecimal") }
                            Picker("Byte lane",selection:$model.saveLane) { Text("Odd (8-bit)").tag(1); Text("Even (read only)").tag(0); Text("Both (16-bit)").tag(2) }.frame(width:185)
                        }
                        Text("Typical 32 KiB SRAM: 200001–20FFFF, odd lane. For both lanes, use an even start and odd end.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let geometry = model.cartridge?.geometry { Text("\(geometry.name) · \(formatBytes(geometry.capacity)) physical flash · \(geometry.sectors.count) erase sectors").font(.caption).foregroundStyle(.secondary) }
                if model.configurationPending { Button("Apply Configuration") { Task { await model.refresh() } }.buttonStyle(.borderedProminent) }
            }
            Divider().opacity(0.4)
            VStack(alignment:.leading,spacing:8) {
                Text("Backup").font(.headline)
                Picker("ROM size",selection:$model.backupLength) { ForEach(ROMBackupLength.allCases) { Text($0.title).tag($0) } }
                Text(model.backupLengthExplanation).font(.caption).foregroundStyle(.secondary)
                if model.backupLength == .custom {
                    LabeledContent("ROM bytes to read") { TextField("2097152",text:$model.forcedROMSize).textFieldStyle(.roundedBorder).accessibilityLabel("ROM bytes to read") }
                    HStack {
                        Button("Use Header Size") { model.forcedROMSize = model.cartridge?.romSize.map { String($0.bytes) } ?? "" }.disabled(model.cartridge?.romSize == nil)
                        Button("Use Capacity") { model.forcedROMSize = model.cartridge?.flashCapacity.map { String($0.bytes) } ?? "" }.disabled(model.cartridge?.flashCapacity == nil)
                    }
                    Text("Bytes to read, up to cartridge capacity. 2097152 = 2 MiB.").font(.caption).foregroundStyle(.secondary)
                }
                Picker("Save format",selection:$model.saveFormat) { Text(SaveFormat.packed.displayName).tag(SaveFormat.packed); Text(SaveFormat.raw.displayName).tag(SaveFormat.raw) }
                Text(model.saveFormatExplanation).font(.caption).foregroundStyle(.secondary)
                Toggle("Verify backup",isOn:$model.verifyBackup)
                Text("Reads twice and compares the results.").font(.caption).foregroundStyle(.secondary)
            }
            Divider().opacity(0.4)
            VStack(alignment:.leading,spacing:8) {
                Text("Writing").font(.headline)
                Toggle("Clear unused ROM space",isOn:$model.clearUnusedROM)
                Text("Erases cartridge ROM beyond the new game.").font(.caption).foregroundStyle(.secondary)
                Picker("Save file format",selection:$model.saveImportFormat) { ForEach(SaveImportFormat.allCases) { Text($0.title).tag($0) } }
                Text(model.saveImportFormat.explanation).font(.caption).foregroundStyle(.secondary)
            }
            Divider().opacity(0.4)
            VStack(alignment:.leading,spacing:8) {
                Text("USB connection").font(.headline)
                Toggle("Choose programmer manually",isOn:$model.portOverride)
                if model.portOverride {
                    Picker("Programmer",selection:$model.selectedPort) {
                        if model.ports.isEmpty { Text("No USB serial devices found").tag("") }
                        ForEach(model.ports) { Text($0.name).tag($0.path) }
                    }
                }
                Text("Choose a device if more than one programmer is connected.").font(.caption).foregroundStyle(.secondary)
            }
        }.font(.callout).padding(26).background(panelBackground).disabled(model.isBusy)
    }

    private var progressPanel: some View {
        VStack(alignment:.leading,spacing:18) {
            if let progress = model.progress {
                HStack(spacing:12) {
                    if model.operationRunning {
                        ProgressView().controlSize(.small).tint(flashViolet)
                    } else {
                        Image(systemName:progress.phase == .completed ? "checkmark.circle.fill" : (progress.phase == .cancelled ? "stop.circle" : "exclamationmark.triangle.fill"))
                            .font(.system(size:28,weight:.light)).foregroundStyle(progress.phase == .completed ? flashMint : .orange)
                    }
                    VStack(alignment:.leading,spacing:5) {
                        Text(operationHeading(progress)).font(.system(size:21,weight:.medium,design:.rounded))
                        Text(model.operationRunning ? "Keep the programmer connected." : (progress.phase == .completed ? progress.detail : "See Activity for details."))
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    }
                    Spacer(minLength:0)
                    if let start = model.operationStart {
                        if model.operationRunning {
                            TimelineView(.periodic(from:start,by:1)) { context in elapsedLabel(context.date.timeIntervalSince(start)) }
                        } else { elapsedLabel((model.operationEnd ?? Date()).timeIntervalSince(start)) }
                    }
                }
                if model.operationRunning {
                    VStack(alignment:.leading,spacing:12) {
                        Text(progress.detail.isEmpty ? "Checking the cartridge" : progress.detail).font(.callout.weight(.medium))
                        if progress.total > 0 {
                            ProgressView(value:Double(progress.completed),total:Double(progress.total))
                            Text(progress.phase == .erasing ? "\(progress.completed) / \(progress.total) sectors" : "\(formatBytes(progress.completed)) / \(formatBytes(progress.total))")
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        } else { ProgressView().progressViewStyle(.linear) }
                    }.padding(.vertical,16)
                    HStack {
                        Text("\(model.operationCartridge?.title ?? "Cartridge") · \(model.operationTitle == "Cartridge backup" ? "Backup" : "Write and verify")").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(progress.cancellable ? "Cancel Transfer" : "Stop Safely") { model.cancel() }
                    }
                } else {
                    if progress.phase != .completed {
                        Text(progress.detail).font(.callout).fixedSize(horizontal:false,vertical:true)
                    }
                    if let result = model.operationResult, !result.manifest.artifacts.isEmpty {
                        VStack(spacing:10) {
                            ForEach(result.manifest.artifacts,id:\.filename) { artifact in
                                HStack {
                                    Image(systemName:artifact.isROM ? "gamecontroller" : "externaldrive").foregroundStyle(flashViolet)
                                    Text(artifact.isROM ? "Game ROM · \(artifact.filename)" : "Save data · \(artifact.filename)").font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text(formatBytes(artifact.bytes)).font(.caption).foregroundStyle(.secondary)
                                    if artifact.verified { Image(systemName:"checkmark.seal").foregroundStyle(flashMint).help("Verified with a second read") }
                                    Button { model.revealArtifact(artifact) } label: { Image(systemName:"arrow.up.forward.square") }
                                        .buttonStyle(.plain).help("Show \(artifact.filename) in Finder").accessibilityLabel("Show \(artifact.filename) in Finder")
                                }
                            }
                        }.padding(16).background(Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:12))
                    }
                    HStack {
                        if model.operationResult?.folder != nil { Button("Show in Finder") { model.revealOperationFolder() } }
                        if progress.phase != .completed { Button("View Details") { model.showHistory = true } }
                        Spacer()
                        Button(model.connected && model.cartridge != nil ? "New Transfer" : "Scan Again") { model.newTransfer() }.buttonStyle(FlashActionStyle())
                    }
                }
            }
        }.padding(26).frame(maxWidth:.infinity,minHeight:300,alignment:.topLeading)
            .background(panelBackground)
    }
    private func elapsedLabel(_ seconds:TimeInterval) -> some View {
        Text("\(Int(max(0,seconds)))s").font(.caption).foregroundStyle(.secondary).monospacedDigit()
    }
    private func operationHeading(_ progress:OperationProgress) -> String {
        if model.operationRunning { return model.operationTitle == "Cartridge backup" ? "Backing up your cartridge" : "Writing your cartridge" }
        switch progress.phase {
        case .completed: return model.operationTitle == "Cartridge backup" ? "Backup complete" : "Write verified"
        case .cancelled: return "Transfer cancelled"
        default: return "Transfer could not finish"
        }
    }

    private var footer: some View {
        HStack(spacing:18) {
            Circle().fill(model.connected || model.demoMode ? flashMint : Color.secondary.opacity(0.5)).frame(width:6,height:6)
            Text(model.demoMode ? "Demo mode" : (model.connected ? "FlashKit connected" : (model.ports.isEmpty ? "Connect your FlashKit via USB" : "USB device available · ready to scan")))
                .font(.caption).foregroundStyle(.secondary)
                .help(model.connected ? model.selectedPort : "")
            Spacer()
            Button { pendingAdvancedScroll = !advanced; advanced.toggle() } label: {
                HStack(spacing:5) { Text("Advanced Settings"); Image(systemName:advanced ? "chevron.up" : "chevron.down").font(.system(size:9,weight:.semibold)) }
            }.accessibilityValue(advanced ? "Expanded" : "Collapsed")
            Button("Activity") { model.showHistory = true }
        }.buttonStyle(.plain).font(.caption).padding(.horizontal,32).padding(.vertical,20)
    }
    private var panelBackground: some View {
        RoundedRectangle(cornerRadius:22).fill(scheme == .dark ? Color.white.opacity(0.045) : Color.white.opacity(0.72))
            .overlay(RoundedRectangle(cornerRadius:22).strokeBorder(Color.primary.opacity(contrast == .increased ? 0.35 : 0.07),lineWidth:1))
    }
}

private struct FlashActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration:Configuration) -> some View {
        configuration.label.font(.system(size:13,weight:.semibold)).foregroundStyle(.white)
            .padding(.horizontal,22).padding(.vertical,12)
            .background(flashViolet.opacity(configuration.isPressed ? 0.65 : 1),in:Capsule()).opacity(enabled ? 1 : 0.4)
    }
}

struct MetadataView: View {
    let metadata: ROMMetadata
    let checksum: UInt16?
    var body: some View {
        VStack(alignment:.leading,spacing:20) {
            Text("Game Details").font(.title2.weight(.semibold))
            Grid(alignment:.leading,horizontalSpacing:20,verticalSpacing:10) {
                row("International title",metadata.internationalTitle)
                row("Domestic title",metadata.domesticTitle)
                row("System",metadata.console)
                row("Product / version",metadata.productCode)
                row("Copyright",metadata.copyright)
                row("Year",metadata.copyrightYear ?? "Unknown")
                row("Regions",metadata.regions.joined(separator:" · "))
                row("Declared ROM size (header)",metadata.declaredROMBytes.map(formatBytes) ?? "Unknown")
                row("Declared save",metadata.saveLayout.map { "\(formatBytes($0.activeBytes)) · \($0.lane.map { $0 == 1 ? "odd lane" : "even lane" } ?? "16-bit")" } ?? metadata.saveWarning ?? "None")
                row("Input support",metadata.peripherals)
                row("Header checksum",String(format:"%04X",metadata.storedChecksum))
                if let checksum { row("File checksum",String(format:"%04X",checksum) + (checksum == metadata.storedChecksum ? " · matches" : " · differs")) }
            }.font(.callout).textSelection(.enabled)
            Text("From the game header. Copyright may identify the publisher.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func row(_ title:String,_ value:String) -> some View { GridRow { Text(title).foregroundStyle(.secondary); Text(value.isEmpty ? "Unknown" : value).fixedSize(horizontal:false,vertical:true).frame(maxWidth:.infinity,alignment:.leading) } }
}

/// Original vector artwork scales cleanly with the window and needs no bitmap assets.
private struct CartridgeArtwork: View {
    var scanning: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweeping = false
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack {
                RoundedRectangle(cornerRadius:width * 0.11)
                    .fill(LinearGradient(colors:[Color(red:0.28,green:0.27,blue:0.37),Color(red:0.09,green:0.09,blue:0.14)],startPoint:.topLeading,endPoint:.bottomTrailing))
                    .overlay(RoundedRectangle(cornerRadius:width * 0.11).strokeBorder(.white.opacity(0.2),lineWidth:1))
                    .frame(width:width,height:width * 0.79)
                    .shadow(color:.black.opacity(0.25),radius:16,y:14)
                VStack(spacing:width * 0.035) {
                    HStack { ForEach(0..<6) { _ in Capsule().fill(.black.opacity(0.2)).frame(height:width * 0.015) } }.padding(.horizontal,width * 0.1)
                    ZStack {
                        RoundedRectangle(cornerRadius:width * 0.04).fill(LinearGradient(colors:[Color(red:0.67,green:0.39,blue:1),Color(red:0.27,green:0.2,blue:0.63)],startPoint:.topLeading,endPoint:.bottomTrailing))
                        VStack(spacing:width * 0.04) {
                            Text("MEGA DRIVE").font(.system(size:width * 0.06,weight:.bold,design:.rounded)).tracking(width * 0.008)
                            Image(systemName:"bolt.fill").font(.system(size:width * 0.22,weight:.light)).foregroundStyle(flashMint)
                            Text("16–BIT").font(.system(size:width * 0.045,weight:.medium)).tracking(width * 0.015)
                        }.foregroundStyle(.white)
                    }.frame(width:width * 0.76,height:width * 0.51)
                    HStack(spacing:width * 0.018) {
                        ForEach(0..<16) { _ in RoundedRectangle(cornerRadius:1).fill(LinearGradient(colors:[Color(red:0.9,green:0.76,blue:0.48),Color(red:0.58,green:0.43,blue:0.21)],startPoint:.top,endPoint:.bottom)).frame(width:width * 0.025,height:width * 0.075) }
                    }.padding(.top,width * 0.08)
                }.offset(y:width * 0.06)
                if scanning {
                    if reduceMotion { RoundedRectangle(cornerRadius:width * 0.11).strokeBorder(flashMint.opacity(0.8),lineWidth:2).frame(height:width * 0.79) }
                    else {
                        Rectangle().fill(LinearGradient(colors:[.clear,flashMint.opacity(0.5),flashMint,.clear],startPoint:.top,endPoint:.bottom))
                            .frame(width:width * 1.13,height:width * 0.035).shadow(color:flashMint,radius:10)
                            .offset(y:sweeping ? width * 0.36 : -width * 0.36)
                            .animation(.easeInOut(duration:1.6).repeatForever(autoreverses:true),value:sweeping)
                    }
                }
            }.frame(maxHeight:.infinity).rotation3DEffect(.degrees(-8),axis:(x:0,y:1,z:0))
        }.onAppear { sweeping = scanning }.onChange(of:scanning) { _,value in sweeping = value }.accessibilityHidden(true)
    }
}

func formatBytes(_ count:Int) -> String {
    if count >= 1048576 { return "\((Double(count)/1048576).formatted(.number.precision(.fractionLength(0...3)))) MiB" }
    if count >= 1024 { return "\((Double(count)/1024).formatted(.number.precision(.fractionLength(0...2)))) KiB" }
    return "\(count) bytes"
}
