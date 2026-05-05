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
