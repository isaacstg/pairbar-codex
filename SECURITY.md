# Security Model

## Scope

Codex Account Switcher provides **profile separation**, not a macOS security sandbox.

The design has two deliberately different trust/ownership roles:

- **Current Account:** the user's ordinary official ChatGPT/Codex profile. The switcher may discover, verify the official app identity, open and focus it, but intentionally does not own its lifecycle.
- **Second Account:** an official ChatGPT process launched with separate Electron and Codex directories. The switcher may focus, gracefully quit or restart it only while strong process ownership can be proven.

Both instances still execute as the same macOS user and therefore share that user's OS-level permissions, Keychain namespace, shell configuration, browser/OAuth environment and other resources. The switcher does not claim to protect one account from a malicious application running as the same user.

## Security invariants

1. The official `ChatGPT.app` is never modified, patched, copied, re-signed, injected into, or rewritten.
2. Current uses normal/default ChatGPT storage and normal `~/.codex`.
3. Only Second receives private Electron/Codex storage overrides.
4. Authentication tokens, cookies, browser stores, account identities and Keychain credentials are never copied, parsed, migrated or inspected.
5. The switcher does not inspect another process's argv or environment.
6. The switcher does not use networking.
7. The switcher does not execute a shell/subprocess to control ChatGPT.
8. Current is never destructively controlled by the switcher.
9. Second is never destructively controlled unless ownership is positively verified.
10. ChatGPT is never force-killed.
11. Ambiguity fails closed: the switcher blocks/asks for manual resolution rather than guessing.
12. A valid PID receipt is not treated as proof that a changed app build still honored isolation.
13. Switcher-private Current storage creation and Current ownership-receipt creation are rejected by the static source-policy audit.

## Current-account discovery

The switcher enumerates running applications with the expected official ChatGPT bundle identifier. It does not inspect credentials or private profile contents to identify accounts.

If Second ownership is positively verified, only that exact PID is excluded from the set of default candidates.

- 0 remaining candidates: Current is considered not running.
- 1 remaining candidate: it may be focused as Current.
- More than 1: Current is ambiguous and discovery/focus is blocked.
- If Second ownership is uncertain: **Current discovery is also blocked**, even with a single visible process, because that process could be an orphaned Second launch.

The last rule is intentionally conservative. A process being signed by OpenAI proves application identity, not which profile/storage role it was launched with.

Current opening itself requires verification of the expected official OpenAI app identity/signature and executable, but it does **not** require the stronger Second-account isolation fingerprint. Current launches with no custom profile arguments/environment.

## Second-account isolation

Second uses switcher-private paths under the historical private root:

```text
~/Library/Application Support/Codex Dual Account Switcher/Profiles/b/
```

The historical directory name is retained across the product display-name change so upgrades continue using the same data.

A Second launch receives a minimal allowlisted environment plus:

```text
CODEX_HOME=<private>/Profiles/b/codex
CODEX_ELECTRON_USER_DATA_PATH=<private>/Profiles/b/electron
--user-data-dir=<private>/Profiles/b/electron
```

The switcher does not forward arbitrary inherited environment variables. In particular, inherited API keys/tokens, `NODE_OPTIONS`, `DYLD_*` and Electron debugging variables are not intentionally forwarded.

## Process ownership

A Second launch receipt records only switcher-owned process metadata:

- profile role (`b`);
- PID;
- UID;
- kernel process start time;
- executable path;
- expected private Codex/Electron paths.

Ownership requires the current kernel snapshot to exactly match the receipt and the current macOS user. This rejects stale PIDs, PID reuse, wrong users, wrong executable paths and receipts for different private paths.

Legacy receipts with profile role `a` can still be decoded for migration but `LaunchReceipt.owns` refuses to treat them as ownership proof.

A launch is adopted only when it is a newly observed process, starts after the launch request, runs as the current user and has the expected official executable path.

The receipt proves process identity/launch provenance only. It does **not** by itself prove the application internally honored every isolation override.

## Official identity vs isolation compatibility

The compatibility layer intentionally has two levels.

### Official app identity

Used for Current Account. It validates the expected bundle identity/signature/executable. This allows Current to remain usable even when Second's isolation compatibility needs review.

### Isolation compatibility

Required before creating Second. It additionally checks the expected Electron user-data override and `CODEX_HOME` support and fingerprints relevant installed application material.

If the approved fingerprint changes, a new Second launch is blocked until the changed build is reviewed and explicitly approved.

Static markers/fingerprints are evidence that the expected mechanism still appears to exist; they are not runtime proof of account isolation.

### Plain-language setup and update confirmation

The menu-bar UI calls initial authorization **Set Up Second Account** and changed-version authorization **Confirm ChatGPT Update**. Both re-inspect the installed official app before persisting its fingerprint. These names simplify the presentation without removing explicit approval.

**Save Names** is a separate metadata-only operation. It cannot change the approved fingerprint, app path, schema, or setup state. Confirmation is refused during pending recovery or an in-flight account lifecycle action, and state is checked again after the asynchronous app inspection. A newer version must not be approved to bypass uncertainty about an older running process.

