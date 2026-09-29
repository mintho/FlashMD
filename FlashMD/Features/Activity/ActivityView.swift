import FlashMDCore
import SwiftUI
import AppKit

struct ActivityView: View {
    @Bindable var model: WorkspaceModel
    @State private var selected: UUID?
    var body: some View {
        VStack(spacing:0) {
            if model.activity.isEmpty {
                ContentUnavailableView("No activity yet",systemImage:"clock.arrow.circlepath",description:Text("Inspections and transfer results are stored locally on this Mac."))
            } else {
                List(model.activity,selection:$selected) { entry in
                    VStack(alignment:.leading,spacing:8) {
                        HStack {
                            Label(entry.title,systemImage:entry.demo ? "cube.transparent" : (entry.outcome == "completed" ? "checkmark.circle" : "exclamationmark.circle"))
                                .fontWeight(.medium)
                            Spacer()
                            Text(entry.date,format:.dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(entry.demo ? "Demo · \(entry.detail)" : entry.detail).font(.callout).foregroundStyle(.secondary)
                        if entry.outcome == "started" { Text("Started record: consult the later result. If none exists, the app exited before recording completion.").font(.caption).foregroundStyle(.secondary) }
                        if let folder = entry.artifactFolder {
                            if FileManager.default.fileExists(atPath:folder.path) {
                                Button("Reveal backup in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                            } else { Text("Backup folder has been moved or deleted.").font(.caption).foregroundStyle(.secondary) }
                        }
                        if let manifest = entry.manifest {
                            DisclosureGroup("Verification and manifest details") {
                                VStack(alignment:.leading,spacing:8) {
                                    Text("Outcome: \(manifest.outcome)")
                                    Text("Device: \(manifest.device)")
                                    ForEach(manifest.inputs ?? [],id: \.filename) { input in
                                        Text("Input: \(input.filename) · \(formatBytes(input.bytes))")
                                        Text(input.sha256).font(.caption.monospaced()).textSelection(.enabled)
                                    }
                                    if let bytes = manifest.programmedROMBytes { Text("ROM representation: \(formatBytes(bytes)) including padding") }
                                    if let bytes = manifest.restoredActiveSaveBytes { Text("Restored SRAM: \(formatBytes(bytes)) active") }
                                    ForEach(manifest.artifacts,id:\.filename) { artifact in
                                        Text("\(artifact.filename) · \(formatBytes(artifact.bytes)) · \(artifact.verified ? "readback compared" : "not compared")")
                                        Text(artifact.sha256).font(.caption.monospaced()).textSelection(.enabled)
                                    }
                                    ForEach(manifest.phases,id:\.self) { Text($0) }
                                }.font(.callout).padding(.top,6)
                            }
                        }
                    }.padding(.vertical,10).accessibilityElement(children:.contain).tag(entry.id)
                }
            }
            HStack {
                Text("History stays on this Mac. Backup files stay in your chosen folders.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clear history…") { model.showClearHistory = true }.disabled(model.isBusy || model.activity.isEmpty)
            }.padding(16)
        }
    }
}
