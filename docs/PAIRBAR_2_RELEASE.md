# Pairbar 2 release gates

This checklist separates implementation validation from a signed, notarized public release. No checklist item is implicitly complete because an earlier Pairbar version passed it. No automated publication or remote push is authorized by this document.

## Recovery and scope

The deliberately modified 1.3.3 base was consolidated in commit `4efdd57718e9a652bcb49d01d6c9b077d7e410f5`, tagged `recovery/pairbar-1.3.3-20260919`, before delegation. Work continues on `codex/pairbar-2`. See [the execution record](PAIRBAR_2_EXECUTION.md) for integration results and file ownership. Preserve the base and all unrelated local changes. Do not use destructive checkout, reset, clean or pull to restore it.

Remote `main` was rechecked on 2026-09-21 and remained `4399fd2090d5e5aa152ec5f0aa0188f5f3e5c5cf`. A source recovery tag does not roll back migrated user data. Do not install an old binary over schema 3 or restore metadata automatically.

The target product is a native menu-bar app with dynamic saved Codex profiles, one unmanaged Current per provider, explicit selected launches and conservative ownership. There is no promise of unlimited concurrent instances. Managed Claude remains unavailable until [the exact-build acceptance gate](CLAUDE_ACCEPTANCE.md) passes for both Chat and Code and resolves Cowork risks. A release with Claude still blocked must say so plainly and must not be labeled completed Claude support.

## Automated source and artifact gates

Run these checks from the final integrated source with the integrator as the sole shared build owner. The commands below do not launch provider accounts:

```sh
git status --short
git diff --check
python3 scripts/audit.py
bash -n scripts/build.sh
plutil -lint Resources/Info.plist
swift test
scripts/build.sh
(cd dist && shasum -a 256 -c Pairbar.zip.sha256)
```

Record the commit or a precise dirty-tree statement, compiler/macOS versions, check results, test count and artifact checksum in the execution record. Never present tests run against a previous revision as tests of the release revision. If an isolated module-cache override is needed, use an ignored workspace directory; do not inspect or repurpose another process's environment.

- [x] Source-policy audit covers all shipped Swift/C sources and relevant tools. No network, telemetry, updater, credential API, foreign argv/environment inspection, subprocess lifecycle control, force kill or provider-app mutation is introduced.
- [x] Dynamic Current can never receive private storage, an ownership receipt, close/restart/reset controls or automatic adoption. This is enforced in the model/controller and covered by behavior tests.
- [x] Tests cover duplicate process/path identities, PID reuse, unknown observations, late callbacks, changed or replaced bundles, pending persistence and lifecycle operation serialization.
- [x] Synthetic migration tests cover missing/old schema fields, Current/Second metadata, corrupt records, future versions, interrupted writes and repeated migration. Legacy profile contents are never read.
- [ ] Archive tests cover every journal phase, stale/corrupt journals, durability failures and symlink/hardlink/path substitution; archived provider directories remain opaque.
- [x] Export tests prove exclusion of paths, receipts, PIDs, fingerprints, journals and provider data. Diagnostics use sanitized fields and errors.
- [x] Performance acceptance exercises 1,000 stored profiles and 10,000 resolved profiles with no artificial profile cap. Native UI responsiveness still belongs to the safe visual pass.
- [x] Preview uses in-memory rows and bypasses controller/store/runtime/shortcut creation. The native preview opened with account/startup actions disabled; Profiles and Settings rendered with accessibility labels.
- [x] Source, bundle and zip version/branding match; historical executable/bundle identifiers and storage root remain compatible.
- [ ] Final macOS CI matrix passes on the exact release source. Prior CI run links remain historical only.

The build script atomically produces `dist/Pairbar.zip` and `dist/Pairbar.zip.sha256` and signs only its own temporary `Pairbar.app`. With the default ad-hoc signing identity it is a development artifact, not a notarized distribution. A Developer ID identity can be supplied explicitly, but the script still does not submit, staple or claim notarization. Rebuilding replaces that workspace ZIP only after the new archive passes an integrity check; copy or rename a needed prior artifact before rebuilding, without touching provider applications.

Before calling any Pairbar 2 build a release candidate, set `CFBundleShortVersionString` and `CFBundleVersion` deliberately and verify that the UI, archive provenance and release notes use the same version. The current integrated source declares 2.0.0 (build 17); this is candidate metadata, not evidence that acceptance, signing or notarization has passed.

## Native acceptance in a safe environment

The hosting Second Account must remain running throughout development. No acceptance step in this session may close or restart it. Do not run the legacy live smoke command or a recovery/reset operation against production storage. Its previous success does not validate dynamic profiles.

Use a separate macOS user/machine for the complete matrix. A test from Current Account still needs newly created disposable profiles and explicit confirmation of which process identities it may control. Use the product's own receipts and allowed process identity metadata; never inspect credentials, profile contents, foreign argv or environments.

