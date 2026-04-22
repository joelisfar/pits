import SwiftUI
import AppKit

struct ConversationListView: View {
    @ObservedObject var store: ConversationStore
    @AppStorage("net.farriswheel.Pits.alwaysOnTop") private var alwaysOnTop: Bool = false
    @State private var selectedIds: Set<String> = []
    @State private var expandedIds: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            MonthPickerBar(store: store)
            Divider()

            if visibleConversations.isEmpty {
                if store.isLoading { loadingState } else { emptyState }
            } else {
                TimelineView(.periodic(from: .now, by: 1.0)) { context in
                    List(selection: $selectedIds) {
                        ForEach(dayGroups, id: \.day) { group in
                            Section {
                                ForEach(group.conversations) { c in
                                    ConversationCell(
                                        conversation: c,
                                        now: context.date,
                                        isExpanded: binding(for: c.id)
                                    )
                                    .tag(c.id)
                                }
                            } header: {
                                DayHeader(day: group.day, total: group.totalCost)
                                    .contentShape(Rectangle())
                                    .onTapGesture { selectedIds.removeAll() }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .onKeyPress(.rightArrow) { expandSelected() }
                    .onKeyPress(.leftArrow) { collapseSelected() }
                }
            }

            Divider()

            HStack {
                Text(statusBarText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if store.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .onTapGesture { selectedIds.removeAll() }
        }
        .frame(minWidth: 400, minHeight: 220)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { applyWindowLevel() }
        .onChange(of: alwaysOnTop) { _, _ in applyWindowLevel() }
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { expandedIds.contains(id) },
            set: { new in
                if new { expandedIds.insert(id) } else { expandedIds.remove(id) }
            }
        )
    }

    /// Right-arrow: expand every selected row that has subagents.
    private func expandSelected() -> KeyPress.Result {
        guard !selectedIds.isEmpty else { return .ignored }
        var changed = false
        for sid in selectedIds {
            guard let c = store.conversations.first(where: { $0.id == sid }),
                  c.hasSubagentTurns,
                  !expandedIds.contains(sid) else { continue }
            expandedIds.insert(sid)
            changed = true
        }
        return changed ? .handled : .ignored
    }

    /// Left-arrow: collapse every currently-expanded selected row.
    private func collapseSelected() -> KeyPress.Result {
        guard !selectedIds.isEmpty else { return .ignored }
        let toRemove = selectedIds.intersection(expandedIds)
        guard !toRemove.isEmpty else { return .ignored }
        expandedIds.subtract(toRemove)
        return .handled
    }

    private var visibleConversations: [Conversation] {
        store.conversations.compactMap { $0.filtered(toMonth: store.selectedMonth) }
    }

    private var statusBarText: String {
        let visible = visibleConversations
        if selectedIds.isEmpty {
            let count = visible.count
            let total = visible.reduce(0.0) { $0 + $1.totalCost }
            return "\(count) conversation\(count == 1 ? "" : "s") · \(CostFormat.string(from: total)) total"
        }
        let selected = visible.filter { selectedIds.contains($0.id) }
        let total = selected.reduce(0.0) { $0 + $1.totalCost }
        return "\(selected.count) of \(visible.count) selected · \(CostFormat.string(from: total)) total"
    }

    /// Apply the "keep window on top" preference to this scene's NSWindow.
    /// We find the first window tagged with the main-scene id/title — the
    /// Settings window has its own title and is unaffected.
    private func applyWindowLevel() {
        DispatchQueue.main.async {
            let level: NSWindow.Level = alwaysOnTop ? .floating : .normal
            for w in NSApp.windows where w.title == "Pits" {
                w.level = level
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No active Claude Code conversations")
                .foregroundStyle(.secondary)
            Text("Start a `claude` session — it'll appear here.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Loading your Claude Code history…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var dayGroups: [DayGroup] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: visibleConversations) { c in
            cal.startOfDay(for: c.lastActivityTimestamp)
        }
        return grouped.map { (day, convos) in
            DayGroup(
                day: day,
                conversations: convos.sorted { $0.lastActivityTimestamp > $1.lastActivityTimestamp }
            )
        }
        .sorted { $0.day > $1.day }
    }
}

private struct DayGroup {
    let day: Date
    let conversations: [Conversation]
    var totalCost: Double { conversations.reduce(0.0) { $0 + $1.totalCost } }
}

private struct MonthPickerBar: View {
    @ObservedObject var store: ConversationStore

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(store.availableMonths, id: \.self) { m in
                    Button(m.displayName()) { store.setSelectedMonth(m) }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(store.selectedMonth.displayName())
                        .font(.caption.weight(.medium))
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

private struct DayHeader: View {
    let day: Date
    let total: Double

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    private static let absoluteFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d"
        return f
    }()

    private var label: String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        // For last-week dates, show the weekday too; otherwise the absolute format.
        return Self.absoluteFormatter.string(from: day)
    }

    var body: some View {
        HStack {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text(CostFormat.string(from: total))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// Per-conversation row. Expansion state is hoisted to the list so L/R
/// arrow keys can toggle the currently-selected row.
private struct ConversationCell: View {
    let conversation: Conversation
    let now: Date
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(spacing: 0) {
            if !conversation.hasSubagentTurns {
                ConversationRowView(conversation: conversation, now: now)
            } else {
                ConversationRowView(
                    conversation: conversation, now: now, isExpanded: $isExpanded
                )
                if isExpanded {
                    SubagentSummaryRow(
                        turnCount: conversation.subagentTurns.count,
                        cost: conversation.subagentCost
                    )
                    .padding(.leading, 30)
                }
            }
        }
    }
}

private struct SubagentSummaryRow: View {
    let turnCount: Int
    let cost: Double

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.on.square")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(turnCount) subagent turn\(turnCount == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(CostFormat.string(from: cost))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}
