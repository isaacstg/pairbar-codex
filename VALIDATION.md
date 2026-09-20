# Pairbar validation and release status

Last reconciled on 2026-09-21. This record separates the frozen 1.3.3 baseline, Pairbar 2 static/integration validation, and real signed-in acceptance. A result in one section must not be used to claim completion of another.

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

Before Pairbar 2 implementation, the deliberate local worktree was consolidated at:

```text
commit 4efdd57718e9a652bcb49d01d6c9b077d7e410f5
tag    recovery/pairbar-1.3.3-20260919
branch codex/pairbar-2
```

Remote `main` was read-only verified at `4399fd2090d5e5aa152ec5f0aa0188f5f3e5c5cf` on 2026-09-19 and rechecked unchanged on 2026-09-21. The Pairbar 2 branch had not been pushed when this audit began; no pull, reset, checkout, or clean was performed.

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

## Pairbar 2 integrated validation

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
- all **131 Swift tests** passed using workspace-local module caches;
- the release build completed as Pairbar **2.0.0 (17)**;
- the local arm64 build produced `dist/Pairbar.zip` with SHA-256 `da85d12d0c45546598f7eb7e6d52b8cbefbc2fea04ab31e9cd636d59a0da7b6c`;
- a fresh extraction, ZIP integrity check, and `codesign --verify --strict --all-architectures` passed;
- the extracted Pairbar bundle is ad-hoc signed with hardened runtime. It is not Developer ID signed or notarized.

The earlier implementation pass recorded a successful read-only `--check-app /Applications/ChatGPT.app` result for ChatGPT `26.915.31945 (9922)` with fingerprint `d87b…eacc1a`. On 2026-09-21, Pairbar rechecked that reported version and macOS returned `invalid signature (code or signature have been modified)`. Pairbar stopped before compatibility approval. The official bundle was not modified or repaired during this audit. The current local installation is therefore a failed identity gate, not compatibility evidence.

The first read-only `--check-claude /Applications/Claude.app` attempt ran against Claude `1.34493.1` and failed at the same strict signature gate before packaged-code inspection. No installed-Claude compatibility result is claimed. Synthetic Claude tests passed and the production managed-Claude gate remains closed.

### Automated/static checklist

- [x] Source-policy audit passes on the integrated tree.
- [x] Diff whitespace, shell syntax, and plist checks pass.
- [x] Dynamic store and migration tests pass for the implemented future-schema, opaque legacy `Profiles/b`, duplicate, link, mode, size, orphan, interrupted archive, and transition-recovery cases.
- [x] Dynamic state tests pass for PID reuse, unreadable observations, duplicate ownership, pending launches, provider-wide uncertainty, and Current ambiguity.
- [x] Controller fake-runtime tests pass for Current protection, pending-before-open, returned-process classification, post-inspection ownership revalidation, failure recovery, concurrency serialization, close timeout, restart exclusion, unreadable/reused PID, login selection, and critical-memory focus of existing instances.
- [x] Synthetic Claude tests pass for ASAR parsing bounds, traversal/link rejection, unstable replacement, packaged-code findings, and the permanently false managed-launch preflight.
- [x] UI/model tests pass for search, filters, favorites, selection/revalidation, stale action rejection, shortcut validation/display, and preview action no-ops.
- [x] Full 131-test Swift suite passes using workspace-local module caches.
- [x] Release compilation succeeds for 2.0.0 (17).
- [x] Fresh ZIP extraction, integrity check, and strict all-architectures app-bundle signature verification succeed.
- [x] Packaged version, build number, executable archive, ad-hoc hardened-runtime signature, and SHA-256 are inspected.
- [x] Preview execution bypasses controller/store/runtime/shortcut construction; the native preview opened with live and startup actions disabled, and Profiles/Settings accessibility labels were inspected.

The 131-test result includes an in-memory preview action-no-op test and explicit Claude fail-closed lifecycle/archive tests. A native visual pass confirmed the popover and Settings surfaces render. Keyboard-only, VoiceOver, contrast, every view/state, and a checked-in product screenshot remain manual acceptance items.

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

No smoke, signed-in, provider lifecycle, login-item, keyboard-only, or VoiceOver test was run. The only native visual test used the inert preview and could not touch accounts. This preserved the task-hosting Second Account. Every real-account acceptance item below therefore remains pending for Current or a disposable environment.

## Codex signed-in acceptance matrix

- [ ] Create two new managed profiles without a saved-profile count cap and confirm neither opens merely because it was saved.
- [ ] Sign each into a different test account and confirm Chat and Code state remain distinct.
- [ ] Keep normal Current on ordinary storage and prove Pairbar never presents managed lifecycle controls for it.
- [ ] Open each profile alone, open a specifically selected set, and verify no unselected profile opens.
- [ ] Exercise favorites, search, Codex/Claude filters, reordering, English/Spanish UI, long names, keyboard navigation, and accessibility labels.
- [ ] Register distinct configurable shortcuts; verify conflicts and registration failures retain the previous working set.
- [ ] Exercise rapid/overlapping open requests and prove no duplicate process or shared receipt is created.
- [ ] Gracefully close and restart only a newly created receipt-owned profile; verify Current and the task-hosting Second are unchanged.
- [ ] Restart Pairbar with multiple disposable managed profiles alive and prove each remains associated only with its exact receipt.
- [ ] Simulate an interrupted launch, stale/reused PID, unreadable identity, moved app, changed fingerprint, and update during launch; confirm every ambiguous action fails closed.
- [ ] Enable Start Pairbar at Login separately from Open Selected Profiles; opt in a subset and prove no other saved profile opens.
- [ ] Trigger warning and critical memory states; confirm new automatic openings pause while existing processes remain running.
- [ ] Migrate a copy of Current + Second metadata and prove the old Second remains usable without reading or moving its contents.
- [ ] Archive and reset a disposable profile only after fresh provider-wide quiescence; prove the old directory is retained in the archive and a reset gets a new generation.
- [ ] Exercise configuration export and diagnostics; verify no ID, path, PID, receipt, fingerprint, journal, account identity, or credential appears.
- [ ] Upgrade/uninstall Pairbar and prove provider Current data remains untouched and archived/managed data remains recoverable.

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

A local or CI `Pairbar.zip` is an ad-hoc development artifact unless it has separately completed Developer ID signing and notarization. Do not describe the current Pairbar 2 worktree as published, notarized, or generally available.

A public release requires:

- every automated/static check recorded with exact results;
- the safe Codex signed-in matrix completed on the release candidate;
- Claude kept disabled or its exact provider/version acceptance gate completed;
- Cowork language matching its actual evidence;
- authorized Developer ID signing, notarization, stapling, and clean-machine verification;
- release notes that distinguish Current support from managed-profile support;
- no regression of network, credential, official-app integrity, Current protection, recovery, archive, or redaction invariants.
