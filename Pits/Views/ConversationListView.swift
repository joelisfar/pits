import SwiftUI
import AppKit

struct ConversationListView: View {
    @ObservedObject var store: ConversationStore
    @AppStorage("net.farriswheel.Pits.alwaysOnTop") private var alwaysOnTop: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            if store.conversations.isEmpty {
                if store.isLoading { loadingState } else { emptyState }
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
        .onAppear { applyWindowLevel() }
        .onChange(of: alwaysOnTop) { _, _ in applyWindowLevel() }
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
}
