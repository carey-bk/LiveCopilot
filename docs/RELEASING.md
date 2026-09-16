# Packaging and publishing LiveCopilot

The public source repository is `carey-bk/LiveCopilot`. Preserve the upstream Stealth history and MIT license. Release assets belong in GitHub Releases; `dist/` is ignored by Git. No runtime data or credentials are copied into the app or disk image.

## Build a new DMG

Install full Xcode and XcodeGen, complete the relevant tests, then commit the release source and documentation. From a clean checkout:

```bash
./StealthApp/scripts/package-dmg.sh
```

The script builds Release, copies the bundle to a temporary staging directory, assigns a UTC build number, ad-hoc signs only that copy, verifies its signature and both architectures, and creates a compressed read-only DMG. It never installs over the running app, reads Keychain, or calls model APIs. An existing output DMG is never overwritten.

The image contains `LiveCopilot.app`, an `/Applications` symlink, bilingual installation instructions, the MIT license and `ReleaseInfo.txt`. The `dist/` directory also contains a release-information file and `SHA256SUMS.txt`.

## Preserve an already validated application

For the first public 1.1.0 release, reuse the exact previously validated application so its signature and build identifier stay unchanged:

```bash
./StealthApp/scripts/package-dmg.sh \
  --app "$HOME/Applications/LiveCopilot.app" \
  --app-source-ref 0c263bf
```

The script rejects this mode if source, resources or project settings differ from the supplied application commit. `--app-source-ref` identifies the caller's validated binary; this is a provenance record, not a reproducible-build attestation. The manifest records both that application commit and the release checkout commit, plus the executable SHA-256, architecture, minimum OS, version and build. Packaging/documentation-only changes are permitted.

## Validate before publishing

- Run `hdiutil verify` and mount the image read-only without launching the app.
- Confirm the app, Applications link, installation instructions, license and manifest are present. Verify the mounted app with `codesign --verify --deep --strict` and compare its executable SHA-256 with the input application.
- Copy the app from the image into a temporary installation directory, verify the copied app, then detach the image. Keep the user's installed app and private data untouched.
- Review the source and reachable Git history for credentials/private files before pushing. Publish a version tag such as `v1.1.0` on the intended release commit.
- Create a draft GitHub Release, upload the DMG, manifest and checksums, download the assets to a fresh directory and verify them. Publish the draft after verification. GitHub provides source archives for the same tag.

## Signing boundary

Version 1.3.2 is an ad-hoc signed community build, not Developer ID signed or Apple notarized. Passing `codesign --verify` confirms bundle integrity; it does not make the app trusted by Gatekeeper. Installation guidance links to [Apple's per-app opening instructions](https://support.apple.com/en-us/102445), without recommending a global Gatekeeper change.

A future notarized release needs the maintainer's Developer ID Application identity, a suitable hardened-runtime build and an Apple notarization submission. No signing private key, account password or API key belongs in Git or release assets.

## Local updates and stale permissions (V1.3.0)

For updates on the development Mac, finish validation and sign **one** staging app, quit the installed application, then use:

```bash
python3 StealthApp/scripts/install-local.py /absolute/path/to/validated/LiveCopilot.app --dry-run
python3 StealthApp/scripts/install-local.py /absolute/path/to/validated/LiveCopilot.app
```

The target is always `~/Applications/LiveCopilot.app`. The installer verifies the bundle identity/signature, archives each old `LiveCopilot.app.previous.*` and the installed version to verified `.tar.gz` files under `~/Library/Application Support/LiveCopilot/Backups/Applications`, unregisters those loose backups, and registers the canonical app. The backups preserve file bytes and symlinks; restore a selected archive outside Applications before installing it. Never leave a renamed, same-ID application bundle beside the live app again.

If the designated requirement changes, it resets only `ScreenCapture` for `com.livecopilot.app`, once after installation. `--repair-permissions` forces this repair for an already stale grant. It never changes Keychain ACLs, resets other applications, edits TCC databases or grants permission itself. A same-signature reinstall does not reset grants. The receipt `latest-install.json` records version/build, executable SHA-256 and archive paths, without credentials.

After installation, the user requests access in General → System audio permission and allows the canonical LiveCopilot in macOS Privacy Settings, following any quit/reopen request. In 1.3.1, startup and service switching never prompt for Keychain access. A changed ad-hoc signature can show a saved credential as needing authorization; the user explicitly clicks the authorization button to access/import it. Keys saved by the app persist in the app-managed Keychain namespace. Stable Developer ID signing is the long-term solution for upgrade identity continuity; this installer does not claim to solve that by weakening signature requirements.


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
