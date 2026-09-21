# Pairbar validation and release status

Last reconciled on 2026-09-21. This record separates the frozen 1.3.3 baseline, validation of the current Pairbar update, and real signed-in acceptance. A result in one section must not be used to claim completion of another.

## Claims and required evidence

| Claim | Minimum evidence |
|---|---|
| Selected bundle is the official provider app | Expected bundle ID, Team ID, executable, and strict signature verification |
| Pairbar owns a managed process | Exact profile receipt plus stable live UID, start time, executable, provider identity, storage generation, launch ID, paths, and policy checks |
| Managed storage was initialized separately | Filesystem metadata observed only inside a new disposable profile after launch |
| Accounts are isolated | Distinct signed-in accounts exercised across Chat and Code, focus, restart, Pairbar restart, and app update with no crossover |
| Claude managed profiles are supported | Full Claude Chat + Code acceptance protocol passes for the exact official version |
| Cowork is isolated | Separate Cowork cloud/local-VM/configuration/permission/transition matrix passes |
| Artifact is a public release | Developer ID signature, notarization, stapling, clean-machine verification, and completed acceptance record |

A PID, signature, static marker, successful build, or isolated directory alone cannot establish account isolation.

## Frozen 1.3.3 baseline

Before the current Pairbar update, the deliberate local worktree was consolidated at:

```text
commit 4efdd57718e9a652bcb49d01d6c9b077d7e410f5
tag    recovery/pairbar-1.3.3-20260919
branch codex/pairbar-2
```

