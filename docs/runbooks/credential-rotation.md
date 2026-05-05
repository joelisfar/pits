# Credential rotation runbooks

Three credentials power the Pits release pipeline. Each is rare enough to be forgotten by the time you need to rotate it. These runbooks are short on purpose — paste-able commands, plus the human bits Apple's portals require.

For all three, the canonical source for the GH secrets is:
**Settings → Secrets and variables → Actions** at https://github.com/joelisfar/pits/settings/secrets/actions

---

## 1. Developer ID Application certificate

**When:** Cert expired (18-year validity, so 2044 for the v0.2.0 cert), revoked by Apple, or your `.p12` was lost/leaked.

**Steps:**

### A. Generate a new CSR

Same as the original setup:
1. Keychain Access → Certificate Assistant → **Request a Certificate From a Certificate Authority…**
2. User Email Address: your Apple ID email
3. Common Name: "Joel Farris" (or whatever Apple has on file)
4. Saved to disk → Desktop

### B. Create the cert at developer.apple.com

1. https://developer.apple.com/account/resources/certificates/list
2. **+** → **Software** section → **Developer ID Application**
3. Profile Type: **G2 Sub-CA** (latest)
4. Upload CSR → Continue → Download

### C. Install + verify

```sh
# Double-click the .cer to install, then:
security find-identity -p codesigning -v | grep "Developer ID Application"
```

Should print one identity with the Team ID in parens.

If `0 valid identities found`, you may also need the G2 intermediate cert:
```sh
curl -fsSLo /tmp/G2.cer https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer
security import /tmp/G2.cer -k ~/Library/Keychains/login.keychain-db
```

### D. Export to .p12

1. Keychain Access → My Certificates → right-click cert → **Export…**
2. File Format: **Personal Information Exchange (.p12)**
3. Save to Desktop with a strong passphrase (record in 1Password)

### E. Update GH secrets

```sh
base64 -i ~/Desktop/developer-id-app.p12 | gh secret set APPLE_CERT_P12_BASE64 --repo joelisfar/pits
echo -n '<NEW_PASSPHRASE>' | gh secret set APPLE_CERT_P12_PASSPHRASE --repo joelisfar/pits
gh secret set APPLE_TEAM_ID --repo joelisfar/pits --body 'X93Z3J9F4P'   # only if Team ID changed
```

### F. Verify

Push a test tag to a throwaway version (or wait for the next real release). Watch the **Import signing certificate** and **Build** steps in the workflow log — both must pass.

### G. Revoke the old cert

If the old cert was compromised, revoke it at developer.apple.com → Certificates → click the old cert → **Revoke**. Anything previously signed with it stops working immediately for end users (Sparkle update path included). **Only revoke if you're certain it was leaked.**

---

## 2. App Store Connect API key (notarization)

**When:** Key was revoked, or operator believes it leaked.

The key doesn't expire on its own.

**Steps:**

### A. Create new key

1. https://appstoreconnect.apple.com/access/integrations/api → **Team Keys** tab
2. **+** → Name: `Pits Notarization (rotation YYYY-MM)`
3. Access: **Developer**
4. Generate → **Download** (one-time only) — file lands as `AuthKey_XXXXX.p8`
5. Note the new **Key ID** (filename) and **Issuer ID** (top of page, UUID — same across rotations unless team changes)

### B. Update GH secrets

```sh
base64 -i ~/Downloads/AuthKey_XXXXX.p8 | gh secret set APPSTORE_API_KEY_P8_BASE64 --repo joelisfar/pits
gh secret set APPSTORE_API_KEY_ID --repo joelisfar/pits --body 'XXXXX'   # 10-char Key ID
# Issuer ID typically unchanged — only update if you switched teams:
# gh secret set APPSTORE_API_ISSUER_ID --repo joelisfar/pits --body '...'
```

### C. Verify locally (optional)

```sh
xcrun notarytool history \
  --key ~/Downloads/AuthKey_XXXXX.p8 \
  --key-id XXXXX \
  --issuer c8ea3603-f1a5-468a-aeab-60d4dfc8c1df
```

Should return submission history (or empty list). Auth error means key/IDs don't match.

### D. Revoke old key

After confirming a release tagged with the new key works end-to-end, return to https://appstoreconnect.apple.com/access/integrations/api → click the old key row → **Revoke**.

### E. Delete local copies

Once the new secret is in GH and the old one is revoked:
```sh
rm ~/Downloads/AuthKey_*.p8   # both old and new (you only had the new one for ~10 min)
```

The cert and API key only live in GH secrets in steady state.

---

## 3. Sparkle EdDSA keypair

**The hard one.** Rotation is essentially a one-way migration: clients running a build with the old `SUPublicEDKey` cannot verify updates signed with the new private key, and vice versa.

**When:** Private key leaked. Otherwise, **don't rotate.**

If you do rotate, every existing user is stranded on their current version until they manually download the new build that contains the new public key.

### A. Generate new keypair

After a fresh build (so `generate_keys` is in DerivedData):

```sh
GEN_KEYS=$(find build/release -name generate_keys -type f | head -1)
"$GEN_KEYS"   # prints new public key, stores private in keychain
```

Copy the public key.

### B. Export private for CI

```sh
"$GEN_KEYS" -x ~/Desktop/sparkle_priv_new.txt
```

### C. Update Info.plist

Edit `Pits/Info.plist`, replace `SUPublicEDKey` with the new public key. Commit on a `v0.X.Y` branch (per the standard branch-per-version flow).

### D. Update GH secret

```sh
gh secret set SPARKLE_ED_PRIVATE_KEY --repo joelisfar/pits < ~/Desktop/sparkle_priv_new.txt
rm ~/Desktop/sparkle_priv_new.txt
```

### E. Verify in CI

The release workflow's **Verify Sparkle keypair match** step will fail loudly if the embedded `SUPublicEDKey` doesn't match the secret. Push a tag and watch that step pass before letting CI proceed to notarization.

### F. Communicate to users

Existing users running the pre-rotation build cannot auto-update past the rotation. They will see "no updates available" indefinitely. Communicate this through whatever channel they reach you on:

> "If you're on Pits v0.X.Y or earlier, please download the next release manually from https://github.com/joelisfar/pits/releases — the in-app updater can't bridge the security key rotation."

### G. Backup

The local keychain copy + 1Password copy are your disaster recovery. **Do not lose both.** If you do, future updates can't be signed and you're forced into another rotation.

---

## Common: KEYCHAIN_PASSWORD secret

After v0.2.1 ships, the `KEYCHAIN_PASSWORD` secret is no longer used by the workflow (it's generated inline). Safe to delete:

```sh
gh secret delete KEYCHAIN_PASSWORD --repo joelisfar/pits
```

Don't delete before v0.2.1 ships — v0.2.0's workflow still references it.

---

## What's NOT documented here

- **Apple Developer Program enrollment renewal** ($99/yr). You'll get an email; pay it. If it lapses, your Developer ID cert is suspended, every build's chain validation breaks immediately, and end users see "Pits.app is damaged" on launch. Don't let it lapse.
- **GitHub repo settings** — branch protection, secrets list, required reviews. These live in repo settings, not in scripts. Document separately if you formalize them.
