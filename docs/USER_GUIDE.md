# Pairbar user guide

Pairbar is a native macOS menu-bar utility for keeping several account profiles close at hand while leaving the official provider apps unchanged. Pairbar has no permanent window and does not require a Dock icon; profile management, settings, help, recovery, diagnostics, and export all live in its popover.

Pairbar is currently a development build. Local and CI archives are ad-hoc development artifacts, not a signed and notarized public release.

## What is supported

Pairbar models each provider in two parts:

- **Current** is the provider's ordinary account and storage. Pairbar may verify, open, or focus it, but never closes, restarts, resets, archives, or creates an ownership receipt for it.
- **Managed profiles** are additional profiles with Pairbar-owned storage and process receipts. The source currently enables these for the official ChatGPT/Codex app only.

There is no product-imposed limit on saved Codex profiles. Saving a profile does not open it. Pairbar opens only a profile you choose, a selected set you explicitly choose, or profiles individually opted into login launch under the separate global login option.

| Provider | Current | Managed profiles |
|---|---|---|
| Official ChatGPT/Codex app | Normal open/focus | Available after compatibility approval; separate Electron storage and `CODEX_HOME` |
| Official Claude.app | Normal open/focus after identity verification | Disabled until signed-in Chat and Code isolation tests pass |
| Claude Cowork | No managed behavior | Unvalidated; do not infer isolation from Chat or Code results |

Static inspection found packaged support related to `CLAUDE_USER_DATA_DIR`, `CLAUDE_CONFIG_DIR`, and `CLAUDE_SECURESTORAGE_CONFIG_DIR`. It also found behavior that removes at least one override in ordinary production startup and disables local pairing when user data is relocated. Those findings are reasons to test, not evidence that accounts are separated. Pairbar does not use hidden harnesses, patch Claude, or enable managed Claude launches on that basis.

## Requirements

- macOS 13 or later.
- The official Electron-based `ChatGPT.app` with bundle identifier `com.openai.codex` for Codex profiles.
- The official `Claude.app` with bundle identifier `com.anthropic.claudefordesktop` and Team ID `Q6L2SF6YDW` only if you want its normal Current entry.
- Xcode Command Line Tools with Swift 5.9 or later when building from source.

Pairbar has no third-party Swift package dependency and contains no updater. Build validation is described in [IMPLEMENTATION_STATUS.md](IMPLEMENTATION_STATUS.md).

## First run and migration

1. Place `Pairbar.app` in `/Applications` or `~/Applications`.
2. Open it. The Pairbar icon appears in the menu bar.
3. Read the welcome page and continue to Profiles.
4. Check the installed official app for the provider you want to use.
5. For Codex, confirm the checked build before creating or opening additional profiles.

An existing Codex Account Switcher or Pairbar 1.3.3 installation is migrated without reading profile contents:

- the normal account becomes Codex Current and continues to use ordinary provider storage;
- the saved Second metadata becomes a managed Codex profile;
- the existing `Profiles/b` directory is retained as that profile's storage;
- legacy Current receipts and pending markers are discarded;
- legacy private profile contents are neither opened nor copied by migration;
- future metadata schemas are rejected rather than silently downgraded.

Keep the existing application-support directory during an upgrade. If migration reports uncertainty, use Safe Recovery only after following the instructions in the popover. Do not manually edit Pairbar metadata to bypass recovery.

## Profiles page

The Profiles page shows Current and managed profiles together. Every row identifies its provider, whether it is Current or managed, and its state.

- Use **Search** to match a saved display name or provider.
- Use **All**, **Codex**, or **Claude** to filter the list.
- Mark frequently used entries as favorites; favorites sort before other rows.
- Choose **Select**, tick only the profiles you want, then open the selected set.
- Open or switch to a single row with its main button.
- Use the row menu to edit, favorite, reorder, or—only for a verified managed profile—close, restart, archive, or archive and reset.

Pairbar never offers destructive lifecycle controls for Current. If a process is unreadable, ambiguous, or cannot be matched to a receipt, the affected actions are disabled and the row asks for verification or recovery.

### Memory pressure

Saved profiles are not a promise that every profile can remain open simultaneously. At elevated memory pressure, Pairbar asks you to open only what you need. At critical pressure, automatic openings and new launches are paused; existing official-app processes are preserved. An explicit manual override, when offered, applies to that launch only.

## Creating and editing a Codex profile