All routine UI lives in an accessory-app popover. Native action confirmations, startup-error dialogs, and the app file picker remain OS-provided exceptions. No accessibility permission, event-monitor permission, or new entitlement is required by the redesign.

## Interrupted launches and recovery

Before LaunchServices is allowed to create Second, the switcher persists a pending marker. Another Second launch is blocked until that state is resolved.

A successful launch sequence is intentionally ordered:

1. persist pending state;
2. ask macOS to create a new official app instance;
3. verify/adopt the exact new process;
4. persist the Second receipt;
5. re-inspect the installed app fingerprint;
6. clear pending state only if the fingerprint still matches the checked/approved build.

This ordering makes crashes conservative.

### Safe automatic recovery

If a crash occurs after the verified receipt was persisted but before pending was cleared, the switcher may restore the session **only** when:

- the receipt still strongly owns the live process; and
- the currently installed official app still passes isolation inspection; and
- its fingerprint equals the user's already-approved fingerprint.

A verified PID alone is insufficient.

### Manual recovery

If no process can be strongly identified, or the installed fingerprint changed/unavailable, recovery requires **all official ChatGPT instances to be closed manually**. Once no official process exists, the switcher can safely clear its pending/receipt metadata without guessing which process had which role.

A clearly dead stale receipt may be removed automatically when there is no pending uncertainty. A live mismatched process is never terminated or adopted.

## Second Account reset

The reset flow is intentionally non-destructive and conservative.

It is enabled only when:

- every official ChatGPT process is closed;
- Second is stopped;
- no pending marker exists;
- no ownership receipt remains.

The switcher then atomically renames the entire `Profiles/b` directory into `Profiles/Archived/<unique-name>` without reading the contents. The next launch creates a fresh `b` directory.

Requiring every official process to be closed avoids archiving a directory that might still be in use by an orphaned process after metadata loss.

## Legacy migration and settings schema

Older builds treated both A and B as isolated profiles. New builds discard A process receipts and A pending markers because A now means Current/default.

Migration is metadata-only. Legacy A directories are deliberately left on disk and their contents are not read. Valid B metadata is retained. Duplicate B ownership receipts are treated as invalid metadata rather than guessed through.

Settings have an explicit schema version and tolerant decoder:

- older schemas may be upgraded using known defaults;
- settings from a **future/newer schema** cause startup to stop rather than silently rewriting/downgrading unknown fields.

## Private filesystem storage

Switcher metadata and isolated Second directories use restrictive POSIX permissions. Metadata reads/writes reject unsafe names, symlinks/hardlinks and oversized metadata. Atomic replacement is used for metadata writes.

The controller lock prevents two switcher controllers from concurrently managing the same private root.

`PrivateStore` exposes private-profile preparation only for Second. Requests to create a private Current profile are rejected.

These defenses reduce accidental/cross-process corruption but are not a defense against a fully malicious process running with the same macOS user privileges.

## Graceful termination only

The switcher calls the normal application termination request only for a verified Second process. It waits for graceful exit and cancels restart after timeout. It never escalates to a forced kill.

Current must be quit/restarted from the official ChatGPT app itself.

## Logging and diagnostics

Logs are bounded and memory-only. Diagnostic output contains switcher state, app/compatibility metadata, process status and private-root location.

It must not contain:

- account email/name/identity discovered from ChatGPT;
- auth tokens;
- cookies/browser stores;
- Keychain credential values;
- ChatGPT application logs;
- another process's environment or command-line arguments.

`Copy Diagnostics` copies only this switcher-generated text.

## Source policy audit

`scripts/audit.py` rejects source patterns associated with:

- networking;
- credential APIs/files;
- process environment/argv inspection;
- shell/subprocess execution;
- privileged/destructive process APIs;
- Dock/app mutation tricks;
- creating switcher-private Current storage;
- creating a Current ownership receipt.

The audit intentionally does not scan tests for the last two patterns because migration tests must construct legacy A metadata to prove it is rejected safely.

The audit is a guardrail, not a formal security proof. Human review, unit tests, app-signature validation and runtime smoke validation remain separate layers.

## Threats deliberately not solved

The switcher does not attempt to defend against:

- malware or a malicious account with the same macOS user privileges;
- the official app intentionally reading shared OS resources;
- browser OAuth choosing the wrong browser account;
- upstream changes that defeat isolation despite retaining static markers;
- compromise of the user's macOS account;
- manually deleted/corrupted switcher metadata while an isolated process remains alive;
- a malicious replacement application explicitly approved by the user outside the intended workflow.

Users should verify the displayed ChatGPT account before sensitive work, especially immediately after signing in or after an app update.

## Reporting

Use [GitHub private vulnerability reporting](https://github.com/isaacstg/pairbar-codex/security/advisories/new) for a suspected security vulnerability. Include the switcher version, official app version, reproduction steps, and expected versus observed behavior. If the private reporting form is unavailable, do not publish sensitive details in an issue; wait until a private channel is available.

Do not include real authentication tokens, cookies, account exports or other secrets in bug reports. Prefer the switcher's generated diagnostics and a description of the observed behavior.
