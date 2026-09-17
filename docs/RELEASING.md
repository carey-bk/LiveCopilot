# Packaging and publishing LiveCopilot

The public source repository is `carey-bk/LiveCopilot`. Preserve the upstream Stealth history and MIT license. Release assets belong in GitHub Releases; `dist/` is ignored by Git. No runtime data or credentials are copied into the app or disk image.

## Developer ID release (1.4.1 and later)

The maintainer needs an installed **Developer ID Application** certificate and its private key. Keep the private key in Keychain. `setup-signing.sh` now only lists identities; it no longer creates or trusts a self-signed root or changes key ACLs. Unsigned/ad-hoc Debug builds remain separate from distribution builds.

Apple references: [notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution), [custom workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

### One-time notarization authentication

Create an App-specific password at `account.apple.com`, then run this in your own local terminal, replacing the email and team. Omit `--password` so the password is entered at a hidden prompt and never becomes shell history or a process argument:

```bash
xcrun notarytool store-credentials "LiveCopilot-Notary" \
  --apple-id "YOUR_APPLE_ACCOUNT_EMAIL" --team-id "YOUR_TEAM_ID"
```

Do not commit or print passwords, signing private keys, `.p12` exports, or App Store Connect `.p8` keys. A notarytool Keychain profile is distinct from the runtime AI service credentials.

### Build, sign, and notarize the app

Finish checks and commit the release sources. Use a clean checkout (or a clean detached worktree for packaging when the main workspace has private, untracked files).

```bash
./StealthApp/scripts/build.sh
python3 StealthApp/scripts/sign-distribution.py \
  StealthApp/build/Build/Products/Release/LiveCopilot.app \
  --output /tmp/LiveCopilot-Release.app --identity "YOUR_DEVELOPER_ID_CERTIFICATE_SHA1"
ditto -c -k --keepParent /tmp/LiveCopilot-Release.app /tmp/LiveCopilot-Release.zip
xcrun notarytool submit /tmp/LiveCopilot-Release.zip \
  --keychain-profile LiveCopilot-Notary --output-format json
```

Record the returned submission ID. Use `notarytool info ID --keychain-profile LiveCopilot-Notary` or a bounded `notarytool wait ID --keychain-profile LiveCopilot-Notary --timeout 60s`; do not resubmit a pending upload. Retrieve the log with `notarytool log ID --keychain-profile LiveCopilot-Notary LOG.json`. Continue only after **Accepted** with no unresolved issues.

```bash
xcrun stapler staple /tmp/LiveCopilot-Release.app
xcrun stapler validate /tmp/LiveCopilot-Release.app
spctl --assess --type execute --verbose=2 /tmp/LiveCopilot-Release.app
```

The signing script copies to a new staging path, assigns a UTC build, and signs each dylib, framework, inference executable, then the application, from the inside out. Every arm64/x86_64 slice must have the same Developer ID team, secure timestamp and hardened runtime. No `get-task-allow`, disabled library validation, JIT or unsigned-memory exception is introduced. It never exports the signing key or installs the app. Run local model smoke checks using this **signed** inference executable to check library loading under the hardened runtime.

### Package and notarize the DMG

Preserve that exact stapled app; do not re-sign it after acceptance.

```bash
./StealthApp/scripts/package-dmg.sh \
  --app /tmp/LiveCopilot-Release.app --app-source-ref COMMIT \
  --sign-identity "YOUR_DEVELOPER_ID_CERTIFICATE_SHA1" --output /tmp/release
xcrun notarytool submit /tmp/release/LiveCopilot-VERSION-macOS-universal.dmg \
  --keychain-profile LiveCopilot-Notary --output-format json
```

Wait for the DMG's own **Accepted** result and inspect its log. Then:

```bash
xcrun stapler staple /tmp/release/LiveCopilot-VERSION-macOS-universal.dmg
./StealthApp/scripts/finalize-release.sh /tmp/release/LiveCopilot-VERSION-macOS-universal.dmg
```

The DMG contains the stapled app, an Applications shortcut, bilingual instructions, MIT license and manifest. Packaging records the caller-supplied app source commit, release commit, executable hash, version/build, architectures and signing team; it rejects changed app inputs. This is provenance, not a reproducible-build attestation. Finalization checks signature, ticket, Gatekeeper and disk image integrity, then regenerates checksums **after stapling**, which changes DMG bytes.

### Validate and publish

- Mount the final DMG read-only without launching its production-ID app. Check both the mounted and copied-out app with `codesign`, `stapler` and `spctl`; compare the executable hash with the signed input.
- Review source/history for private files. Publish the matching source/tag and create a draft GitHub Release. Upload the final DMG, manifest and checksums; download and verify all uploaded files before publishing.
- Retain older release assets. Versions through 1.4.0 are historical ad-hoc builds; do not relabel or silently replace them as notarized.
- Install only the final validated bundle at the canonical location after tests. Do not launch production-ID staging copies afterward.

## Local updates and stale permissions (V1.3.0)

For updates on the development Mac, finish validation and sign **one** staging app, quit the installed application, then use:

```bash
python3 StealthApp/scripts/install-local.py /absolute/path/to/validated/LiveCopilot.app --dry-run
python3 StealthApp/scripts/install-local.py /absolute/path/to/validated/LiveCopilot.app
```

The target is always `~/Applications/LiveCopilot.app`. The installer verifies the bundle identity/signature, archives each old `LiveCopilot.app.previous.*` and the installed version to verified `.tar.gz` files under `~/Library/Application Support/LiveCopilot/Backups/Applications`, unregisters those loose backups, and registers the canonical app. The backups preserve file bytes and symlinks; restore a selected archive outside Applications before installing it. Never leave a renamed, same-ID application bundle beside the live app again.

If the designated requirement changes, it resets only `ScreenCapture` for `com.livecopilot.app`, once after installation. `--repair-permissions` forces this repair for an already stale grant. It never changes Keychain ACLs, resets other applications, edits TCC databases or grants permission itself. A same-signature reinstall does not reset grants. The receipt `latest-install.json` records version/build, executable SHA-256 and archive paths, without credentials.

After installation, the user requests access in General → System audio permission and allows the canonical LiveCopilot in macOS Privacy Settings, following any quit/reopen request. In 1.3.1, startup and service switching never prompt for Keychain access. The transition from an ad-hoc build to Developer ID can show a saved credential as needing authorization; the user explicitly clicks the authorization button to access/import it. Keys saved by the app persist in the app-managed Keychain namespace. Subsequent releases preserve the Developer ID team and bundle ID. Stable signing supports identity continuity, but does not bypass Keychain or TCC policy; renewed user authorization may still be required after migration or system policy changes.


### Keep development identity separate

Debug uses `com.livecopilot.development`; Release uses `com.livecopilot.app`. The prior shared bundle ID let a post-install Xcode test run register its Debug signature as the apparent production application, so a user could enable the right-looking permission switch for the wrong binary. Confirm the built Debug plist retains its distinct ID. Run validation **before** the final local install, then register the canonical app last. The installer unregisters known same-production-ID copies under build/dist/staging without deleting them; it leaves the separate development app alone. Do not run production-ID preview/test bundles after final installation.

## Bilingual website

`site/` contains Chinese and English content and a shared template. Build with
`python3 StealthApp/scripts/build-site.py`; serve `_site/` to check both desktop
and mobile layouts, language links and all three example buttons.

Enable GitHub Pages with GitHub Actions as its build source. The pinned
`.github/workflows/pages.yml` builds and deploys `_site/` from `main`; it can also
be dispatched manually. Publish the matching release assets before announcing
the download link. Verify `/LiveCopilot/` and `/LiveCopilot/en/` after deployment.
Only public product content belongs in `site/`; never include user recordings,
keys, local data, or screenshots of private conversations.