PR [#1](https://github.com/isaacstg/pairbar-codex/pull/1) merged the verified implementation commit `91db9471a05ada20e58c5a1b4f6e9c181afad273` into `main` as merge commit `520f85db55fe403e910331a5e1f1760f0efd48eb` on 2026-09-21. The post-merge macOS 14/15 workflow run `35541961329` passed.

PR [#2](https://github.com/isaacstg/pairbar-codex/pull/2) merged release-readiness commit `d34d82728cf0dc0b65b438c8975c262e5d0d74de` into `main` as `0bf3fbcb083e4a6454db2227e78e28522c566d89`. Its post-merge macOS 14/15 workflow run `35585485542` passed both jobs.

Installed acceptance found one localization defect. Code commit `0dcaeff6e98fb7009319363c5e5baa3c6f406273` clears a stale localized error and refreshes login-item status whenever the language changes. The 133-test suite and the universal artifact recorded below were produced from that application source; GitHub CI for the acceptance branch is recorded when its PR completes.

The baseline passed:

- `python3 scripts/audit.py`;
- whitespace, shell syntax, and plist validation;
- all 47 baseline tests using repository-local Swift/Clang module caches;
- release compilation and local packaging;
- strict verification of the staged ad-hoc Pairbar bundle.

Historical CI and local testing also exercised the fixed Current + Second implementation, including an unsigned disposable profile that initialized separate Electron and Codex directories beside a preserved Current process. Installed 1.3 testing later observed two signed-in entries and repeated Open Both without an extra process.

Those are useful regression references only. They do not validate:

- the schema-3 dynamic store or metadata migration;
- more than one managed Codex profile;
- configurable shortcuts or selected-at-login behavior;
- dynamic archive/recovery across several profiles;
- Claude Chat, Code, or Cowork isolation.

Specific historical PIDs are intentionally omitted. They were observations from completed runs, not reusable ownership evidence.

## Pairbar integrated validation

The integration source includes:

- provider-aware Current entries and dynamic managed Codex profile records;
- schema-3 metadata, opaque legacy Second migration, pending/receipt state, orphan detection, and journaled archive/reset;
- a pure provider state resolver with explicit absent, unreadable, and verified observations;
- LaunchServices runtime orchestration with an allowlisted environment and strong ownership checks;
- scalable popover UI with favorites, search, provider filters, explicit selection, configurable shortcuts, English/Spanish text, and separate login options;
- read-only Claude bundle/ASAR inspection with all managed Claude capabilities marked unvalidated;
- an inert preview model and redacted diagnostics/configuration export.

The audited worktree completed the following non-live validation on 2026-09-21:

- `scripts/audit.py` passed;
- `git diff --check`, `plutil`, and `bash -n` passed;
- all **133 Swift tests** passed using workspace-local module caches;
- the release build completed as Pairbar **2.0.0 (17)**;
- the local universal build produced `dist/Pairbar.zip` for `x86_64 arm64` with SHA-256 `fbd9891b696fac98b4b28e2ed4f9502db9705956632dd998fa7f3a6514ff8058`;
- a fresh extraction, ZIP integrity check, and `codesign --verify --strict --all-architectures` passed;
- the extracted Pairbar bundle is ad-hoc signed with hardened runtime. It is not Developer ID signed or notarized.
- GitHub Actions passed macOS 14 and macOS 15 for implementation commit `91db9471a05ada20e58c5a1b4f6e9c181afad273`, release-readiness commit `d34d82728cf0dc0b65b438c8975c262e5d0d74de`, and both post-merge revisions. The final recorded `main` run `35585485542` passed both jobs for merge commit `0bf3fbcb083e4a6454db2227e78e28522c566d89`.

Initial strict checks inside the task sandbox reported both installed apps as modified. The same sandbox could not read any of the 158 certificates in the system root keychain and also failed validation of a macOS system app. Independent resource-seal verification found 3,809 matching ChatGPT resources and 2,749 matching Claude resources with no missing or mismatched files; signed executable page hashes, `Info.plist`, `CodeResources`, and detached CMS signatures also matched.

The decisive read-only checks were repeated outside the sandbox. `codesign --verify --strict --all-architectures` validated ChatGPT `26.915.31945 (9922)`, Claude `1.34493.1`, and every nested component; `spctl` accepted both as `Notarized Developer ID`. Pairbar then reported `OpenAI signature verified` with fingerprint `d87b…eacc1a` and `Anthropic signature verified` with fingerprint `cd6e…ab1f`. The earlier errors were sandbox trust-service false negatives. Neither official app was modified, repaired, replaced, or re-signed.

Installed-Claude static inspection succeeded, but managed Claude remains unavailable because signed-in Chat, Code, and Cowork isolation has not passed.

### Automated/static checklist

- [x] Source-policy audit passes on the integrated tree.
- [x] Diff whitespace, shell syntax, and plist checks pass.
- [x] Dynamic store and migration tests pass for the implemented future-schema, opaque legacy `Profiles/b`, duplicate, link, mode, size, orphan, interrupted archive, transition-recovery, and five injected archive durability-boundary cases.
- [x] Dynamic state tests pass for PID reuse, unreadable observations, duplicate ownership, pending launches, provider-wide uncertainty, and Current ambiguity.
- [x] Controller fake-runtime tests pass for Current protection, pending-before-open, returned-process classification, post-inspection ownership revalidation, failure recovery, concurrency serialization, close timeout, restart exclusion, unreadable/reused PID, login selection, and critical-memory focus of existing instances.
- [x] Synthetic Claude tests pass for ASAR parsing bounds, traversal/link rejection, unstable replacement, packaged-code findings, and the permanently false managed-launch preflight.
- [x] UI/model tests pass for search, filters, favorites, selection/revalidation, stale action rejection, shortcut validation/display, and preview action no-ops.
- [x] Full 133-test Swift suite passes using workspace-local module caches.
- [x] Release compilation succeeds for 2.0.0 (17).
- [x] Fresh ZIP extraction, integrity check, and strict all-architectures app-bundle signature verification succeed.
- [x] Packaged version, build number, executable archive, ad-hoc hardened-runtime signature, and SHA-256 are inspected.
- [x] Preview execution bypasses controller/store/runtime/shortcut construction; Profiles, Settings, and Help opened in English and Spanish with live/startup actions disabled. Search and Command-F filtering worked, the accessibility tree exposed labeled controls and states, and three isolated synthetic screenshots were checked in under `docs/images/`.

The 133-test result includes an in-memory preview action-no-op test, explicit Claude fail-closed lifecycle/archive tests, injected one-shot failures after journal persistence, storage rename, each parent-directory sync, and profile metadata persistence, plus a regression test proving that changing language clears a stale localized error and refreshes the login-item status. Every injected durability failure left a recoverable journal; recovery preserved the opaque marker and completed exactly one archive.

The native preview confirms Command-F search, English/Spanish rendering, accessible labels, and visually legible dark-mode surfaces. The installed-app pass then enabled Full Keyboard Access temporarily and reached search, provider filters, profile actions, Settings, Add Profile, and Help using Tab. VoiceOver exposed labels, values, disabled states, hints, recovery text, and confirmation actions. Light, dark, Increase Contrast, and Reduce Transparency modes rendered legibly. All changed system settings were restored. VoiceOver audio/rotor output was not human-observed, so that portion remains pending manual acceptance.

### Reference commands

Run from the repository root. In a restricted workspace, keep module caches inside ignored `work/`:

```sh
python3 scripts/audit.py
CLANG_MODULE_CACHE_PATH="$PWD/work/clang-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/work/swift-cache" \
swift test --disable-sandbox --cache-path work/swift-cache
SWITCHER_SWIFTPM_DISABLE_SANDBOX=1 bash scripts/build.sh
```

Disabling SwiftPM's nested sandbox addresses the build environment only; it does not change Pairbar's runtime privileges or relax its policy.

## Safe real-acceptance environment

The Second Account managed by Pairbar currently hosts the development task. Do not close, restart, reset, archive, recover, or replace that account during validation.

Run lifecycle and signed-in cases from one of these environments:

1. a separate macOS user or test Mac;
2. the normal Current context with only newly created disposable managed profiles;
3. a clean copy of metadata and opaque profile directories that cannot affect the hosting instance.

Before each destructive-looking test, resolve the exact disposable profile and prove its receipt. Do not inspect profile contents, tokens, cookies, Keychain, provider logs, another process's arguments, or another process's environment. Do not modify an official app bundle.

### Installed-app acceptance attempt — 2026-09-21

This pass used the installed universal ad-hoc build on the development Mac. It did not inspect account data, provider storage contents, credentials, another process's arguments/environment, or change either official app. The task-hosting `Work` process remained open throughout and received no close, restart, archive, reset, or recovery action.

| Area | Result | Evidence and limit |
|---|---|---|
| Legacy migration | Passed for metadata/storage preservation | Launch migrated the existing root to schema 3, retained the legacy `Profiles/b` path and presented it as `Work`, without decoding or moving its opaque contents. |
| Disposable profile creation | Passed | `Acceptance A` and `Acceptance B` were saved through the production UI and did not open merely because they were created. Their Electron and `CODEX_HOME` directories were distinct, private profile paths. |
| Managed launch and ownership | Partial, then safely blocked | `Acceptance A` produced a verified receipt. `Acceptance B` visibly opened, as confirmed by the user, but Pairbar retained pending intent without a receipt and changed the provider to recovery-required. It did not guess ownership or control the process. Signed-in account identity was not verified. |
| Recovery | Fail-closed behavior passed; completion blocked | Safe recovery refused to clear uncertainty while provider processes remained and the pending launch lacked a receipt. Completing recovery would require all ChatGPT instances to stop, including task-hosting `Work`, so it was deliberately not attempted. |
| Pairbar restart and reinstall | Passed for Pairbar state | Pairbar quit normally and released its controller lock. Removing/reinstalling only Pairbar preserved Current, `Work`, both disposable records, their states, preferences, and provider data. The official app bundles were untouched. |
| Current protection | Passed for observed UI and runtime behavior | Current remained on ordinary storage, showed no managed close/restart/reset control, and was not closed. Pairbar did not repurpose a managed process as Current while ownership was uncertain. |
| Launch at Login registration | Passed; login-event launch not run | `SMAppService` registration changed the installed UI from Disabled to Enabled and unregistering returned it to Disabled. “Open chosen profiles” remained an independent opt-in and exposed explicit per-profile choices. Logging out/restarting the user session was not safe during this task. |
| Language changes | Passed after correction | Switching English → Spanish cleared the stale English recovery message and refreshed login status to Spanish; switching back refreshed it to English. Preferences were restored to their pre-test values. |
| Keyboard and visual accessibility | Passed with tooling | Full Keyboard Access traversed the complete available popover controls. The UI remained legible in light/dark, Increase Contrast, and Reduce Transparency modes. System settings were restored afterward. |
| VoiceOver | Partial | The accessibility tree exposed the expected labels, values, hints, states, and safe-recovery confirmation while VoiceOver was enabled. Human listening, rotor order, and spoken-announcement quality were not observed. VoiceOver was restored to off. |
| Owned lifecycle, Open Selected, shortcuts, archive/reset | Not run live | Provider-wide recovery after `Acceptance B` prevented further managed actions. The task-hosting process could not be stopped to establish provider-wide quiescence. Automated tests cover these paths, but that is not live acceptance. |
| Developer ID distribution | Blocked | The release keychain exposed zero `Developer ID Application` identities without printing identity details. No Developer ID signing, notarization, stapling, tag, or GitHub Release was attempted. |

The fail-closed `Acceptance B` result is a real acceptance blocker, not a pass inferred from implementation. Finish the remaining provider matrix from a separate macOS user or test Mac where every disposable ChatGPT instance can be stopped without terminating the task-hosting session.

## Codex signed-in acceptance matrix

- [x] Create two new managed profiles without a saved-profile count cap and confirm neither opens merely because it was saved.
- [ ] Sign each into a different test account and confirm Chat and Code state remain distinct.
- [ ] Keep normal Current on ordinary storage and prove Pairbar never presents managed lifecycle controls for it.
- [ ] Open each profile alone, open a specifically selected set, and verify no unselected profile opens.
- [ ] Exercise favorites, search, Codex/Claude filters, reordering, English/Spanish UI, long names, keyboard navigation, and accessibility labels. Keyboard traversal, labels, filters, language switching, and appearance modes passed; live reordering and long-name acceptance remain.
- [ ] Register distinct configurable shortcuts; verify conflicts and registration failures retain the previous working set.
- [ ] Exercise rapid/overlapping open requests and prove no duplicate process or shared receipt is created.
- [ ] Gracefully close and restart only a newly created receipt-owned profile; verify Current and the task-hosting Second are unchanged.
- [ ] Restart Pairbar with multiple disposable managed profiles alive and prove each remains associated only with its exact receipt.
- [ ] Simulate an interrupted launch, stale/reused PID, unreadable identity, moved app, changed fingerprint, and update during launch; confirm every ambiguous action fails closed.
- [ ] Enable Start Pairbar at Login separately from Open Selected Profiles; opt in a subset and prove no other saved profile opens. Registration/unregistration and independent selections passed; an actual login event remains.
- [ ] Trigger warning and critical memory states; confirm new automatic openings pause while existing processes remain running.
- [x] Migrate Current + legacy Second metadata and prove the old Second remains usable without reading or moving its contents.
- [ ] Archive and reset a disposable profile only after fresh provider-wide quiescence; prove the old directory is retained in the archive and a reset gets a new generation.
- [ ] Exercise configuration export and diagnostics; verify no ID, path, PID, receipt, fingerprint, journal, account identity, or credential appears.
- [ ] Upgrade/uninstall Pairbar and prove provider Current data remains untouched and archived/managed data remains recoverable. Pairbar-only reinstall and metadata persistence passed; archived-data recovery remains.

Record provider app version, Pairbar commit, macOS version, test profile identifiers as non-sensitive aliases, expected result, observed result, and retained artifacts. Never record real account identifiers.

## Claude acceptance gate

Managed Claude profiles stay disabled throughout ordinary validation. Static inspection may be repeated read-only, but its result cannot open a managed profile.

The exact test protocol is [docs/CLAUDE_ACCEPTANCE.md](docs/CLAUDE_ACCEPTANCE.md). At minimum, it must demonstrate:

- two different signed-in Chat accounts without cookie, OAuth, deep-link, notification, or restart crossover;
- separate Code configuration, project state, shell integration, MCP state, and secure storage;
- concurrent Chat + Code use in both profiles across Pairbar restart and Claude update;
- normal Claude Current remaining on ordinary storage;
- reliable receipt ownership without credential, argv, or environment inspection;
- failure/recovery behavior that never controls an unproven process.

Cowork remains unvalidated even if Chat and Code pass. It needs independent tests for cloud execution, local VM state, permissions, configuration, links, artifacts, and transitions between Cowork and Chat.

Until the applicable gate passes, release text must use “Current only,” “under investigation,” or “unavailable” for managed Claude. It must not say Claude profiles are isolated or supported.

## Preview acceptance

Preview uses fixed, in-memory example rows. A successful visual pass should cover welcome, profiles, search/no-results, provider filters, favorites, selection, settings, editor validation, Help, memory warning, recovery state, long Spanish/English labels, keyboard navigation, and accessibility inspection.

The pass is valid only if instrumentation or code-path evidence also confirms that preview:

- does not acquire the production store/controller lock;
- does not read or write production Pairbar metadata or preferences;
- does not inspect `ChatGPT.app` or `Claude.app`;
- does not enumerate, focus, launch, close, or restart provider processes;
- does not register global shortcuts or login items;
- does not write diagnostics/export output.

## Release boundary

A local or CI `Pairbar.zip` is an ad-hoc development artifact unless it has separately completed Developer ID signing and notarization. Do not describe the current Pairbar worktree as published, notarized, or generally available.

A public release requires:

- every automated/static check recorded with exact results;
- the safe Codex signed-in matrix completed on the release candidate;
- Claude kept disabled or its exact provider/version acceptance gate completed;
- Cowork language matching its actual evidence;
- authorized Developer ID signing, notarization, stapling, and clean-machine verification;
- release notes that distinguish Current support from managed-profile support;
- no regression of network, credential, official-app integrity, Current protection, recovery, archive, or redaction invariants.
