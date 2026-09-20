# Pairbar 2 execution record

## Recovery point

The approved 1.3.3 working tree was consolidated at `4efdd57718e9a652bcb49d01d6c9b077d7e410f5`, tagged `recovery/pairbar-1.3.3-20260919`, on `codex/pairbar-2`. Remote `main` was read-only verified as `4399fd2090d5e5aa152ec5f0aa0188f5f3e5c5cf` on 2026-09-19 and rechecked unchanged on 2026-09-21. The Pairbar 2 branch had not been pushed when this audit began.

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

- all 131 Swift tests passed with repository-local module caches, including the final adversarial Claude lifecycle/archive denial cases, suspended-inspection ownership revalidation, independent batch failures, and critical-memory focus behavior;
- `scripts/audit.py`, `git diff --check`, `plutil`, and `bash -n` passed;
- the release build completed as Pairbar 2.0.0 (17);
- `dist/Pairbar.zip` was freshly extracted and passed ZIP integrity and `codesign --verify --strict --all-architectures`;
- the archive SHA-256 is `3fb1070595328e5ae6d296da77c75222fff50ce4e65d4aefce681ab6bd893c12`;
- Pairbar is ad-hoc signed with hardened runtime. It has no Developer ID signature or notarization.

The historical read-only `--check-app /Applications/ChatGPT.app` command passed for version `26.915.31945 (9922)` and reported fingerprint `d87b…eacc1a`. On 2026-09-21, a strict recheck of that installed ChatGPT version failed signature validation; a first read-only Claude check of `1.34493.1` failed at the same gate. Both official bundles were left untouched. The current local installations therefore provide no compatibility evidence.

`--check-claude` was executed read-only and refused the locally installed bundle at strict signature validation, before ASAR findings could be produced. Synthetic Claude tests passed while managed Claude remained hard disabled.

No live smoke, account lifecycle, login-item, signed-in isolation, keyboard, or VoiceOver test ran. This kept the task-hosting Second Account untouched. The inert native preview opened successfully; its Profiles and Settings surfaces and accessibility labels were inspected while all account/startup actions remained disabled.

## Remaining acceptance gates

1. Execute real migration, lifecycle, login-item, signed-in Codex isolation, native visual, accessibility, and clean-machine checks from Current or a disposable environment.
2. Run the installed-Claude check only when safe authorization is available, without treating it as managed-isolation approval.
3. Keep managed Claude blocked until its full real Chat and Code matrix passes; validate Cowork separately.
4. Perform authorized Developer ID signing, notarization, stapling, and final clean-machine artifact verification before public distribution.

## Release boundary

Public release remains gated on real signed-in acceptance and Developer ID notarization. An ad-hoc archive is a development artifact. Claude remains unavailable for managed profiles until its acceptance gate passes; this is not a completed claim of Claude support.
