# Pits — Release Pipeline, Phase 2 Design

**Status:** Drafted 2026-05-04
**Target branch:** `v0.2.0`
**Predecessor:** [Phase 1 design](2026-04-22-release-pipeline-phase1-design.md) (unsigned `.dmg`, manual install, local-only `release.sh`)

## Problem

Phase 1 ships unsigned `.dmg` artifacts. End users must right-click → Open on first launch and there is no in-app update mechanism. To upgrade Pits, users have to remember to check the GitHub Releases page and re-run the install flow. This works as a stopgap on an MDM-managed Mac that allows unsigned binaries, but is friction every release.

Phase 2 closes both gaps:
- Signed and notarized builds remove the Gatekeeper right-click prompt — installs become double-click.
- Sparkle-driven auto-update removes the manual "go check the releases page" loop entirely.

Apple Developer individual enrollment (started 2026-04-22) is now active, unblocking signing and notarization. Phase 2 also takes the opportunity to move all credential-bearing work into GitHub Actions, so Apple signing material lives only in GH secrets — never on a developer laptop.

## Goals

1. Pushing a `v*` git tag triggers a GitHub Actions workflow that builds, signs, notarizes, packages, and publishes a release with a stapled `.dmg`.
2. End users running v0.2.0+ receive an in-app update prompt within ~3 days of a new release; checking on demand is also possible from the app's main window.
3. The Apple Developer ID certificate, App Store Connect API key, and Sparkle EdDSA private key live only in GH Actions secrets after initial setup. Local laptops carry no signing material in steady state.
4. `release.sh` becomes the operator's tagging tool — version bump, release notes assertion, commit, tag, push. It needs no Apple credentials.
5. The release stanza in `RELEASE_NOTES.md` is the single source of truth for both the GitHub Releases page body and the Sparkle update prompt's "What's New" content.

## Non-goals

