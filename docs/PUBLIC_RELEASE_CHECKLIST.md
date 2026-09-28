# Public repository and release checklist

This project may be made public as source code once the repository settings and checks below are complete. A public source repository is different from publishing a broadly installable release.

## Before changing repository visibility

- [x] Review every remotely reachable Git commit for secrets and private diagnostics, including historical branches and tags (46 commits before publication preparation; Gitleaks and additional blob/metadata checks).
- [x] Confirm no unintended tracked or untracked files; publication changes are committed before changing visibility.
- [x] Run `python3 scripts/audit.py`, `swift test`, and `scripts/build.sh` from a clean checkout in a non-symlink location.
- [x] Confirm macOS 14/15 CI is green for final preparation source/workflow `c4fa88a`, run `35336196581`; download both CI artifacts and verify ZIP checksums and commit provenance.
- [x] Review `README.md`, `SECURITY.md`, `VALIDATION.md`, `CONTRIBUTING.md`, and this checklist for accurate claims.
- [x] Enable GitHub private vulnerability reporting in the repository security settings; API verified `enabled: true` after publication.
- [x] Set the repository description and topics; state clearly that it is an independent, unofficial utility.
- [x] Issues enabled for maintainer triage; discussions disabled. Bug template prohibits sharing account data.

The repository became public on September 18, 2026. Private vulnerability reporting was enabled immediately afterward; secret scanning and secret push protection are also enabled. Anonymous repository and README access were verified. Source publication does not claim that the pending binary-release acceptance matrix is complete.

## Pairbar 2.0.0 public binary release checklist

This is the single authoritative checklist for public binary release. Source reference: the post-PR #7 `main` baseline at `55b704c9fdbb5fce5ee4dbbe011d9cf182813ada`. The release candidate source declares `2.0.0 (18)`; CI and local ZIPs are ad-hoc development artifacts. Record evidence and exact artifact identifiers before checking a box. Historical source-publication checks above do not satisfy binary gates.

### Source gate

- [ ] On the final release commit: `swift test` (record count/failures), `python3 scripts/audit.py`, `git diff --check`, `bash -n scripts/build.sh`, and `plutil -lint Resources/Info.plist` pass.
- [ ] `bash scripts/build.sh` produces a universal `arm64 x86_64` bundle; fresh ZIP extraction, `unzip -tq`, and strict all-architectures signature verification pass. Record macOS/toolchain and commit.

### Version and provenance gate

- [ ] Final bundle and `BUILD_INFO.txt` agree on semantic version `2.0.0`, unique build number `18` (increment again if a later binary-affecting change requires another RC), exact source commit, `source_state=clean`, architectures, signing state, and ZIP SHA-256.
- [ ] `Pairbar.zip.sha256` verifies the exact final ZIP. Record the checksum in release notes. Do not reuse a checksum from a historical build.

### Live acceptance gate

- [ ] **MUST: account isolation.** In a disposable macOS user or test Mac, sign Current into disposable account A and managed Work profile into different disposable account B. A human confirms distinct identities in both Chat and Code/Codex. Repeat the identity check after Switch, graceful Close, reopen, managed Restart, and Pairbar restart. Current remains A and Work remains B throughout. Record aliases only; never collect session data.
- [ ] **MUST: build update.** Change the installed ChatGPT build in the disposable environment. Verify Pairbar detects it, offers contextual `Approve and open`, leaves an old running build fail-closed where ownership cannot be proved, and never crosses account identity.
- [ ] **SHOULD: shortcuts.** Live focus `⌥⌘1` → Current and `⌥⌘2` → Work, with distinct identities maintained.
- [ ] **SHOULD: concurrency.** If two simultaneous managed profiles will be advertised, verify both live with distinct disposable accounts.
- [ ] **SHOULD: recovery.** Exercise stale pending/recovery live with disposable profiles and provider-wide quiescence.
- [ ] **SHOULD: clean user.** Verify first run and migration as applicable in a new macOS user.
- [ ] **SHOULD: accessibility.** Human VoiceOver speech and rotor review; visual Reduce Motion review.

### Signing and notarization gate

No Developer ID identity or notarization credentials are assumed. Obtain explicit maintainer authorization before signing with Developer ID or submitting anything. The default `scripts/build.sh` signature is ad-hoc and cannot satisfy this gate. Run the universal build, then extract `dist/Pairbar.zip` into a fresh temporary staging directory with `ditto -x -k`; sign the extracted `Pairbar.app`. The build script does not retain a separate app bundle.

- [ ] Developer ID Application identity available and authorized; sign the extracted universal app with `codesign --force --sign <authorized-identity> --options runtime --timestamp Pairbar.app`.
- [ ] `codesign --verify --deep --strict --all-architectures Pairbar.app` passes; inspect `codesign -dv --verbose=4 Pairbar.app` for Developer ID authority, timestamp, and runtime options.
- [ ] Make a **temporary** notarization ZIP from the signed app: `ditto -c -k --keepParent Pairbar.app Pairbar-notary.zip`.
- [ ] Submit `xcrun notarytool submit Pairbar-notary.zip --keychain-profile <authorized-profile> --wait`; record accepted status and submission ID. Credentials remain outside the repo.
- [ ] `xcrun stapler staple Pairbar.app` then `xcrun stapler validate Pairbar.app` pass.
- [ ] `spctl --assess --type execute --verbose=4 Pairbar.app` accepts it under normal Gatekeeper policy.

### Final artifact gate

- [ ] Create the **final** ZIP with `ditto -c -k --keepParent Pairbar.app Pairbar.zip` **after stapling**. The pre-staple notarization ZIP is never the release ZIP.
- [ ] Compute `shasum -a 256 Pairbar.zip`; verify ZIP integrity, extracted app version/build/architectures, signature, staple, and Gatekeeper again. Prepare `Pairbar.zip.sha256` and `BUILD_INFO.txt` for this exact ZIP, recording version, build, clean source commit, architectures, Developer ID signing state, notarization state, and checksum. The development `BUILD_INFO.txt` generated by `scripts/build.sh` must be replaced with truthful final distribution metadata.
- [ ] Clean install the final ZIP on a fresh user or Mac without bypassing Gatekeeper. Check launch and the accepted live account matrix.
- [ ] Publish release notes and annotated tag tied to the verified commit; attach only the verified final ZIP, checksum, and `BUILD_INFO.txt`.

`dist/` and `work/` are ignored local outputs. The build uses a temporary staging directory and replaces one stable `dist/Pairbar.zip`; it does not retain a second app bundle. Preserve any user backups and caches. No gate above is complete merely because an earlier 2.0.0 (17) artifact passed.

## After making the repository public

- [x] Verify anonymous README access and validate the public-facing documentation's internal file links.
- [x] Verify the latest green default-branch CI run is accessible after publication and both artifacts have correct checksums/provenance. Continue monitoring subsequent public runs.
- [ ] Triage public reports without asking reporters to share credentials, cookies, account exports, or unredacted logs.
- [ ] Keep the isolation compatibility gate conservative when the official app changes; Current should stay normal and usable while Second awaits review.
