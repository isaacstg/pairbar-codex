# Implementation Status

Last reconciled against the Pairbar 1.3.3 source revision.

## 1.3.3 welcome guide

Implemented: a welcome page shown once independently of completed account setup, an always-visible continuation button, contextual instructions for new versus already configured users, and Help → Quick Start replay. Completion stores only a boolean in the switcher's own preferences. It does not change approval, setup, profile data, or login-item state; preview mode bypasses both reading and writing that preference.

Validated: release compilation, source-policy audit, diff checks, no secrets in the changes, and fresh ZIP extraction with strict signature verification. The 47 core tests were already passing; shared core code is unchanged in this UI revision. `dist/Pairbar-1.3.3.zip` is the version-specific local package; `dist/Pairbar.zip` contains the same build. Native visual acceptance remains pending: the existing controller correctly rejected a second controller on its locked data, and the computer-use tool did not approve opening the separate preview application. The user's running controller was preserved.

Installation and GitHub publication remain pending under the previously recorded session restrictions. The local ad-hoc build is not a notarized release.

## 1.3.2 Pairbar branding and stable actions

Implemented: aligned Open/Switch columns, Second's More menu beside its shortcut, native Pairbar labels/metadata, `Pairbar.app` and `Pairbar.zip`, matching CI artifact names, updated repository links, and a corrected gray/blue interface illustration.

Locally verified: source audit, 47 unit tests, release compilation, unchanged identity/storage invariants, fresh ZIP extraction and strict signature verification. The unchanged icon was reused from our verified preceding bundle after iconutil failed under the restricted shell. The 1.3.1 alignment was observed in the installed native UI before the branding change.

Requires validation: 1.3.2 CI, installation/native branding on the Mac, and renamed-app startup-at-login acceptance. Installation is pending because current session permissions do not permit replacing `/Applications` bundles. Existing account data and the official ChatGPT bundle were not modified.

Publication of this revision is also pending: the connected GitHub write tool required approval unavailable under the current session policy. The source changes remain local and uncommitted; no 1.3.2 CI result is claimed. `dist/Pairbar.zip` passed final fresh extraction and strict verification in an unsynchronized temporary directory. Build information and its checksum are available beside the local ZIP.

## 1.3 menu-bar revision

Implemented and locally validated:

- Native Accounts/Settings/Help popover; no detached settings or diagnostic windows.
- Two account cards, Open Both, and a verified-Second-only More menu.
- Automatic app checking with plain-language setup/update confirmation.
- Label-only saves, inline errors, close-after-switch callbacks, recovery guidance, and grouped diagnostics/data/uninstall tools.
- Version 1.3.0 (13), native keyboard back navigation, accessibility labels, and compact/long-label layouts.
- Source audit, 47 passing unit tests, native scratch preview, release build, and extracted-bundle signature verification.

Native preview exercised first run, ready state, saved/invalid names, Help details, keyboard back, Escape dismissal/reopen, long labels, simulated pending recovery, and a simulated changed fingerprint. Preview never launched an account or changed login items. The original 1.2 daily workflow was reported by the user as working perfectly; the detailed signed-in release matrix is still distinct from that report.

The 1.3 executable source commit `db3fc8b8d9a5a2317919634ffd0778997b0a74b8` passed every CI step on macOS 14 and 15 in run `35255458165`, including artifact upload.

The installed switcher was backed up and upgraded to 1.3 with strict signature verification, retaining labels/setup and preserving the original Current process. Live Second opening, both Running cards, three Open Both activations without duplicate processes, and cancellation of the native Restart confirmation were observed. Neither live account was terminated. Physical global-keyboard dispatch and startup behavior remain unverified by this automated UI session.

See `docs/UX_IMPROVEMENT_PLAN.md` for the implemented scope and prioritized proposals.

## Product invariant

Current Account is the user's normal official ChatGPT/Codex profile. It is never switcher-owned or destructively controlled. Second Account is the sole isolated profile and may be controlled only with a verified receipt.

## Implemented and CI-validated

- Current/Second typed account state resolver and menu capability policy.
- Current candidate selection that excludes only a positively verified Second PID and fails closed on ambiguity or uncertain Second recovery.
- Secondary-only launch environment, storage, ownership receipts, graceful termination, restart, stale-receipt handling, pending-launch recovery, and conservative reset/archive.
- Metadata-only migration: legacy A receipts and pending markers are discarded; legacy A storage remains untouched; valid B metadata remains usable.
- Backward-compatible settings migration and future-schema downgrade protection.
- Separate official-app identity checks for Current and strict isolation compatibility/fingerprint checks for Second.
- Update-race quarantine, private-store path/permission protections, diagnostics, safe uninstall text, and opt-in startup at login.
- Current/Second UX, fixed global shortcuts, source-policy audit, expanded unit tests, macOS 14/15 CI, release build, and strict bundle verification.

GitHub Actions runs #42 and #43 passed every configured job on both supported runner versions. Run #43 also retained the ZIP, SHA-256, and build-provenance artifacts for each runner. This validates compilation and static checks; it does not validate real accounts.

## Locally validated, but not a signed-in acceptance test

- Source-policy audit and all 41 unit tests passed.
- Official `/Applications/ChatGPT.app` passed read-only identity and isolation compatibility inspection.
- Release archive built, extracted into a fresh directory, and passed strict app-bundle verification.
- The live smoke test passed with one preserved normal Current process and one disposable Second process. It verified separate storage, simultaneous processes, graceful Second termination, and Current preservation.

The disposable smoke profile remains in an ignored local `work/` directory. It was never signed in and was not read by the test.

## Implemented but requires live validation

- Signed-in dual-account persistence and OAuth behavior.
- Physical hotkeys, rapid overlapping Open Both stress, graceful Second quit/restart, and switcher restart with both processes alive.
- Interrupted launch, stale receipt, changed fingerprint, moved app, reset/archive, login-item, uninstall/reinstall, and legacy-data upgrade acceptance.

## Deliberately deferred

- More than one isolated extra account.
- Account identity/email scraping, token copying, Keychain or browser-store access.
- Custom shortcuts, updater, browser automation, and project quick actions.

## Next validation sequence

1. Preserve the existing normal Current instance; the disposable one-Current/one-Second smoke test has already passed.
2. Validate the real two-account workflow without relaxing any ownership invariant.
3. Record only performed evidence in `VALIDATION.md`.
4. Tag/release only after that acceptance work; notarize only if distributing outside this Mac.
