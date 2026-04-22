# Pits — Handoff: "is-session-open" detection

**Status:** Research + design complete. No code shipped this session. Three features scoped and ready to implement.

**Repo:** `/Users/jifarris/Projects/pits`. On `main`. Working tree had three unstaged modifications entering this session (`PitsApp.swift`, `Stores/ConversationStore.swift`, `Views/ConversationRowView.swift`) — **not touched here**, preserve them.

---

## What we discovered

Claude Code writes a one-file-per-live-session JSON at `~/.claude/sessions/<PID>.json`. Example contents for a VS Code extension session:

```json
{"pid":97560,"sessionId":"a87b74a1-cf9c-46c5-a43a-39743aa2e56b",
 "cwd":"/Users/jifarris/Projects/pits","startedAt":1776874213278,
 "version":"2.1.116","kind":"interactive","entrypoint":"claude-vscode"}
```

**Tested empirically (four tab-close cycles):** closing a Claude Code tab in VS Code reliably removes that tab's `sessions/<PID>.json` file. Zero leaks across the test run.

**The PID in that JSON is not reliable for liveness checks.** The VS Code extension spawns the `claude` binary per-turn — between turns there is no live process for an open tab. `kill -0 <PID>` therefore gives false negatives. **Use file existence, not PID liveness, as the open-signal.**

**sessionId is the stable identifier.** It matches the filename of the conversation JSONL at `~/.claude/projects/<project-dir>/<sessionId>.jsonl` — so Pits' existing conversation IDs line up directly with the open-set.

**`entrypoint` field** distinguishes `claude-vscode` (extension) from terminal CLI. Not currently needed but available if we want to differentiate.

**Prompt cache warmth is unaffected by tab state.** Anthropic's prompt cache (5-min default TTL, 1-hr extended) runs on server-side timers. Closing a tab does not expire the cache. A closed-but-recent conversation is still cache-warm if re-opened within the window — Pits' current `warm`/`cold` logic remains correct regardless of open/closed.

**Hook notes (for context, not for use):** `SessionEnd` exists with `reason` values `clear | resume | logout | prompt_input_exit | bypass_permissions_disabled | other`. Docs explicitly say the hook is "no blocking possible" and "asynchronous for observability only" — it may not complete on abrupt exits. Filesystem-based detection is more reliable than hooks here.

---

## Proposed plan (in build order)

### 1. Open-sessions service + suppress "1m remaining" warning for closed sessions

**Scope:** smallest blast radius, biggest user value.

