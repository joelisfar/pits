import SwiftUI

struct ConversationListView: View {
    @ObservedObject var store: ConversationStore

    var body: some View {
        VStack(spacing: 0) {
            if store.conversations.isEmpty {
                emptyState
            } else {
                TimelineView(.periodic(from: .now, by: 1.0)) { context in
                    List(store.conversations) { c in
                        ConversationRowView(conversation: c, now: context.date)
                    }
                    .listStyle(.plain)
                }
            }

            Divider()

            HStack {
                Text("\(store.conversations.count) conversation\(store.conversations.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                SettingsLink {
                    Image(systemName: "gear")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(minWidth: 400, minHeight: 220)
        .background(Color(nsColor: .windowBackgroundColor))
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
}