| Area | Required result |
| --- | --- |
| Current + two disposable Codex profiles | Separate intended signed-in sessions, durable storage, correct focus and repeated open requests without duplicate instances. Human verifies identities in provider UI; evidence stores aliases only. |
| Hosting-process protection | No test targets the development Second Account. Tests requiring all provider instances stopped run in a different macOS user or machine. |
| Current reopening | With managed profiles running and Current closed manually, normal opening yields the true default account rather than a managed instance. Pairbar never owns that process. |
| Lifecycle | Only an exact owned disposable process receives graceful quit/restart; decline, timeout, changed identity or unreadable identity cancels continuation and never forces termination. |
| Recovery | Unknown ownership blocks relevant provider operations. Recovery never adopts a process by PID/name alone or clears uncertainty while a possible orphan remains. |
| Migration | Copy only synthetic metadata fixtures into a scratch root. For real upgrade acceptance, use the separate user's own disposable data and verify legacy paths are retained without decoding contents. |
| Archivado/reset | When every instance of the tested provider is stopped, reset renames its opaque old directory and uses a fresh generation. Never delete original provider data. |
| Startup | “Start Pairbar” and “Open selected profiles at login” are independent. Profile opening starts disabled, respects exact selection and does not run on ordinary launch or wake. |
| Memory | Warnings are visible and critical pressure pauses pending batch launches; no automatic process close occurs. Use simulated pressure for deterministic tests. |
| Popover | Favorites, search, provider filters, creation, rename, ordering and management remain inside the native popover; no permanent window or mandatory Dock icon. |
| Accessibility | Keyboard-only navigation, VoiceOver labels/actions, focus retention, long labels and contrast work across accounts and management screens. |
| Languages/shortcuts | Spanish and English cover onboarding, states, errors and confirmations. Configurable shortcuts report conflicts and preserve the previous valid binding. |
| Claude | Current is normal and unmanaged. Managed profiles remain unavailable until all required evidence exists; a local fingerprint approval cannot lift that gate. |

Record each result as passed, failed or not run, with the tested build and date. “Prepared” is not “passed.” No account screenshots, logs, cookies, credentials or user identifiers belong in a public issue or release artifact.

## Developer ID and notarization gate

These steps are performed by the release owner using their existing authorized signing setup. Pairbar code must not discover, read, export or print signing credentials or Keychain contents. If the setup is unavailable, stop at the verified development ZIP and state that public signing/notarization is pending.

1. Freeze the release commit and use a clean non-symlink checkout. Preserve the working tree and recovery point; do not clean it destructively to obtain the checkout.
2. Build Pairbar with the intended Developer ID identity through the build script's documented signing option. Verify strict signature and hardened-runtime settings on **Pairbar.app only**. Never sign, replace or alter ChatGPT.app or Claude.app.
3. Submit the intended artifact through Apple's supported notarization workflow using the release owner's existing authorization. Build/release tooling may communicate with Apple; this does not add networking to the Pairbar app.
4. Confirm notarization success, staple the ticket to Pairbar.app, validate the staple and repackage the final ZIP. A ZIP made before stapling is not the final artifact.
5. Extract the final ZIP to a new scratch directory and verify its signature, staple and Gatekeeper assessment. Install and open it on another macOS user/machine without disabling Gatekeeper or removing quarantine as a workaround.
6. Compute SHA-256 on the final ZIP. Record source commit, version, architecture support, toolchain, signing/notarization result and exact artifact checksum. Keep private signing setup and submission credentials out of provenance.
7. Review the final release notes against observed behavior and open gates. Only then propose the concrete tagged release and upload. No task scheduler or script publishes automatically.

Follow [Apple's notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow) for the release toolchain. Do not call an ad-hoc archive or CI artifact a notarized release.

## Claims, attribution and final verdict

- [x] README, security policy, user guide, validation record and implementation status describe the dynamic architecture and retained restrictions accurately.
- [x] No documentation claims full credential/session isolation from static markers alone; Claude Chat/Code/Cowork status is explicit.
- [x] Switcher design references are attributed as references. The implementation is recorded as independent; no reused third-party code was identified.
- [x] No private paths, test identities, provider data, debug exports or generated live-profile directories enter Git or the verified development archive.
- [x] Adversarial review lists concrete issues and a final verdict against the integrated revision. Addressed findings were rechecked; absent real acceptance and notarization still block a public binary.

Current adversarial verdict: **BLOCK** for public binary release. The audited worktree passes the source-policy audit, 131 synthetic tests, Pairbar 2.0.0 (17) development build, ZIP integrity/checksum and strict all-architectures verification of Pairbar's ad-hoc signed bundle. It also fixes and tests an ownership race after asynchronous inspection, critical-memory focus of existing processes, unsupported residual Claude login selection, and continuation past an independent provider failure. The inert native preview passed a limited visual/accessibility-tree check. Safe-environment signed-in lifecycle, full keyboard/VoiceOver/contrast acceptance, checked-in product screenshots, exact-revision macOS CI, injected archive durability-failure coverage, Developer ID signing, notarization, and clean-machine acceptance remain pending. The locally installed ChatGPT and Claude bundles currently fail strict signature validation and are blocked. Managed Claude is separately blocked by its signed-in Chat, Code, and Cowork evidence gate.

Truthful development-delivery wording: “Dynamic profile implementation and 131 local synthetic checks are available in this branch as an ad-hoc development artifact. Managed Claude remains blocked pending signed-in isolation acceptance. Final live acceptance, Developer ID signing, notarization, and public binary release are not claimed.”
