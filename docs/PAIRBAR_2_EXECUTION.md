# Pairbar update execution record

## Recovery point

The approved 1.3.3 working tree was consolidated at `4efdd57718e9a652bcb49d01d6c9b077d7e410f5`, tagged `recovery/pairbar-1.3.3-20260919`, on `codex/pairbar-2`. PR #1 merged the verified update commit `91db9471a05ada20e58c5a1b4f6e9c181afad273` into `main` as `520f85db55fe403e910331a5e1f1760f0efd48eb`. PR #2 merged release-readiness commit `d34d82728cf0dc0b65b438c8975c262e5d0d74de` as `0bf3fbcb083e4a6454db2227e78e28522c566d89`; post-merge macOS 14/15 run `35585485542` passed.

Installed acceptance follow-up code commit `0dcaeff6e98fb7009319363c5e5baa3c6f406273` refreshes localized errors and login-item status immediately after a language change. Its PR/CI integration state is recorded separately from the earlier merged baseline.

Before delegation: source audit, whitespace, shell/plist validation, 47 unit tests and release packaging passed. Module caches were redirected into ignored `work/`; iconutil required building outside the restricted sandbox. Only Pairbar's staging bundle was signed.

## Exclusive ownership during parallel implementation

| Owner | Exclusive writable scope |
| --- | --- |
| Architecture agent | `Tests/SwitcherCoreTests/DynamicStoreTests.swift` and `Tests/SwitcherCoreTests/DynamicStateTests.swift` |
| UI agent | `Sources/DualAccountSwitcher/UI/` and `Sources/DualAccountSwitcher/HotKeys.swift` |
| Claude agent | Initial implementation of `Sources/SwitcherCore/Providers/Claude/`; ownership returned to the integrator after the agent stopped |
| Review/release agent | Read-only adversarial review, then `docs/CLAUDE_ACCEPTANCE.md` and `docs/PAIRBAR_2_RELEASE.md` |
| Product-documentation agent | `README.md`, `SECURITY.md`, `VALIDATION.md`, `docs/USER_GUIDE.md`, `docs/CASE_STUDY.md`, `docs/IMPLEMENTATION_STATUS.md`, and this execution record |
| Integrator | All remaining source, runtime/controller/application integration, ProcessIdentity, Package.swift, integration tests, audit/build fixes, Git, and final validation |

Agents must not revert, overwrite or format another owner's files. No agent may operate live accounts, inspect credential/profile contents or another process's arguments/environment, alter official app bundles, commit, switch branches, or run the full shared build. API changes across boundaries are communicated before editing. The integrator alone runs shared builds/tests and Git operations.

## Integration contracts

- Keep existing legacy core types for metadata decoding and old tests; introduce prefixed dynamic types in `Dynamic/`. No artificial profile-count limit. Keep 64 KiB per metadata record.
- Architecture publishes its concrete public API early. Required operations: lock/open and metadata-only migration; load/save provider and app preferences; list/create/update profiles; durable per-profile receipt and pending state; generate validated profile paths; journaled archive/reset; typed process observations and pure provider state resolution. Store construction must never access production roots implicitly in tests.
- UI exposes a MainActor observable `PairbarPanelModel` with rows, provider settings/status, error/progress, language, memory pressure, login status, welcome state and callback actions. UI models stay independent of lifecycle implementations. The integrator binds callbacks; the UI never directly controls processes/storage/login items.
- Claude exposes a read-only official identity/compatibility inspection API, explicit unvalidated capability status and a launch recipe only if policy permits it. Static markers or local approval cannot claim runtime separation. No production managed-Claude launch until signed-in Chat and Code acceptance exists.
- All process control uses AppKit. Current has no ownership receipt, lifecycle controls or private storage. Stopped Current must never reuse a managed process. Unknown observations fail closed.
- The session-hosting Second Account must never be closed, restarted, reset or subjected to destructive recovery. Real acceptance uses another macOS user/machine or explicitly new disposable profiles; automated tests use fakes.

## Integrated architecture status

