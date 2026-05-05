## v0.2.1

Reliability and robustness pass after a thorough review of the v0.2.0 codebase + release pipeline. No user-visible feature changes; everything below is correctness, performance, or hardening.

**Swift correctness:**
- File watcher caps per-pass reads at 16 MB; drops runaway partial lines over 4 MB. Prevents OOM on first backfill of a heavy history or on malformed JSONL.
- Pricing table is now lock-protected (was a global mutable static; safe in production paths today, but a latent race during tests and a maintenance hazard).
- Symlinks pointing outside `~/.claude/projects/` are no longer followed by the JSONL enumerator (defense in depth).
- LiteLLM pricing fetch rejects responses larger than 4 MB.
- `MonthScope.dateRange` no longer crashes on a corrupted cache with invalid year/month.
- `OpenSessionsWatcher` retries once on parse failure when the file still exists — handles the truncate→refill race during Claude Code's session JSON rewrites.
- `Conversation.projectName` is memoized per JSONL URL in the store, so heavy-history users don't pay 1000+ stat syscalls per snapshot rebuild.
- `LogWatcher.stop()` is queue-synchronized; deinit takes a separate unsync'd path to avoid deadlock.
- JSONLDecoder fall-back parser for ISO-8601 timestamps without fractional seconds (no longer silently drops turns if the format ever changes).
- `humanTurnsBySession` dedups by `(sessionId, timestamp)` on both ingest and cache hydration — prevents silent unbounded cache growth.
- Cache `~/Library/Caches/state.json` and `pricing.json` are now `0600` (was 0644); prompt previews capped at 200 characters.
- Errors logged via `os_log` use `%{private}@` for paths to avoid leaks via sysdiagnose.

**Release pipeline:**
- Sparkle dep pinned exactly to 2.9.1 (was loose, with `Package.resolved` gitignored — every CI run did fresh dependency resolution against GitHub).
- `notarytool submit --wait` has a 30-min timeout + the workflow has a 60-min job cap. Apple's notary service has stalled multiple hours; without a timeout the runner could be killed mid-staple.
- Decoded secret tempfiles (`cert.p12`, `key.p8`, `sparkle_priv.txt`) are cleaned up via `trap` on every step — so a failed step doesn't leak the file for the rest of the job.
- `sign_app.sh` audits for unknown nested executables in `Sparkle.framework` and fails loudly if a future Sparkle bump adds a helper we don't know about.
- Sparkle nested re-signing uses `--preserve-metadata` so XPC service entitlements survive (was: stripped, empirically fine but fragile).
- New "Verify Sparkle keypair match" step in CI catches operator error during key rotation (the silent-update-channel-break failure mode).
- Workflow `concurrency: { group: release }` serializes tag-triggered runs.
- `gh release create` runs before the appcast push to `main` (closes the small window where the appcast referenced a not-yet-published DMG).
- `release.sh` does a Release build + sign + verify before tagging, using your locally-installed Developer ID cert. Catches ~80% of notarization-blocking issues in 30 sec locally instead of 8 min in CI.
- `KEYCHAIN_PASSWORD` is now generated inline; the GH secret is no longer needed (delete it after this release ships).

**Docs:**
- New: `docs/runbooks/credential-rotation.md` covers Developer ID cert / App Store API key / Sparkle keypair rotation.

## v0.2.0

- Signed and notarized builds — no more right-click → Open on first launch
- Auto-update via Sparkle (checks every 3 days; manual check from Settings)
- Update-available indicator in the main window status row and on the menu bar icon
- Privacy: `~/Library/Caches/state.json` is now `0600` (was world-readable) and
  cached prompt previews are capped at 200 characters
- Reliability: dedup human turns by `(sessionId, timestamp)` to prevent silent
  cache bloat under offset miscalculation; tolerate ISO-8601 timestamps without
  fractional seconds
- Performance: drop redundant per-second SwiftUI publish in the cache-tick path
- Sparkle dependency pinned exactly to 2.9.1 (supply-chain hardening)

If you're upgrading from v0.1.x: download and install v0.2.0 manually one
last time. After that, Pits will auto-update on its own.
