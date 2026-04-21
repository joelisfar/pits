# Pits

A macOS app that monitors Claude Code sessions in real time, tracks API costs, and keeps you aware of cache expiration so you never pay for a cold turn you thought was warm. Designed to live on a second display — a pit master's view of all your fires.

## Why this exists

There are plenty of "Claude Code usage" dashboards. Pits is different: it's a persistent, ambient monitor focused on two things other tools ignore:

1. **Cache TTL awareness** — every conversation shows a countdown to cache expiration. You always know if your next turn will be warm or cold.
2. **Real-time cost projection** — the estimated cost of your next turn updates dynamically, flipping from the warm price to the cold price the moment cache expires.

It also plays sounds on activity so you can context-switch away from your terminal and still know what's happening.

## Core features (v1)

### Windowed app

- Standard macOS window, resizable, meant to be kept open on a second display
- Window remembers its position and size between launches (standard SwiftUI state restoration)
- Compact enough to be useful at small sizes (~400px wide) but can expand to fill more space
- Respects system appearance (light/dark mode)

### Conversation list

- Lists every active Claude Code conversation, sorted by most recent activity
- Each row shows:
  - Project name / directory (parsed from the JSONL path, e.g. `~/.claude/projects/-Users-joel-code-myproject/`)
  - Total cost so far (sum of all input + output costs for that session)
  - Cache status indicator: **warm** (orange) or **cold** (gray)
  - Cache TTL countdown timer (e.g. "3:42 remaining") — counts down from the last API response timestamp. When it hits 0:00, the row transitions from warm to cold.
  - Estimated next-turn cost — shows the projected input cost for the next turn based on the current context size. This value changes when warm→cold transition happens (cache read cost → full input cost).

### Sounds

- **Message received**: play a short, pleasant notification sound when Claude sends a response (i.e., when new assistant content is appended to a JSONL file)
- **One minute warning**: play a distinct alert sound when any conversation's cache TTL reaches 1:00 remaining
- Use macOS system sounds initially (e.g. `NSSound(named: "Blow")`, `NSSound(named: "Ping")`). Can be made configurable later.

### Cache TTL logic

- Default TTL: **5 minutes** from the timestamp of the last API response in that conversation
- Store this as a configurable setting (in UserDefaults) so it can be adjusted later
- Future enhancement: automatic TTL detection by analyzing cache hit ratios in the logs. Out of scope for v1 — just use the 5-minute default with a preference to change it.

## Data source

Claude Code writes session logs as JSONL files in `~/.claude/projects/`. Each project directory contains one or more `.jsonl` files.

### JSONL structure (what to parse)

Each line is a JSON object. The relevant entries have a `type` field. Key types:

- **API request/response pairs**: contain model name, token counts (input, output, cache_read, cache_creation), and a `requestId` for deduplication
- **Token counts to extract**: `inputTokens`, `outputTokens`, `cacheReadInputTokens`, `cacheCreationInputTokens`
- **Timestamps**: use the entry's timestamp to determine recency and calculate cache TTL

### Reference implementation

