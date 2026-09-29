import SwiftUI

struct ActivityView: View {
    let entries: [ActivityEntry]

    var body: some View {
        if entries.isEmpty {
            ContentUnavailableView(
                "No activity yet",
                systemImage: "clock.arrow.circlepath",
                description: Text("Selected files and cartridge inspections appear here.")
            )
        } else {
            List(entries) { entry in
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: entry.symbol).foregroundStyle(.tint).frame(width: 22)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(entry.title).fontWeight(.medium)
                        Text(entry.detail).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(entry.date, style: .time).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }
            .safeAreaInset(edge: .bottom) {
                Text("Activity is kept for this session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
            }
        }
    }
}
