# Pairbar implementation status

Last reconciled with the Pairbar audit worktree on 2026-09-21. This document distinguishes implemented source, completed evidence, and acceptance still required.

## Product invariant

Each provider has one normal **Current** account. Current uses the official app's ordinary storage, has no Pairbar receipt, and is never closed, restarted, reset, archived, or otherwise destructively controlled by Pairbar.

Additional managed profiles are separate records. Managed Codex profiles have distinct Electron storage and `CODEX_HOME`, durable pending state, and a process receipt. Lifecycle actions require exact ownership proof. The data model imposes no profile-count limit; only explicitly chosen profiles are opened.

## Implemented in the current Pairbar source

### Dynamic model and storage

- Provider-aware settings for Codex and Claude, one Current entry per provider, and independent managed profile records.
- Saved name, favorite, order, configurable shortcut, and per-row login selection.
- Generated immutable storage locators and generations, plus continued support for the legacy `Profiles/b` directory.
- Schema-3 preferences/provider/profile records bounded to 64 KiB each, with atomic descriptor-relative writes and restrictive filesystem validation.
- Metadata-only migration from Current + Second. Migration retains safe legacy Second metadata and storage without reading profile contents, drops legacy Current ownership state, and refuses future schemas.
- Detection of orphan storage, duplicate profile identity/storage/receipt state, pending archive operations, unsafe paths, symlinks, hardlinks, wrong ownership, and permissive modes.
- Journaled archive and reset. Profile directories are moved opaquely into an archive; immediate deletion is not a Pairbar operation.
- Configuration export limited to language, labels, favorites, ordering, shortcuts, and login selections.

### State and runtime

- Pure per-provider resolution for Current and managed states, with explicit absent, unreadable, and verified process observations.
- Current classification excludes only managed processes with fully verified ownership. Ambiguity or recovery uncertainty blocks classification.
- Provider-specific identity inspection and LaunchServices requests using an allowlisted environment.
- Codex managed launch with per-profile Electron and `CODEX_HOME` paths, pending-before-launch ordering, new-process adoption, receipt persistence, post-launch fingerprint recheck, and conservative failure state.
- Graceful close and restart for verified managed profiles only; no forced termination.
- Provider-wide safe recovery and quiescence requirements for metadata repair and archive transitions.
- Memory-pressure state that warns or pauses new/automatic openings without closing existing processes.

A PID, bundle identifier, or signature by itself is never ownership evidence. The receipt and live observation must also match profile, provider, storage generation, launch ID, UID, start time, exact executable, expected paths, identity, and applicable fingerprint policy.

### Interface

- Native menu-bar popover with welcome, Profiles, Settings, Help, create, and edit pages.
- Search by profile/provider, All/Codex/Claude filters, favorites, ordering, and explicit multi-select opening.
- Per-profile editing, configurable global shortcuts with staged registration and rollback, and English/Spanish text.
- Separate “Start Pairbar at login” and “Open selected profiles at login” settings. Both default off; individual row selection never means all profiles.
- Managed-only close, restart, archive, and reset confirmations. Current rows expose no lifecycle action.
- Inline memory/recovery/compatibility state, redacted diagnostics, non-sensitive export, and an inert preview model whose account and startup actions are disabled.
- Accessory-app behavior with no permanent window and no required Dock icon.

### Claude research boundary

- Read-only verification of the official bundle identifier `com.anthropic.claudefordesktop`, expected Team ID `Q6L2SF6YDW`, executable, signature, version, and selected packaged code.
- Bounded ASAR parsing designed to reject traversal, symlinks, unstable assets, oversized entries, and malformed metadata.
- Static findings for the packaged override names and for behavior that can remove an override or disable local pairing.
- Explicit capability states of unvalidated for Chat, Code, and Cowork.
- No managed Claude launch path. Claude Current remains a normal provider app entry after identity verification.

The installed bundle and static markers do not establish account isolation. Managed Claude support remains blocked until [CLAUDE_ACCEPTANCE.md](CLAUDE_ACCEPTANCE.md) passes with signed-in Chat and Code sessions and no crossover. Cowork requires separate evidence.

## Evidence completed before this update

