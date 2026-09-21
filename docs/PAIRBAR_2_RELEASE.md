# Pairbar release gates

This checklist separates implementation validation from a signed, notarized public release. No checklist item is implicitly complete because an earlier Pairbar version passed it. No automated publication or remote push is authorized by this document.

## Recovery and scope

The deliberately modified 1.3.3 base was consolidated in commit `4efdd57718e9a652bcb49d01d6c9b077d7e410f5`, tagged `recovery/pairbar-1.3.3-20260919`, before delegation. PR #1 merged the update into `main`; PR #2 merged the release-readiness work. See [the execution record](PAIRBAR_2_EXECUTION.md) for integration results. Preserve the base and all unrelated local changes. Do not use destructive checkout, reset, clean or pull to restore it.

The final recorded merge commit is `0bf3fbcb083e4a6454db2227e78e28522c566d89` from PR #2. Its macOS 14/15 workflow run `35585485542` passed both jobs. A source recovery tag does not roll back migrated user data. Do not install an old binary over schema 3 or restore metadata automatically.

Installed acceptance follow-up code commit `0dcaeff6e98fb7009319363c5e5baa3c6f406273` fixes immediate English/Spanish refresh of errors and login-item status. Its branch PR and macOS 14/15 CI must pass before this follow-up is integrated.

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
- [x] Archive tests cover journal phases, stale/corrupt journals, five injected durability boundaries, symlink/hardlink/path substitution, and preservation of opaque archived contents.
- [x] Export tests prove exclusion of paths, receipts, PIDs, fingerprints, journals and provider data. Diagnostics use sanitized fields and errors.
- [x] Performance acceptance exercises 1,000 stored profiles and 10,000 resolved profiles with no artificial profile cap. Native UI responsiveness still belongs to the safe visual pass.
- [x] Preview uses in-memory rows and bypasses controller/store/runtime/shortcut creation. Profiles, Settings, and Help rendered in English and Spanish with account/startup actions disabled, accessible labels, working Command-F search, and checked-in synthetic screenshots.
- [x] Source, bundle and zip version/branding match; historical executable/bundle identifiers and storage root remain compatible.
- [x] PR #1 and PR #2 merged cleanly. The macOS 14/15 matrix passed for implementation commit `91db9471a05ada20e58c5a1b4f6e9c181afad273`, release-readiness commit `d34d82728cf0dc0b65b438c8975c262e5d0d74de`, and final recorded merge commit `0bf3fbcb083e4a6454db2227e78e28522c566d89`; its post-merge run is `35585485542`.
- [x] The build script produces one universal `x86_64 arm64` archive by default, and CI rejects an archive missing either architecture.

The build script atomically produces `dist/Pairbar.zip` and `dist/Pairbar.zip.sha256` and signs only its own temporary `Pairbar.app`. With the default ad-hoc signing identity it is a development artifact, not a notarized distribution. A Developer ID identity can be supplied explicitly, but the script still does not submit, staple or claim notarization. Rebuilding replaces that workspace ZIP only after the new archive passes an integrity check; copy or rename a needed prior artifact before rebuilding, without touching provider applications.

Before calling any Pairbar build a release candidate, set `CFBundleShortVersionString` and `CFBundleVersion` deliberately and verify that the UI, archive provenance and release notes use the same version. The current integrated source declares 2.0.0 (build 17); this is candidate metadata, not evidence that acceptance, signing or notarization has passed.

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

### Installed acceptance evidence on the development Mac

The 2026-09-21 installed-app pass completed the parts that did not require stopping the task-hosting `Work` profile:

- the real legacy root migrated to schema 3 while retaining opaque `Profiles/b` storage and a usable `Work` row;
- two disposable profiles were saved without opening automatically, and their Electron and `CODEX_HOME` paths were distinct;
- `Acceptance A` reached receipt-verified ownership;
- Pairbar restart plus Pairbar-only uninstall/reinstall preserved Current, `Work`, the disposable records, preferences, and recovery state;
- Launch at Login registered and unregistered through `SMAppService`; the separate per-profile login selection remained opt-in;
- Full Keyboard Access traversed the popover, VoiceOver exposed labeled states/actions, and light, dark, increased-contrast, and reduced-transparency rendering was inspected; all system settings were restored;
- English/Spanish changes refreshed both error text and login status after the localization correction.

`Acceptance B` visibly opened but left a durable pending marker without a verified receipt. Pairbar correctly blocked ownership-dependent actions and refused safe recovery while provider processes were still present. Because `Work` hosts this task, provider-wide quiescence could not be established safely. Signed-in identity separation, owned close/restart, Open Selected, archive/reset, and completed recovery therefore remain blocked for a separate macOS user or test Mac. VoiceOver speech/rotor quality also still needs human observation. These are acceptance limits, not implementation failures to bypass.

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

Current adversarial verdict: **BLOCK** for public binary release. The audited worktree passes the source-policy audit, 133 synthetic tests, universal Pairbar 2.0.0 (17) development build, ZIP integrity/checksum, and strict all-architectures verification of Pairbar's ad-hoc signed bundle. Injected failures cover five archive durability boundaries. The installed ChatGPT and Claude bundles pass strict signing, Gatekeeper, and Pairbar's read-only checks outside the task sandbox. The real installed Pairbar pass completed migration, Pairbar restart/reinstall persistence, login-item registration, keyboard traversal, accessibility-tree inspection, appearance modes, and language refresh. Signed-in identity separation, owned lifecycle, an actual login event, completed recovery, archive/reset, human VoiceOver acceptance, Developer ID signing, notarization, stapling, and clean-user acceptance remain pending. Managed Claude is separately blocked by its signed-in Chat, Code, and Cowork evidence gate.

Truthful development-delivery wording: “Pairbar's dynamic profile update and 133 local synthetic checks are available as a universal ad-hoc development artifact. Managed Claude remains blocked pending signed-in isolation acceptance. Remaining live lifecycle acceptance, Developer ID signing, notarization, and public binary release are not claimed.”