The Python extraction logic in [joelisfar/gh-claude-costs](https://github.com/joelisfar/gh-claude-costs) (`extract.py`) handles:
- Globbing JSONL files from `~/.claude/projects/`
- Deduplicating API calls by `requestId`
- Classifying turns as warm/cold/session-start based on cache token ratios
- Cost calculation per model with per-token pricing

Port this logic to Swift. The cost-per-token rates and classification heuristics in that file are the source of truth.

## Architecture

### Technology

- **SwiftUI** for all UI
- **Swift** for data layer
- **MenuBarExtra** is not needed — this is a standard windowed app. Use `WindowGroup` as the scene.
- No external dependencies. Stdlib only.

### File watching

- Use `DispatchSource.makeFileSystemObjectSource` or `FSEvents` to watch `~/.claude/projects/` recursively for changes to `.jsonl` files
- When a file changes, read only the new lines appended since last read (track file offsets per path)
- Parse new lines, update the in-memory model, recalculate costs

### Data model (rough shape)

```
Conversation
  - id: String (derived from JSONL file path)
  - projectName: String (human-readable, parsed from path)
  - filePath: URL
  - totalCost: Double
  - lastActivityTimestamp: Date
  - lastResponseTimestamp: Date (for cache TTL calc)
  - cacheStatus: .warm | .cold (computed from TTL)
  - cacheTTLRemaining: TimeInterval (computed, counts down)
  - estimatedNextTurnCost: Double (computed, changes on warm→cold)
  - turns: [Turn] (parsed API calls with token counts and costs)

Turn
  - requestId: String
  - model: String
  - timestamp: Date
  - inputTokens: Int
  - outputTokens: Int
  - cacheReadTokens: Int
  - cacheCreationTokens: Int
  - inputCost: Double
  - outputCost: Double
```

### Timer management

- A single shared timer (every 1 second) updates all cache TTL countdowns
- When any conversation crosses the 1:00 remaining threshold, play the warning sound (once per conversation per cycle — don't re-trigger)
- When a conversation hits 0:00, flip its status to cold and recalculate `estimatedNextTurnCost`

## UI design direction

Keep it utilitarian and information-dense. Think "Activity Monitor meets terminal." This is a tool for developers, not a consumer product.

- Dark background (match macOS dark mode, respect system appearance)
- Monospaced type for numbers, costs, and timers
- Warm sessions: subtle orange/amber accent
- Cold sessions: dimmed/gray
- The warm→cold transition should be visible but not dramatic — a color fade, not an animation
- Compact rows. No wasted space. Information density over decoration.
- Minimum window width: ~400px. Should look good from narrow sidebar-width up to a wider layout.
- Consider a fire pit glyph or stylized flames for the app icon.

## Settings (minimal for v1)

Accessible via a gear icon in the window footer or a standard Settings window (Cmd+,):

- Cache TTL duration (default: 300 seconds)
- Sound on/off toggle (global)
- Launch at login toggle

## Project structure

```
Pits/
├── Pits.xcodeproj
├── Pits/
│   ├── PitsApp.swift             # App entry point, WindowGroup
│   ├── Views/
│   │   ├── ConversationListView.swift
│   │   ├── ConversationRowView.swift
│   │   └── SettingsView.swift
│   ├── Models/
│   │   ├── Conversation.swift
│   │   └── Turn.swift
│   ├── Services/
│   │   ├── LogWatcher.swift       # File system monitoring
│   │   ├── LogParser.swift        # JSONL parsing, cost calculation
│   │   ├── CacheTimer.swift       # TTL countdown management
│   │   └── SoundManager.swift     # Notification sounds
│   ├── Stores/
│   │   └── ConversationStore.swift  # ObservableObject, central state
│   └── Resources/
│       └── Assets.xcassets
```

## What success looks like

I can be in another app, hear a chime, glance at Pits on my second display, see that my Claude session just cost $0.12, has 3:20 left on its cache, and the next turn will cost ~$0.04 warm or ~$0.18 cold. If I need to send another message, I know I have time. If I hear the one-minute warning, I know to either send now or accept the cold cache cost.

## Out of scope for v1

- Automatic cache TTL detection
- Historical cost tracking / charts
- Multiple account support
- Cost alerts / budget limits
- iOS / iPad companion
- Export or sync

## Notes for implementation

- Target macOS 14+ (Sonoma) for latest SwiftUI APIs
- The `gh-claude-costs` repo's `extract.py` is the reference for JSONL parsing. Read it before writing the Swift parser.
- Don't over-engineer the data layer. This is a monitor, not a database. In-memory state rebuilt from JSONL on launch is fine.
- Test with real Claude Code session logs from `~/.claude/projects/`.