1. On Profiles, choose **Add profile**.
2. Select Codex and enter a unique name from 1 to 40 characters.
3. Optionally mark it as a favorite, assign a shortcut, or opt it into the profile-at-login list.
4. Save. The profile is stored but is not opened.
5. Open it when ready and sign into the intended account in the official app window.
6. Verify the displayed account before using it for sensitive work, especially after an official-app update.

Each generated Codex profile receives a private base directory containing separate Electron storage and a private `CODEX_HOME`. The legacy migrated Second profile keeps the historical path:

```text
~/Library/Application Support/Codex Dual Account Switcher/Profiles/b
```

New profiles use opaque generated directories below the same Pairbar root. Display names never become filesystem paths.

Pairbar launches the official app through LaunchServices with an allowlisted environment and the required profile overrides. It does not patch, copy, inject into, re-sign, or replace `ChatGPT.app`.

## Current accounts

There is one Current entry per provider. Current always means the provider's normal application storage:

- Current receives no Pairbar profile environment or command-line override.
- Current has no managed profile record, private directory, pending marker, or receipt.
- Pairbar may open or focus Current after checking official-app identity.
- Pairbar never closes, restarts, resets, or archives Current.
- If several normal candidates exist, or managed ownership is uncertain, Pairbar refuses to guess which process is Current.

Opening Current while a managed instance exists requests a distinct normal app instance. Pairbar verifies the returned process is resolved as Current before focusing it.

## App checks and updates

Opening Current requires an identity check of the selected official app. Opening a stopped managed Codex profile also requires a successful compatibility inspection and approval of the installed build fingerprint.

After a ChatGPT update, Pairbar may continue to focus an already verified, receipt-owned managed process. It blocks a new managed launch until the new installed build is inspected and explicitly approved. Approval never bypasses pending recovery or ambiguous ownership.

Claude's identity check is intentionally separate from managed capability. A genuine, correctly signed Claude.app can be used as Current without implying that profile relocation isolates Chat, Code, secure storage, OAuth, deep links, extensions, or Cowork.

## Shortcuts

Shortcuts are configurable per Current entry or managed profile. Pairbar rejects an invalid or duplicate chord and retains the previous working bindings if registration fails. Shortcuts do not bypass app identity, compatibility, memory, ownership, or recovery checks.

The migrated Codex Current and Second entries retain the historical shortcuts where possible. New profiles do not receive an implicit shortcut.

Inside the popover:

- Command-F focuses profile search.
- Shift-Command-B returns to Profiles from another page.
- Escape closes the popover.

## Startup at login

Two separate choices are required:

1. **Start Pairbar at login** registers only the Pairbar menu-bar app.
2. **Open selected profiles at login** allows Pairbar to consider rows individually marked for login opening.

Both are off by default. Marking a row for login does nothing until the global profile-opening option is also enabled. Pairbar never interprets this as “open all saved profiles.” Startup processing runs only for the actual login launch, respects memory and safety gates, and stops when a selected target cannot be opened safely.

## Process ownership and lifecycle controls

Before launching a managed profile, Pairbar persists a pending marker. It then verifies the new process and saves a receipt containing Pairbar-owned identity data. Ownership requires the receipt to match:

- provider and profile identifier;
- storage generation and launch identifier;
- PID, macOS user, and kernel process start time;
- exact official executable and provider identity;
- the profile's expected private paths;
- the approved app fingerprint and launch-policy version where applicable.

Pairbar never reads another process's arguments or environment to establish ownership. It uses OS-provided process identity and its own launch record.

Close is graceful and is available only for a verified managed process. Pairbar waits for exit and does not escalate to a forced kill. Restart first proves that the profile is safe to reopen, closes the verified owned process, confirms its exit, and then performs a new verified launch. Any mismatch preserves the receipt and stops the operation.

## Recovery

A crash or interruption can leave a pending marker or a receipt whose process cannot be verified. Pairbar then fails closed.

Safe recovery has two categories:

1. If a pending launch can be matched to a still-running, correctly signed process and the unchanged approved build, Pairbar may restore the receipt without controlling that process.
2. Otherwise, recovery requires every official process for that provider to be closed manually. Pairbar rechecks quiescence immediately before changing ownership metadata.

Do not use recovery to close the Second Account that hosts a development task. Finish acceptance from Current, another macOS user or machine, or explicitly new disposable profiles.

## Archive, reset, and retained data

Archive operations are conservative and recoverable. They require the provider to be quiescent, with no unreadable process, receipt, pending launch, competing archive operation, or unexplained profile directory.

