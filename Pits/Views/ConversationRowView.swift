import SwiftUI

struct ConversationRowView: View {
    let conversation: Conversation
    let now: Date

    private var status: CacheStatus { conversation.cacheStatus(at: now) }
    private var remaining: TimeInterval { conversation.cacheTTLRemaining(at: now) }

    private var accent: Color {
        switch status {
        case .warm: return .orange
        case .cold: return .secondary
        }
    }

    private var remainingText: String {
        let total = Int(remaining.rounded(.down))
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    private func formatCost(_ v: Double) -> String {
        v >= 10.0 ? String(format: "$%.2f", v) : String(format: "$%.3f", v)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // Status dot
            Circle()
                .fill(accent)
                .frame(width: 8, height: 8)

            // Primary label: AI-generated title if present, falling back to the
            // project path. When a title is shown, the project path sits beneath
            // it as a dimmed subtitle.
            VStack(alignment: .leading, spacing: 1) {
                if let title = conversation.title {
                    Text(title)
                        .font(.system(.body, design: .default))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(conversation.projectName)
                        .font(.system(.caption2, design: .default))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                } else {
                    Text(conversation.projectName)
                        .font(.system(.body, design: .default))
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 2) {
                Text(formatCost(conversation.totalCost))
                    .font(.system(.body, design: .monospaced))
                Text("next ~\(formatCost(conversation.estimatedNextTurnCost(at: now)))")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .trailing, spacing: 2) {
                Text(remainingText)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(accent)
                Text(status == .warm ? "warm" : "cold")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 60, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .opacity(status == .cold ? 0.65 : 1.0)
    }
}

#Preview {
    let turn = Turn(
        requestId: "r", sessionId: "s",
        timestamp: Date().addingTimeInterval(-60),
        model: "claude-opus-4-6",
        inputTokens: 10, cacheCreationTokens: 0,
        cacheReadTokens: 25_000, outputTokens: 120,
        stopReason: "end_turn", isSubagent: false
    )
    let c = Conversation(
        id: "s", projectName: "/Users/j/Projects/demo",
        title: "Wire session titles into the row view",
        filePath: URL(fileURLWithPath: "/tmp/x.jsonl"),
        turns: [turn], ttlSeconds: 300
    )
    return ConversationRowView(conversation: c, now: Date())
        .padding()
        .frame(width: 420)
}