- Mac App Store distribution (would require sandboxing, which conflicts with Sparkle's in-place install).
- Beta / pre-release / RC channels. One appcast, one track.
- Sparkle delta updates (full DMG download is fine at Pits' size).
- In-app migration tooling for existing v0.1.x users. They download v0.2.0 manually one time; auto-update takes over after that.
- Replacing or restyling Sparkle's standard update prompt window. We layer affordances on top, not under.
- A custom appcast hosting solution. We commit `appcast.xml` to `main` and serve via raw.githubusercontent.com.
- Local sign/notarize as a steady-state path. CI is the only credentialed runner after Phase 2 lands.

## Architecture

```
┌─────────────────────────┐         ┌──────────────────────────────────┐
│ Local (operator laptop) │         │ GitHub Actions (per tag push)    │
├─────────────────────────┤         ├──────────────────────────────────┤
│ release.sh X.Y.Z:       │         │ release.yml:                     │
│  - preflight            │         │  - import cert into temp keychain│
│  - bump_version         │ git push│  - xcodegen + xcodebuild         │
│  - assert RELEASE_NOTES │  ──────▶│    (Release, hardened, signed)   │
│  - commit + tag + push  │  v0.2.0 │  - codesign verify               │
│                         │         │  - package_dmg                   │
│ (no Apple credentials)  │         │  - notarytool submit --wait      │
└─────────────────────────┘         │  - stapler staple                │
                                    │  - generate_appcast (EdDSA sign) │
                                    │  - commit appcast.xml to main    │
                                    │  - gh release create + .dmg      │
                                    │  - delete temp keychain          │
                                    └────────────┬─────────────────────┘
                                                 │ writes
                              ┌──────────────────▼────────────────────┐
                              │ raw.githubusercontent.com/.../        │
                              │ appcast.xml (signed, public)          │
                              └──────────────────┬────────────────────┘
                                                 │ polled every 3 days
                              ┌──────────────────▼────────────────────┐
                              │ End-user Pits.app:                    │
                              │  Sparkle verifies EdDSA signature,    │
                              │  prompts user, downloads, installs    │
                              └───────────────────────────────────────┘
```

The local script and CI job are decoupled: `release.sh` only mutates git state. CI does everything that needs Apple credentials. The two communicate exclusively through the pushed tag and the contents of the tagged commit.

## Components

### A. Sparkle integration (Swift)

**SwiftPM dependency** added to `project.yml`:

```yaml
packages:
  Sparkle:
    url: https://github.com/sparkle-project/Sparkle
    from: 2.6.0
```

`Sparkle` joins the `Pits` target's `dependencies` list. xcodegen handles the rest.

**`Pits/Updates/UpdaterModel.swift`** (new) — `@MainActor` `ObservableObject` wrapping `SPUStandardUpdaterController`. Conforms to `SPUUpdaterDelegate`. Exposes:

```swift
@Published private(set) var updateAvailable: Bool = false
var canCheckForUpdates: Bool { ... }
func checkForUpdates() { ... }

// SPUUpdaterDelegate:
func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
    updateAvailable = true
}
func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
    updateAvailable = false
}
```

The model is created once in `PitsApp.init` and held as a `@StateObject`.

**`Pits/Updates/CheckForUpdatesView.swift`** (new) — small SwiftUI view with a "Check for Updates…" button bound to `UpdaterModel.checkForUpdates`. Disabled when `canCheckForUpdates` is false. Mounted inside `SettingsView`.

**`Pits/Views/ConversationListView.swift`** (modified) — the bottom status row at lines 43–53 currently renders the conversation count + total on the left and a `ProgressView` on the right when `store.isLoading`. Add a new branch:

```swift
HStack {
    Text(statusBarText)...
    Spacer()
    if store.isLoading {
        ProgressView()...
    } else if updaterModel.updateAvailable {
        Button(action: { updaterModel.checkForUpdates() }) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.blue)
        }
        .buttonStyle(.plain)
        .help("Update available — click to install")
    }
}
```

`isLoading` wins if both are true (loading is rare and short-lived; the indicator returns once loading clears).

**`Pits/PitsApp.swift`** (modified) — `MenuBarRouter` learns about `updaterModel`; `AppDelegate.refreshIcon()` reads `updaterModel.updateAvailable` and composes a small accent dot onto the flame symbol when true (so the user notices an update even with the main window closed). Implementation: `NSImage.SymbolConfiguration` with a paletteColors overlay, OR a separate small `NSImage` drawn at the bottom-right of the base symbol via `NSImage(size:flipped:drawingHandler:)`. Pick whichever produces a clean result during implementation.

**Info.plist additions (via `project.yml` → `infoPlist`):**

```yaml
SUFeedURL: https://raw.githubusercontent.com/joelisfar/pits/main/appcast.xml
SUEnableAutomaticChecks: true
SUScheduledCheckInterval: 259200    # 3 days, in seconds
SUPublicEDKey: <pasted at setup time, see Bootstrap below>
```

### B. Hardened Runtime + entitlements

**`Pits/Pits.entitlements`** (new) — minimal. Pits doesn't sandbox and doesn't need any specific entitlements; the file exists because hardened runtime requires `CODE_SIGN_ENTITLEMENTS` to be set:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
</dict>
</plist>
```

**`project.yml` settings additions** in the `Pits` target's `settings.base`:

```yaml
ENABLE_HARDENED_RUNTIME: YES
CODE_SIGN_ENTITLEMENTS: Pits/Pits.entitlements
CODE_SIGN_STYLE: Manual
# CODE_SIGN_IDENTITY and DEVELOPMENT_TEAM are passed by xcodebuild in CI;
# leave blank in project.yml so local debug builds remain unsigned.
```

### C. `RELEASE_NOTES.md` (new)

Stanza-per-version, newest first:

```markdown
## v0.2.0

- Signed and notarized builds — no more right-click → Open on first launch
- Auto-update via Sparkle (checks every 3 days; manual check from Settings)
- Update-available indicator in the main window status row

If you're upgrading from v0.1.x, download and install v0.2.0 manually one
last time. After that, Pits will auto-update on its own.

## v0.1.9
- ...
```

The format is conventional Markdown — `## vX.Y.Z` heading, then prose. Both `release.sh`'s preflight (assertion only) and the GH Actions release-notes step (extraction) parse it the same way: take the block of lines from the first `## ` heading through the line before the next `## ` heading.

### D. `scripts/release.sh` (modified)

Becomes a thin local-only tool. Phases:

```
release.sh X.Y.Z
  preflight()           → version regex, branch, tree, sync, tag, version monotonic, gh auth, RELEASE_NOTES.md has stanza
  bump_version()        → edit project.yml, xcodegen
  assert_notes()        → grep for "^## v$VERSION$" in RELEASE_NOTES.md
  tag_and_push()        → commit project.yml + Pits.xcodeproj, tag, push main + tag
  print_ci_url()        → "CI started: https://github.com/joelisfar/pits/actions"
```

Removed phases (now CI's job): `build_release`, `package_dmg`, `publish`.

### E. `scripts/lib/package_dmg.sh` (new, extracted)

The current `release.sh` packaging block (hdiutil + staging dir + Applications symlink) moves into this library script so CI can `bash scripts/lib/package_dmg.sh "$VERSION"`. ~30 lines, no logic change.

### F. `.github/workflows/release.yml` (new)

Triggered on `push: tags: ['v*']`. Runs on `macos-14`. Steps:

1. **checkout** with `fetch-depth: 0`
2. **import cert** — base64-decode `APPLE_CERT_P12_BASE64` to a tempfile, create temp keychain, import with `security import`, set partition list. Tempfile deleted after import.
3. **xcodegen + xcodebuild** — Release config, hardened, signed with `CODE_SIGN_IDENTITY="Developer ID Application"`, `DEVELOPMENT_TEAM="$APPLE_TEAM_ID"`, into `build/release/`.
4. **verify codesign** — `codesign -dv --verbose=4` and `codesign --verify --deep --strict --verbose=2`. Fail-fast surface for a busted cert import.
5. **package DMG** — call `scripts/lib/package_dmg.sh "${GITHUB_REF_NAME#v}"`.
6. **notarize + staple** — base64-decode `APPSTORE_API_KEY_P8_BASE64` to `$RUNNER_TEMP/key.p8`, run `xcrun notarytool submit dist/Pits-X.Y.Z.dmg --key … --key-id … --issuer … --wait`, then `xcrun stapler staple`. Tempfile deleted after.
7. **render release notes to HTML** — extract the stanza for `${GITHUB_REF_NAME}` from `RELEASE_NOTES.md` (awk against `^## ` headings) and pipe through a Markdown→HTML renderer (use `pandoc` if available on the runner, fall back to a tiny `sed` for the bullet→`<li>` and para→`<p>` cases since the format is constrained). Write to `dist/Pits-${VERSION}.html`. `generate_appcast` will pick this up and embed it as the appcast item's `<description>` (CDATA-wrapped), which is what Sparkle's update prompt renders as "What's New".
8. **generate appcast** — write `SPARKLE_ED_PRIVATE_KEY` secret to `$RUNNER_TEMP/sparkle_priv.txt`, run `generate_appcast --ed-key-file … dist/`. Tempfile deleted after.
9. **commit appcast.xml back to main** — copy `dist/appcast.xml` to repo root, configure `github-actions[bot]` user, commit, push to `main`. The push uses `${{ github.token }}` (GHA's default scoped token), which has `contents: write` because the job declares `permissions: contents: write`.
10. **publish GH release** — reuse the extracted stanza from step 7 (Markdown form), `gh release create "$GITHUB_REF_NAME" --title "$GITHUB_REF_NAME" --notes "$NOTES" "dist/Pits-${VERSION}.dmg"`. (GitHub renders Markdown natively in release pages, so no HTML conversion needed here — the same source stanza serves both surfaces in their respective formats.)
11. **cleanup** — `if: always()` step that deletes the temp keychain.

**Required secrets** (set via Settings → Secrets and variables → Actions):

| Secret | Source |
|---|---|
| `APPLE_CERT_P12_BASE64` | `base64 -i developer-id-app.p12` |
| `APPLE_CERT_P12_PASSPHRASE` | passphrase chosen in Keychain Access export |
| `APPLE_TEAM_ID` | 10-char Team ID from `security find-identity` output |
| `APPSTORE_API_KEY_P8_BASE64` | `base64 -i AuthKey_XXXXX.p8` |
| `APPSTORE_API_KEY_ID` | 10-char Key ID from App Store Connect |
| `APPSTORE_API_ISSUER_ID` | UUID from App Store Connect |
| `SPARKLE_ED_PRIVATE_KEY` | Output of `generate_keys -x sparkle_priv.txt; cat sparkle_priv.txt` |
| `KEYCHAIN_PASSWORD` | Any random string; only used to unlock the temp build keychain |

## Bootstrap (one-time, manual)

This is the operator-side flow that produces the eight secrets above. None of this is automated — Apple's portals are humans-only and the secrets are too sensitive to script.

### Step 1 — Developer ID Application certificate

1. **Generate CSR locally:** Keychain Access → Keychain Access menu → Certificate Assistant → **Request a Certificate From a Certificate Authority…**
   - User Email Address: your Apple ID email
   - Common Name: e.g. "Joel Farris"
   - Leave CA Email Address blank
   - **Saved to disk** → save the `.certSigningRequest`
2. **Create cert at Apple:** developer.apple.com → Account → **Certificates, IDs & Profiles** → **Certificates** → **+** → **Software** section → **Developer ID** → Continue → **Developer ID Application** → upload the CSR → Download the `.cer`.
   - Requires Account Holder role (you have this as an individual enrollee).
   - Limit: 5 active Developer ID Application certs per account.
   - Cert validity: 18 years.
3. **Install + verify:** double-click the `.cer` to add it to login keychain. Then:
   ```sh
   security find-identity -p codesigning -v | grep "Developer ID Application"
   ```
   Should print `1) <hash> "Developer ID Application: Joel Farris (TEAMID12345)"`. Note the 10-char Team ID — that's `APPLE_TEAM_ID`.
4. **Export for CI:** Keychain Access → My Certificates → right-click the cert → **Export…** → `developer-id-app.p12` with a strong passphrase.
   - `base64 -i developer-id-app.p12 | pbcopy` → paste into `APPLE_CERT_P12_BASE64` secret.
   - Passphrase → `APPLE_CERT_P12_PASSPHRASE` secret.
   - Team ID → `APPLE_TEAM_ID` secret.

### Step 2 — App Store Connect API key

1. **Create at Apple:** appstoreconnect.apple.com → **Users and Access** → **Integrations** tab → **App Store Connect API** → **Team Keys** → **+** (Generate API Key).
   - Name: "Pits Notarization"
   - Access: **Developer** role (sufficient for notarytool — confirmed in [Apple forums](https://developer.apple.com/forums/thread/133063))
2. **Download:** `AuthKey_XXXXX.p8` — **one-time download**. Apple will not let you re-download. Note the **Key ID** (10 chars on the page) and **Issuer ID** (UUID at the top of the page).
3. **Verify locally** (optional sanity check):
   ```sh
   xcrun notarytool history --key ./AuthKey_XXXXX.p8 --key-id XXXXX --issuer YYYY-…
   ```
   Should return either an empty list or past submissions.
4. **Encode for CI:**
   - `base64 -i AuthKey_XXXXX.p8 | pbcopy` → `APPSTORE_API_KEY_P8_BASE64` secret
   - Key ID → `APPSTORE_API_KEY_ID` secret
   - Issuer ID → `APPSTORE_API_ISSUER_ID` secret

### Step 3 — Sparkle EdDSA keypair

This step happens *after* Sparkle is added as a SwiftPM dep and the project builds once (so the `generate_keys` binary exists in derived data).

1. **Generate:**
   ```sh
   GEN_KEYS=$(find build -name generate_keys -type f | head -1)
   "$GEN_KEYS"
   ```
   Stores private key in login keychain. Prints the public key (base64 string) to stdout. Copy that — it goes into `project.yml`'s `infoPlist.SUPublicEDKey`.
2. **Export for CI:**
   ```sh
   "$GEN_KEYS" -x sparkle_priv.txt
   pbcopy < sparkle_priv.txt
   ```
   Paste into `SPARKLE_ED_PRIVATE_KEY` secret. **Then `rm sparkle_priv.txt`** — keychain copy is the local backup.
3. **Backup outside keychain** — also write the `-x` output into 1Password as belt-and-suspenders. If you lose both keychain and GH secret, future updates can't be signed and the only recovery is shipping a new public key in a future release, breaking auto-update for everyone running the old key.

### Step 4 — Misc

- `KEYCHAIN_PASSWORD` secret: just `openssl rand -hex 32 | pbcopy`. Random string, only used inside the runner to unlock the temp keychain it creates.

## Data flow

### Releasing v0.2.1 (post-bootstrap, normal case)

1. Operator finishes a feature on `v0.2.0` branch, opens PR, merges to `main`.
2. Operator updates `RELEASE_NOTES.md` with a new `## v0.2.1` stanza, commits to main.
3. Operator runs `bash scripts/release.sh 0.2.1` from `main`.
4. Script preflights, bumps version, asserts the notes stanza exists, commits, tags `v0.2.1`, pushes both. Prints CI URL.
5. CI starts. ~5–8 min later: `appcast.xml` is updated on main, GH release `v0.2.1` is published with stapled `.dmg`.
6. Within ~3 days, every running v0.2.0+ instance polls the appcast, sees v0.2.1, prompts the user.

### End-user install (post-v0.2.0)

1. **First time:** download `Pits-0.2.0.dmg` from the Releases page, double-click, drag to `/Applications`. **No right-click required** — that's signing+notarization at work.
2. **Subsequent updates:** Sparkle prompt appears in-app. Click Install → Sparkle downloads, verifies EdDSA signature against embedded public key, prompts for relaunch, replaces the app. No browser involved.

### End-user upgrade from v0.1.x

One-time manual step: download v0.2.0 from Releases, install over the existing app. After that, Sparkle handles everything. Documented in v0.2.0's `RELEASE_NOTES.md` stanza.

## Error handling

| Failure | Behavior |
|---|---|
| `release.sh` preflight detects no `## vX.Y.Z` stanza | Exit 1 with "Add a release notes stanza in RELEASE_NOTES.md before tagging" |
| Cert import fails in CI | Step fails. `security` output shown. Hypothesis: `APPLE_CERT_P12_BASE64` corrupted on paste, or `APPLE_CERT_P12_PASSPHRASE` mismatch. |
| `xcodebuild` fails to find signing identity | Step fails. `codesign` log shown. Hypothesis: cert imported but partition list missing — re-check the `set-key-partition-list` invocation. |
| `codesign --verify` fails | Step fails before notarytool runs (saving credit). Hypothesis: entitlements mismatch or hardened runtime not actually applied — inspect `codesign -dv --verbose=4` output. |
| `notarytool submit --wait` returns Invalid status | Step fails. Run `xcrun notarytool log <submission-id> --key …` from local machine for the full diagnostic. Common causes: missing hardened runtime on a nested binary (Sparkle's XPC services), library validation failures. |
| `stapler staple` fails | Step fails. Notarization didn't actually complete despite `--wait` returning OK. Re-check status with `notarytool info`. |
| `generate_appcast` produces no entries | Step succeeds (no output) but the appcast.xml will be missing the new version. Hypothesis: DMG filename doesn't match Sparkle's expected pattern (`<AppName>-<Version>.dmg`). |
| Push to main fails (e.g. branch protection) | Step fails after notarization succeeded. Recovery: download the artifact from the run, push appcast.xml manually, create the GH release manually. The notarized DMG is preserved as a workflow artifact. |
| `gh release create` fails | Step fails after appcast pushed. Recovery: `gh release create` manually with the artifact downloaded from the run. |

The workflow is **not** transactional. Each step's effects are visible (keychain, file system, git, Apple's notarization service, GitHub Releases) and recovery is a manual judgment call. Recovery hints in step names + run logs give the operator enough to triage.

## Testing

No unit tests — same reasoning as Phase 1. Correctness surface is "produces a working signed/notarized/auto-updateable app." Manual validation is the gate.

**Validation order:**

1. **Local sign smoke test** — before any CI work, sign a Release build on the laptop with the new cert + entitlements:
   ```sh
   xcodebuild -scheme Pits -configuration Release \
     CODE_SIGN_IDENTITY="Developer ID Application" \
     DEVELOPMENT_TEAM="$TEAM_ID" \
     -derivedDataPath build/release clean build
   codesign -dv --verbose=4 build/release/Build/Products/Release/Pits.app
   spctl --assess --type execute --verbose build/release/Build/Products/Release/Pits.app
   ```
   `spctl` should print "accepted source=Notarized Developer ID" only after step 2; for now "accepted source=Developer ID" is fine.

2. **Local notarize smoke test** — package a `.dmg` from the locally-signed build, submit:
   ```sh
   xcrun notarytool submit dist/Pits-test.dmg \
     --key ./AuthKey_XXXXX.p8 --key-id XXXXX --issuer YYYY \
     --wait
   xcrun stapler staple dist/Pits-test.dmg
   ```
   Should complete in 1–5 minutes. Confirms cert + API key + entitlements are all coherent before CI tries the same thing.

3. **Local Sparkle dry-run** — generate keys, paste public key into `project.yml`, build, launch. Verify:
   - App launches without errors
   - Settings → "Check for Updates…" button appears and is enabled
   - Clicking it produces "You're up to date" (since no appcast exists yet)

4. **First CI release: v0.2.0** — push the `v0.2.0` tag, watch the workflow. Iterate on failures (this is where the slow CI debug loop tax we accepted gets paid). Do not delete local credentials yet.

5. **First end-user install on personal Mac** — download `Pits-0.2.0.dmg` from the GH Releases page in a browser, mount, drag to Applications, double-click. Should launch with no Gatekeeper prompt at all (the proof signing+notarization+stapling all worked).

6. **First end-user install on work Mac** — same as 5, plus check that MDM doesn't fight the signed bundle.

7. **First auto-update test** — with v0.2.0 installed, push a v0.2.1 tag (trivial bump — anything that produces a different `CURRENT_PROJECT_VERSION`). Wait for the in-app prompt (or click "Check for Updates" to skip the timer). Verify Sparkle:
   - Downloads the new DMG
   - Verifies the EdDSA signature against the public key embedded in the running v0.2.0
   - Prompts for relaunch
   - Replaces the app and relaunches into v0.2.1

8. **Cleanup** — after step 7 passes, delete local `developer-id-app.p12`, `AuthKey_XXXXX.p8`, and the local Sparkle private key file. CI is the only place they live thereafter. (Keychain copies of cert + Sparkle private key remain as personal backup; 1Password copies remain as disaster-recovery backup.)

**Failure-mode coverage:** the first time CI runs end-to-end, intentionally trigger a notarization failure (e.g. by temporarily disabling hardened runtime) to exercise the recovery flow. Confirms the error messaging is actually useful when something breaks for real.

## Out of scope (Phase 3 candidates)

- **Beta channel** — separate `appcast-beta.xml` for pre-release tags (e.g. `v0.3.0-beta.1`). Useful once user count grows beyond "me".
- **Delta updates** — Sparkle supports binary diffs to shrink update downloads. Not worth the complexity at Pits' size (a few MB).
- **Notarization queue prefetch** — if notarization wait becomes the long pole, submit the unsigned upload earlier in the workflow concurrently with `codesign`. Premature optimization right now.
- **Automated changelog generation** — extracting `RELEASE_NOTES.md` from PR descriptions or commit messages. Hand-authoring is fine while there's one developer.
- **Crash reporting integration** — separate concern; would slot into the signed app naturally but doesn't depend on signing.

Each of these slots into the Phase 2 architecture without restructuring — verified by the workflow step boundaries above.