- **Archive profile** removes it from the active list and atomically moves its whole storage directory under `Profiles/Archived`.
- **Archive and reset** archives the old directory, assigns fresh storage and a new storage generation, and keeps the profile entry ready for a future clean sign-in.

Pairbar does not inspect the contents during the move and does not immediately delete the archived directory. Purging archived data is a separate, deliberate manual operation performed only when all relevant provider processes are closed.

## Claude acceptance boundary

Managed Claude profiles remain unavailable. Enabling them requires repeatable signed-in evidence for at least:

- two distinct Chat accounts with no cookie, OAuth, deep-link, notification, or restart crossover;
- two distinct Code states with separate configuration, project state, shell integration, MCP settings, and secure storage;
- combined Chat + Code use in both profiles across restart and official-app update;
- confirmation that normal Current remains on ordinary storage and Pairbar can identify every managed process without reading credentials;
- a separate Cowork matrix covering cloud execution, local VM state, shared configuration, permissions, links, and transitions between Chat and Cowork.

The detailed protocol is in [CLAUDE_ACCEPTANCE.md](CLAUDE_ACCEPTANCE.md). Until it passes, the UI must say “under investigation” or “unavailable”; it must not describe Claude as isolated or supported for managed profiles.

## Diagnostics and export

Diagnostics contain bounded Pairbar-generated facts such as version, schema, provider state counts, recovery flags, login-item state, and event codes. They omit account names, profile display names, paths, PIDs, fingerprints, receipt contents, credentials, cookies, tokens, and provider logs.

Configuration export contains non-sensitive preferences only: language, labels, favorites, ordering, shortcuts, and login selections. It excludes storage paths, profile identifiers, receipts, pending launches, archive journals, process data, fingerprints, and private profile contents.

## Preview mode

Preview mode exists for native UI and accessibility review. It uses fixed in-memory examples and disables account, process, storage, startup, and export actions. It must not acquire the production store lock, read live profile metadata, inspect official apps, register login items, or launch any provider process.

## Privacy boundary

Pairbar does not:

- read, copy, parse, export, or migrate authentication tokens;
- read cookies, browser stores, Keychain items, or provider logs;
- inspect account emails or identities;
- inspect another process's command-line arguments or environment;
- make network requests or send telemetry;
- update itself;
- modify, patch, copy, inject into, replace, or re-sign an official app;
- use shell commands or forced termination to control an official app.

Profile separation under one macOS user is not an OS security boundary. All official-app instances retain the permissions and shared operating-system resources of that user.

## Build and uninstall

Build from a regular checkout directory:

```sh
python3 scripts/audit.py
swift test
bash scripts/build.sh
```

The verified local universal development build created Pairbar 2.0.0 (17) at `dist/Pairbar.zip`, SHA-256 `fbd9891b696fac98b4b28e2ed4f9502db9705956632dd998fa7f3a6514ff8058`. It contains `x86_64` and `arm64`; its fresh extraction passed strict all-architectures signature verification. The bundle is ad-hoc signed with hardened runtime. Public distribution still requires an authorized Developer ID signature, notarization, stapling, and clean-machine acceptance.

The audited source passed 133 Swift tests and the source/diff/plist/shell checks. The native UI rendered Profiles, Settings, and Help in English and Spanish with accessibility labels; Command-F search worked and public screenshots contain synthetic data only. The installed app passed keyboard traversal, light/dark/contrast/transparency inspection, opaque migration, Pairbar-only reinstall persistence, and login-item registration. Human VoiceOver listening, signed-in account separation, owned lifecycle, actual login launch, recovery/archive/reset, and clean-user acceptance remain pending. Read-only checks verified installed ChatGPT `26.915.31945 (9922)` and Claude `1.34493.1` outside the task sandbox; both official bundles passed strict signing and Gatekeeper, and Pairbar's compatibility checks passed. The bundles were left untouched.

To uninstall:

1. Finish work in managed profiles and close them through Pairbar while ownership is verified.
2. Disable Pairbar startup at login.
3. Quit Pairbar from Help.
4. Move `Pairbar.app` to Trash.

Provider Current accounts are unaffected. Managed and archived profile data remain in `~/Library/Application Support/Codex Dual Account Switcher` until you deliberately remove that directory after closing all relevant provider processes.

For development boundaries and remaining tests, read [IMPLEMENTATION_STATUS.md](IMPLEMENTATION_STATUS.md), [PAIRBAR_2_EXECUTION.md](PAIRBAR_2_EXECUTION.md), and [VALIDATION.md](../VALIDATION.md).
