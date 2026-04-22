import SwiftUI

struct ConversationRowView: View {
    let conversation: Conversation
    let now: Date
    /// Whether the user currently has this session open (a live Claude Code
    /// tab or terminal). Closed sessions still appear in the list (they're
    /// real conversations with real cost) but are de-emphasized: no status
    /// dot, no live countdown, reduced row opacity.
    var isOpen: Bool = true
    /// When non-nil the row is a parent with subagents — renders a chevron
    /// the parent cell flips to expand/collapse. `nil` hides the chevron.
    var isExpanded: Binding<Bool>? = nil

    private var status: CacheStatus { conversation.cacheStatus(at: now) }
    private var remaining: TimeInterval { conversation.cacheTTLRemaining(at: now) }

    private var accent: Color {
        switch status {
        case .warm: return remaining <= 60 ? .red : .orange
        case .cold: return .secondary
        case .new: return .secondary
        }
    }

    /// Dot fill: accent for warm+open, gray for cold+open, hidden for closed.
    /// The dot's frame is always reserved so the title column doesn't jump
    /// when a session transitions open ↔ closed.
    private var dotFill: Color {
        guard isOpen else { return .clear }
        return status == .warm ? accent : .secondary
    }

    /// Countdown is a live, attention-grabbing element — only shown when the
    /// user has an open tab to act on. Closed-but-warm sessions still display
    /// the "warm" label (the cache is genuinely warm server-side) but without
    /// the ticking timer, since nothing is going to refresh it.
    private var showCountdown: Bool { isOpen && status == .warm }

    private var rowOpacity: Double {
        if !isOpen { return 0.45 }
        return status == .cold ? 0.65 : 1.0
    }

    private var remainingText: String {
        let total = Int(remaining.rounded(.down))
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    private func formatCost(_ v: Double) -> String {
        CostFormat.string(from: v)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Disclosure chevron — matches Finder's sidebar glyph.
            if let isExpanded {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { isExpanded.wrappedValue.toggle() }
                } label: {
                    Image(systemName: "chevron.forward")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.7))
                        .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                        .frame(width: 18, height: 18, alignment: .center)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                // Keep the row's start-of-content aligned whether or not
                // there's a disclosure triangle.
                Spacer().frame(width: 18)
            }

            // Status dot — pinned to the title line, Mail-style. Three states:
            // open+warm = accent dot, open+cold = gray dot, closed = hidden.
            // The column stays reserved in all cases so the title column
            // lines up across rows.
            Circle()
                .fill(dotFill)
                .frame(width: 8, height: 8)
                .padding(.top, 5)

            // Primary label: AI-generated title if present, else the first
            // user message (Claude Code skips title generation for slash-
            // command openers), else the project path alone.
            VStack(alignment: .leading, spacing: 1) {
                if let heading = conversation.title ?? conversation.firstMessageText {
                    Text(heading)
                        .font(.system(.body, design: .default))
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(conversation.projectName)
                        .font(.system(.caption2, design: .default))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Text(conversation.projectName)
                        .font(.system(.body, design: .default))
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 2) {
                Text(formatCost(conversation.totalCost))
                    .font(.system(.body, design: .monospaced))
                Text("next turn ~\(formatCost(conversation.estimatedNextTurnCost(at: now)))")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .trailing, spacing: 2) {
                // Always render the countdown line — opacity 0 when not
                // displayed — so all rows share a consistent height and the
                // list doesn't reflow on warm ↔ cold or open ↔ closed.
                Text(showCountdown ? remainingText : " ")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(accent)
                    .opacity(showCountdown ? 1 : 0)
                Text(status == .warm ? "warm" : "cold")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 60, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .opacity(rowOpacity)
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
        turns: [turn]
    )
    return ConversationRowView(conversation: c, now: Date(), isExpanded: .constant(false))
        .padding()
        .frame(width: 420)
}
