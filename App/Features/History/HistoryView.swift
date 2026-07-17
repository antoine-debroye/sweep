import SwiftUI
import SweepCore

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var sessions: [CleanSession] = []
    @State private var statusMessage: String?

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                SectionHeader(
                    title: "History",
                    subtitle: "Every clean is logged. Sessions with items still in the Trash can be undone."
                )
                Spacer()
                StatTileMini(value: model.lifetimeFreed.sweepBytes, label: "freed lifetime")
            }

            if let status = statusMessage {
                StatusPill(text: status, color: Theme.azure)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if sessions.isEmpty {
                SweepEmptyState(
                    symbol: "clock.arrow.circlepath",
                    title: "No cleans yet",
                    message: "Run a Smart Clean and it will show up here, with undo."
                )
            } else {
                List {
                    ForEach(sessions) { session in
                        SessionRow(session: session) {
                            undo(session)
                        }
                        .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.inset)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                        .strokeBorder(.separator.opacity(0.5), lineWidth: 1)
                )
            }
        }
        .padding(24)
        .task { await reload() }
    }

    private func reload() async {
        sessions = await model.history.sessions()
    }

    private func undo(_ session: CleanSession) {
        Task {
            let result = await model.history.undo(sessionID: session.id)
            statusMessage = "Restored \(result.restored) items"
                + (result.missing > 0 ? " · \(result.missing) were no longer in the Trash" : "")
            await reload()
            await model.refreshHistorySummary()
        }
    }
}

private struct StatTileMini: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(value)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.accentGradient)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
}

private struct SessionRow: View {
    let session: CleanSession
    let onUndo: () -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: session.undone ? "arrow.uturn.backward.circle" : "checkmark.circle.fill")
                    .foregroundStyle(session.undone ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.mint))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(session.source.label)
                            .font(.system(size: 12.5, weight: .semibold))
                        if session.undone {
                            StatusPill(text: "Undone", color: .gray)
                        }
                    }
                    Text(session.date.formatted(date: .abbreviated, time: .shortened) + " · \(session.items.count) items")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                ByteText(bytes: session.totalFreed, font: .system(size: 13, weight: .bold, design: .rounded))
                if session.restorableCount > 0 && !session.undone {
                    Button("Undo") { onUndo() }
                        .buttonStyle(SecondaryButtonStyle())
                }
                Button {
                    withAnimation(.spring(duration: 0.25)) { expanded.toggle() }
                } label: {
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            if expanded {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(session.items.prefix(40)) { item in
                        HStack {
                            Image(systemName: item.category.symbol)
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                                .frame(width: 14)
                            Text(item.originalPath)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(item.size.sweepBytes)
                                .font(.system(size: 10, design: .rounded))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    if session.items.count > 40 {
                        Text("… and \(session.items.count - 40) more")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    ForEach(session.errors, id: \.self) { error in
                        Text(error)
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.coral)
                    }
                }
                .padding(.leading, 26)
            }
        }
        .padding(.vertical, 6)
    }
}