- New service (candidate name: `OpenSessionsWatcher`) — observes `~/.claude/sessions/` and exposes `@Published var openSessionIds: Set<String>`. FSEvents on the directory is ideal; a 1-Hz poll is also acceptable (file count is tiny).
- Gate the warning emission in [CacheTimer.swift:42](../Pits/Services/CacheTimer.swift#L42) — if the conversation's sessionId isn't in the open set, don't emit `oneMinuteWarning`.
- **Write tests first (TDD, per project convention):** feed the timer a conversation with a closed sessionId and assert no `oneMinuteWarning` event is produced.
- The `warnedOneMinute` flag on `Snapshot` should still be set when we skip — so we don't fire the warning if the session is later re-opened and we're already past the 60-second mark.

### 2. Row indicator: gray dot / no dot / warm dot

- Current behavior in [ConversationRowView.swift:56,97,101](../Pits/Views/ConversationRowView.swift#L56): warm → accent-colored dot + "next turn ~Xs" line; cold → transparent dot + opacity-0 countdown (placeholder to prevent row jump).
- Target behavior:
  - **Open + warm:** accent dot + countdown (unchanged).
  - **Open + cold:** gray dot (user's request: "bring that 'gray dot' back"), no countdown.
  - **Closed:** no dot, no countdown, row rendered at `.opacity(0.65)` or similar.
- Model change: either extend `CacheStatus` with a `.closed` case, or add a parallel `isOpen: Bool` on the row's view model. Parallel flag is cleaner — `CacheStatus` describes cache warmth (an independent axis from session liveness) and conflating them would tangle semantics.
- **Row height must not shift** when a session transitions closed → open. Keep the countdown placeholder logic that v0.1.1 introduced.

### 3. Deep-link "Open in VS Code"

Nice-to-have. Deferred. `code --reuse-window /path/to/project` re-focuses a project; there's no documented CLI for jumping to a specific Claude Code tab. Would likely require the VS Code extension to expose a URL scheme (e.g. `vscode://anthropic.claude-code/open?sessionId=...`) — Anthropic may or may not have one. Check extension source under `~/.vscode/extensions/anthropic.claude-code-*` before giving up.

---

## Open design questions (pin these down before writing code for #1/#2)

### Q1. Does a Pits "conversation" ever span multiple sessionIds?

**User's position:** they don't use `/clear`, so for them one tab = one sessionId = one conversation.

**The general case is 1:N.** `/clear` ends the current session (`SessionEnd` reason `clear`) and starts a new one *in the same VS Code tab*. So a tab that's seen `/clear` has produced a sequence of sessionIds. Resume-as-new-session and fork behaviors likely also create new sessionIds.

**Impact:** if Pits ever groups multiple sessionIds into a single displayed conversation, the "is open" check needs to be `contains(any: conversation.sessionIds) in openSet`, not a single-sessionId lookup. Today each JSONL file is its own conversation row, so this may already be handled — but verify before committing to a 1:1 API shape for the open-sessions service.

**Action for next session:** grep for how the store aggregates turns across sessionIds. If every row is exactly one sessionId, the service can expose a simple `isOpen(sessionId:) -> Bool`. If rows can span, the service's public API should still be per-sessionId and the conversation layer does the `any` check.

### Q2. Per-day cost accrual for multi-day conversations (new requirement surfaced this session)

**Current behavior (v0.0.7):** per-turn bucketing across **months**. A session that spans months appears in every month, each instance showing that month's slice — matches per-turn reference dashboards.

**Not yet implemented:** same treatment at the **day** granularity. If a conversation had $5 on Monday and $3 on Tuesday, it should show on both days with the respective slice, with an indicator that it's part of a continuing conversation. Today's view likely shows the whole conversation's cost on the day of its first turn (or last — verify).

**Why it matters:** per-day views should reflect cost accrued *that day*, not anchor-to-creation-date.

**Implementation sketch:** `Conversation.filtered(toMonth:in:)` already exists — `filtered(toDay:in:)` or a generalized `filtered(toRange:)` follows the same pattern (`range.contains(timestamp)`). The "part of a continuing conversation" indicator is a UI affordance — small chevron/tick or a muted icon on the row.

**Not urgent.** Capture as a known follow-up, not a blocker for #1/#2.

---

## Gotchas the next agent should know

1. **The `claude` process is ephemeral in the VS Code extension.** Between turns there is no live PID. Don't use `kill -0 <PID>` as a liveness check — you'll get false negatives. File existence in `~/.claude/sessions/` is the reliable signal.

2. **Stale lock files exist in `~/.claude/ide/*.lock`.** Two stale `.lock` files were observed for dead PIDs during testing. *Don't* use those for open-detection; they leak. `~/.claude/sessions/*.json` appears to be cleaned up reliably on tab close — observed four-for-four in testing.

3. **Session JSONs include sessions from other projects.** The watcher should read everything under `~/.claude/sessions/` and filter by matching sessionId (or by `cwd`) at the consumer level. Example observed: a `ripple`-project session co-existed with two Pits sessions.

4. **`SessionEnd` hook is not suitable for this.** Docs say it's "asynchronous for observability only" with "no blocking possible." On abrupt terminal/window close, the hook may not finish. We verified the filesystem cleanup happens anyway — so trust the files, not the hook.

5. **sessionIds in `sessions/<PID>.json` match Pits' JSONL filenames exactly.** No translation layer needed.

6. **Working tree was dirty entering this session.** Three modifications were present in `PitsApp.swift`, `Stores/ConversationStore.swift`, `Views/ConversationRowView.swift` at start — preserve them when creating a feature branch. Per the "don't silently discard stash contents" feedback rule, ask before dropping any stash.

---

## How to start the next session

Paste into the next chat:

> Follow the handoff doc at `/Users/jifarris/Projects/pits/docs/4-22-handoff-1.md`. Start on #1 (open-sessions service + suppress 1m warning for closed sessions). Before writing code, answer Q1 by grepping how the store aggregates turns per conversation row — confirm the 1 conversation = 1 sessionId assumption holds in current code. Then TDD the feature: test-first that `CacheTimer` does not emit `oneMinuteWarning` for conversations whose sessionId is not in the open set. Ship as its own PR before starting #2.