The deliberate 1.3.3 working tree was consolidated at commit `4efdd57718e9a652bcb49d01d6c9b077d7e410f5` with recovery tag `recovery/pairbar-1.3.3-20260919`. The then-known remote `main` was read-only verified at `4399fd2090d5e5aa152ec5f0aa0188f5f3e5c5cf` on 2026-09-19.

That baseline passed:

- source-policy audit, whitespace, shell, and plist checks;
- all 47 baseline unit tests;
- release compilation and local ad-hoc packaging;
- strict verification of the staged Pairbar bundle.

Historical live evidence also showed one disposable legacy Second process initializing separate directories beside a preserved Current process, and a later installed 1.3 workflow with Current + Second. That evidence applies to the fixed two-entry implementation only. It does not prove the current multi-profile behavior or Claude isolation.

## Pairbar validation completed

The integrated tree completed its non-live validation pass:

- all 132 Swift tests passed, covering the dynamic store/migration, injected archive durability failures, state resolver, synthetic Claude inspection, panel model, controller fake runtime, suspended-inspection ownership revalidation, independent batch failures, memory-pressure focus behavior, and Claude lifecycle/archive denial;
- `scripts/audit.py`, `git diff --check`, plist validation, and shell syntax validation passed;
- the release build produced universal Pairbar 2.0.0 (17) for `x86_64 arm64`;
- fresh extraction, ZIP integrity, and `codesign --verify --strict --all-architectures` passed;
- `dist/Pairbar.zip` has SHA-256 `89e26e781329eb075c037bdc994de623ff78ca211301434b7b884971d143f5b2`;
- the bundle is ad-hoc signed with hardened runtime, not Developer ID signed or notarized.
- PR #1 merged implementation commit `91db9471a05ada20e58c5a1b4f6e9c181afad273`; PR #2 merged release-readiness commit `d34d82728cf0dc0b65b438c8975c262e5d0d74de`. Post-merge run `35585485542` passed on macOS 14 and macOS 15 for merge commit `0bf3fbcb083e4a6454db2227e78e28522c566d89`.

Read-only checks outside the task sandbox verified ChatGPT `26.915.31945 (9922)` and Claude `1.34493.1` with strict all-architectures signing and Gatekeeper. Pairbar's own checks passed for both. Earlier failures were sandbox trust-service false negatives; resource manifests, code pages, and CMS signatures were unchanged. The provider bundles were not changed or repaired during this audit. Static compatibility is not signed-in isolation evidence.

The installed-Claude check completed read-only while managed Claude stayed hard disabled. No signed-in, lifecycle, login-item, full keyboard, or VoiceOver pass was performed. The inert native preview opened in English and Spanish and exposed Profiles, Settings, Help, disabled live actions, search behavior, and accessibility labels. Exact evidence is recorded in [VALIDATION.md](../VALIDATION.md).

## Real acceptance still required

Perform these from the normal Current context, a separate macOS user/machine, or explicitly new disposable profiles. Do not close, restart, reset, or recover the Second Account that hosts this development task.

1. Migrate a copy of legacy Current + Second metadata and prove profile contents remain unread and the legacy Second login persists.
2. Create at least two new Codex profiles; prove distinct signed-in Chat and Code state across focus, restart, Pairbar restart, and official-app update.
3. Exercise rapid requests, configurable hotkeys, multi-select, memory warnings, login launch selection, interrupted launch, stale/reused PID, unreadable observation, changed fingerprint, moved app, and provider-wide recovery.
4. Archive and reset disposable profiles only after provider quiescence; verify data is moved to the archive and can be manually recovered.
5. Verify English/Spanish accessibility, keyboard navigation, long names, search/filter/favorite behavior, first-run migration, upgrade, and uninstall on clean supported macOS versions.
6. Run the separate Claude Chat + Code protocol. Keep managed Claude disabled unless every required gate passes; treat Cowork as its own unvalidated surface.

## Release boundary

Pairbar has not been declared Developer ID signed, notarized, stapled, published, or generally available. A passing local build produces an ad-hoc development artifact only.

Public release still requires safe real-account acceptance, native/accessibility validation, login-item validation, clean-machine packaging verification, authorized Developer ID signing, notarization, and stapling. Claude must remain described as Current-only while its managed gate is closed.