The working source now contains the dynamic provider/profile model, schema-3 metadata store, pure state resolver, provider runtime abstraction, Pairbar controller, native scalable panel, configurable hotkeys, and read-only Claude compatibility inspection. The integrator retains responsibility for reconciling their APIs, correcting adversarial findings, connecting the application entry point, and running the only shared test/build sequence.

The implementation keeps these decision-complete boundaries:

- no artificial limit on saved profile records and a 64 KiB bound on each metadata record;
- no automatic “open all” path; manual multi-select and login selections enumerate concrete targets;
- one receipt-free, ordinary Current account per provider;
- managed lifecycle control only after live receipt ownership and official identity are both verified;
- archive journals and provider-wide quiescence for archive/reset/recovery;
- opaque Current + Second migration with the historical Second directory retained;
- normal Claude Current only, with managed Claude construction and launch blocked;
- preview fixtures in memory with live actions disabled;
- redacted diagnostics and non-sensitive configuration export.

## Integrated validation result

The integrator completed the shared non-live validation and follow-up audit on the joined source:

- all 133 Swift tests passed with repository-local module caches, including injected archive durability failures, Claude lifecycle/archive denial, suspended-inspection ownership revalidation, independent batch failures, critical-memory focus behavior, and language-change refresh behavior;
- `scripts/audit.py`, `git diff --check`, `plutil`, and `bash -n` passed;
- the release build completed as universal Pairbar 2.0.0 (17) for `x86_64 arm64`;
- `dist/Pairbar.zip` was freshly extracted and passed ZIP integrity and `codesign --verify --strict --all-architectures`;
- the archive SHA-256 is `fbd9891b696fac98b4b28e2ed4f9502db9705956632dd998fa7f3a6514ff8058`;
- Pairbar is ad-hoc signed with hardened runtime. It has no Developer ID signature or notarization.
- implementation commit `91db9471a05ada20e58c5a1b4f6e9c181afad273`, release-readiness commit `d34d82728cf0dc0b65b438c8975c262e5d0d74de`, and final recorded merge commit `0bf3fbcb083e4a6454db2227e78e28522c566d89` passed the macOS 14/15 matrix; the final post-merge run is `35585485542`.

Read-only checks outside the task sandbox verified ChatGPT `26.915.31945 (9922)` and Claude `1.34493.1` with strict signing and Gatekeeper. Pairbar's checks reported fingerprints `d87b…eacc1a` and `cd6e…ab1f`. Earlier failures were reproduced as sandbox trust-store false negatives, not bundle modification. Both official bundles were left untouched.

`--check-claude` completed its read-only installed-bundle inspection. Synthetic Claude tests passed while managed Claude remained hard disabled pending the real Chat, Code, and Cowork matrix.

The installed-app pass completed opaque legacy migration, creation of two non-auto-opening disposable records, one receipt-verified managed launch, Pairbar restart/reinstall persistence, login-item registration/unregistration, English/Spanish refresh, Full Keyboard Access traversal, VoiceOver accessibility-tree inspection, and light/dark/contrast/transparency checks. All temporary system settings were restored. A second managed launch visibly opened but retained pending intent without a receipt; Pairbar correctly entered recovery-required state and controlled no uncertain process. Because the task-hosting `Work` profile could not be stopped, signed-in identity separation, owned lifecycle, completed recovery, archive/reset, an actual login event, and human VoiceOver speech/rotor acceptance did not run.

## Remaining acceptance gates

1. Complete signed-in Codex isolation, owned lifecycle, recovery/archive/reset, actual-login-event, human VoiceOver, and clean-user checks in a separate disposable environment.
2. Keep managed Claude blocked until its full real Chat and Code matrix passes; validate Cowork separately.
3. Perform authorized Developer ID signing, notarization, stapling, and final clean-machine artifact verification before public distribution.

## Release boundary

Public release remains gated on real signed-in acceptance and Developer ID notarization. An ad-hoc archive is a development artifact. Claude remains unavailable for managed profiles until its acceptance gate passes; this is not a completed claim of Claude support.
