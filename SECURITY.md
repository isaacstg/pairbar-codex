# Pairbar security model

## Scope

Pairbar provides profile separation inside one macOS user. It is not an operating-system security sandbox and does not claim to protect one account from malicious software running as the same user.

The security model distinguishes three facts:

1. **Official app identity**: the selected bundle has the expected identifier, Team ID, executable, and valid signature.
2. **Pairbar process ownership**: live kernel identity exactly matches a durable receipt created for a specific managed profile launch.
3. **Runtime account isolation**: the official app actually kept signed-in account, Chat, Code, secure storage, links, and other state separate.

The first two can be checked by Pairbar. They do not prove the third. Runtime isolation requires provider- and version-specific acceptance tests.

## Trust and ownership roles

### Current

Each provider has one Current entry. Current uses the provider's ordinary app storage and launch behavior. Pairbar may verify the app, enumerate conservative candidates, open it normally, or focus it. Pairbar never:

- creates private storage or an ownership receipt for Current;
- launches Current with managed-profile overrides;
- closes, restarts, resets, archives, or recovers Current;
- treats an uncertain managed process as Current.

### Managed profile

A managed profile is an additional Pairbar metadata record with an immutable storage locator and generation. Managed Codex profiles receive separate Electron storage and `CODEX_HOME`. Pairbar may focus, gracefully close, restart, archive, or reset one only while the relevant safety preconditions hold.

The model imposes no limit on saved profile records. It does not promise unlimited live processes. Pairbar opens only concrete targets selected by the user or individually opted into the separately enabled login-launch setting.

### Claude boundary

The official Claude.app may be represented as normal Current after verification of bundle identifier `com.anthropic.claudefordesktop`, expected Team ID `Q6L2SF6YDW`, signature, and executable.

Managed Claude profiles are disabled. Packaged references to `CLAUDE_USER_DATA_DIR`, `CLAUDE_CONFIG_DIR`, or `CLAUDE_SECURESTORAGE_CONFIG_DIR` are static evidence only. Packaged behavior that deletes an override or disables local pairing under relocated user data increases uncertainty. Pairbar does not bypass those behaviors, invoke an internal test harness, patch the app, or claim they provide isolation.

Chat and Code require real signed-in separation evidence before managed Claude can be enabled. Cowork requires its own assessment because cloud execution, local VM storage, permissions, configuration, and transitions with Chat may cross boundaries that a Chat-only test does not exercise.

## Security invariants

1. Official `ChatGPT.app` and `Claude.app` bundles are never modified, patched, copied, injected into, replaced, or re-signed.
2. Each Current account uses normal provider storage and receives no Pairbar receipt or profile override.
3. Every additional Codex profile has distinct Pairbar-managed Electron storage and `CODEX_HOME`.
4. Authentication tokens, cookies, browser stores, account identities, Keychain credentials, provider logs, and profile contents are never copied, parsed, migrated, or inspected.
5. Pairbar never inspects another process's arguments or environment.
6. Pairbar has no networking, telemetry, or automatic updater.
7. Pairbar does not execute a shell or subprocess to control a provider app.
8. Current is never destructively controlled.
9. A managed lifecycle action requires positive ownership; ambiguity and unreadable observations fail closed.
10. Pairbar requests graceful termination only and never force-kills a provider process.
11. A PID, bundle identifier, signature, receipt, or static compatibility fingerprint alone is insufficient evidence of safe managed control or runtime account isolation.
12. New managed launches persist pending intent before invoking LaunchServices and retain conservative state after interruption.
13. Archive/reset moves opaque storage into an archive and never immediately deletes profile data.
14. Existing Current + Second data migrates through Pairbar metadata only; profile contents are not read.
15. Diagnostics and exports omit credentials and operational identifiers that are unnecessary for the user-facing purpose.
16. Managed Claude remains unavailable until the external acceptance gate passes.

## Provider and Current discovery

Pairbar enumerates applications with the provider's expected official bundle identifier. It does not inspect credentials or profile contents to identify an account.

For each managed receipt, Pairbar obtains a typed kernel observation:

- **verified** contains a stable PID, UID, start time, and executable snapshot that also corresponds to an enumerated official app at the checked bundle path;
- **absent** means the kernel reports that process no longer exists;
- **unreadable** means absence or identity could not be established safely.

Only a managed process with a receipt that exactly owns its verified observation can be excluded from Current candidates. Unknown, duplicate, mismatched, pending, orphaned, or unreadable managed state blocks Current classification.

After positively excluding every owned managed process:

- no candidate means Current is stopped;
- one candidate may be treated as Current;
- more than one candidate is ambiguous and Pairbar refuses to choose.

Opening Current verifies official identity and uses no profile override. If managed processes already exist, LaunchServices is asked for a new normal instance. Pairbar then re-resolves provider state and focuses the returned process only if it is classified as Current and is not referenced by a managed receipt.

## Managed Codex storage and launch

New Codex profiles use opaque generated directories below Pairbar's historical application-support root. The migrated Second profile retains:

```text
~/Library/Application Support/Codex Dual Account Switcher/Profiles/b/
```

A managed Codex launch receives an allowlisted base environment plus only the required profile values:

```text
CODEX_HOME=<profile>/codex
CODEX_ELECTRON_USER_DATA_PATH=<profile>/electron
--user-data-dir=<profile>/electron
```

Pairbar does not forward arbitrary inherited variables. In particular, it does not intentionally forward API keys, token variables, `NODE_OPTIONS`, `DYLD_*`, or Electron debugging variables.

Before a stopped managed profile opens, Pairbar requires:

- a stopped, non-archived record with no provider recovery uncertainty;
- acceptable memory pressure or a one-time explicit override;
- a fresh official-app identity and compatibility inspection;
- a fingerprint equal to the explicitly approved build;
- prepared private directories that pass ownership, permission, and path checks.

The launch sequence is:

1. save a profile-specific pending marker with launch ID, time, policy, and fingerprint;
2. ask LaunchServices for a new official app instance;
3. require a new PID with a stable current-user kernel snapshot after the recorded intent and the exact checked executable;
4. save a profile- and storage-generation-specific receipt;
5. re-inspect the official app and verify its fingerprint did not change during launch;
6. clear pending state last;
7. re-resolve state before focusing.

A failure after step 1 intentionally leaves evidence requiring recovery.

## Process ownership

A receipt contains Pairbar-owned metadata only:

- provider and managed profile identifier;
- immutable storage generation;
- launch identifier and policy version;
- PID, current macOS UID, kernel start time, and exact executable path;
- expected private Electron and Codex paths;
- expected bundle identifier, Team ID, and approved fingerprint where applicable;
- provenance indicating a runtime or migrated legacy receipt.

Ownership requires the entire receipt to match the current profile record, validated paths, current user, installed identity, and a stable live process observation. Duplicate PIDs, profile identifiers, storage paths, or active receipts invalidate metadata rather than being guessed through.

A receipt proves Pairbar's launch provenance and the current identity of that process. It does not expose or prove the account signed into the app, and Pairbar never reads account data to strengthen the claim.

## Graceful lifecycle control

Pairbar activates a managed process only after rechecking ownership and official identity. Close and restart additionally serialize lifecycle work for the provider, preventing overlapping operations from reusing stale state.

Close sends the normal application termination request to the exact verified process and waits for its absence. Timeout, identity change, or an unreadable observation preserves the receipt and cancels the operation. Pairbar never escalates to a forced kill.

Restart proves that the app is still compatible and safe to reopen before closing anything. It then completes the verified close before starting the ordinary managed launch sequence. Current is never involved.

## Interrupted launches and recovery

Pending state blocks another launch. Recovery follows two conservative paths:

1. A live process may be adopted only when the pending launch, receipt or new-process evidence, provider identity, storage generation, launch ID, policy, exact executable, and unchanged approved fingerprint all match.
2. Otherwise, the user must manually close every official process for that provider. Pairbar obtains fresh provider-wide quiescence immediately before changing pending/receipt or archive metadata.

Quiescence evidence is short-lived and must report zero official processes and no unverifiable process. It is insufficient if any active profile has a receipt or pending marker, an archive journal is outstanding, or unexplained provider storage exists.

A definitely absent stale receipt may be cleared only when no pending or other recovery uncertainty remains. A live mismatch is neither adopted nor terminated.

## Archive and reset

Archive is a journaled, non-deleting transition:

1. validate the record and fresh provider-wide quiescence;
2. persist an operation containing only the expected before/after metadata;
3. atomically rename the whole validated profile directory into `Profiles/Archived` without reading its contents;
4. sync the affected parent directories;
5. persist the archived or reset profile record;
6. remove the operation journal.

Recovery accepts only the exact before or after record and the expected source/destination configuration. It cannot turn an arbitrary metadata edit into a filesystem move.

Reset assigns a new storage locator and generation after archiving the old data. Archiving removes the record from the active UI. Pairbar does not permanently delete either directory.

## Migration and schema handling

Migration from the fixed Current + Second model reads only Pairbar-owned metadata and filesystem entry metadata needed to retain the legacy directory. It does not open files inside profile storage.

- Current remains ordinary and receives no migrated ownership.
- Safe legacy Second metadata maps to the fixed legacy managed profile identifier and `Profiles/b` locator.
- Legacy Current receipts and pending markers are discarded.
- Original metadata bytes are retained in a migration backup area.
- Migration writes an intent journal before schema-3 records and removes it only after validation.
- A future schema blocks startup rather than being silently rewritten.

## Private filesystem storage

The store pins and validates its root, uses a controller lock, and resolves internal metadata paths relative to validated directory descriptors. Metadata operations reject unsafe names, traversal, symbolic links, hard links, unexpected file types, wrong ownership, permissive modes, oversized files, duplicate identifiers, and unstable directory enumeration.

Writes use mode-0600 temporary files, synchronization, atomic rename, and parent-directory synchronization. Directories are mode 0700. These defenses limit accidents and same-user races; they are not a defense against a fully malicious process with the same macOS user privileges.

Each metadata record is bounded to 64 KiB. The number of valid profile records is not artificially capped.

## Startup and memory pressure

Starting Pairbar at login and opening selected profiles are separate, opt-in settings that default off. Each row also has an individual selection. Login handling enumerates only those concrete targets and never means “open all profiles.” Every ordinary safety check still applies.

Memory pressure can warn or block a new or automatic opening. It never causes Pairbar to terminate an existing provider process.

## Diagnostics, export, and preview

Diagnostics are bounded and generated from Pairbar state. They may include version, schema, aggregate provider states, recovery flags, login-item state, and event codes. They exclude profile display names, paths, PIDs, fingerprints, receipts, account identity, credentials, cookies, provider logs, and another process's arguments or environment.

Configuration export contains display and preference data only: language, labels, favorites, order, shortcut, and login selection. It excludes IDs, storage locators, paths, process data, receipts, pending markers, archive journals, fingerprints, and profile contents.

Preview mode uses fixed in-memory examples. It disables account, process, storage, login-item, export, and lifecycle actions and must not acquire the production controller lock or inspect installed official apps.

## Source policy audit

`scripts/audit.py` is intended to reject source patterns associated with networking, credential/keychain/browser-store access, process argument or environment inspection, shell/subprocess control, privileged or forced termination, mutation of official apps, private Current storage, and Current receipts.

The audit is a guardrail, not a formal proof. Pure tests, adversarial review, strict signature validation, fake-runtime integration tests, disposable live tests, and signed-in acceptance are separate layers.

For Pairbar 2.0.0 (17), the integrated source-policy audit and all 128 Swift tests passed, and a freshly extracted ad-hoc hardened-runtime bundle passed strict all-architectures signature verification. The read-only installed ChatGPT check passed for `26.915.31945 (9922)` with reported fingerprint `d87b…eacc1a`. These results support source, policy, and static app-compatibility claims only. No final live/signed-in isolation test was run, the installed Claude check was not run, and the artifact is neither Developer ID signed nor notarized.

## Threats deliberately not solved

Pairbar does not attempt to defend against:

- malware or a malicious process running with the same macOS user privileges;
- an official app reading shared operating-system resources;
- browser OAuth selecting an unintended browser account;
- upstream behavior that ignores or partially honors profile overrides while retaining static markers;
- compromise of the user's macOS account;
- manual corruption or deletion of Pairbar metadata while a managed process is alive;
- denial of service through memory or process exhaustion;
- Claude Chat, Code, or Cowork crossover before their acceptance gate passes.

Users must verify the account shown by the official app before sensitive work, especially after initial sign-in or an app update.

## Reporting

Use [GitHub private vulnerability reporting](https://github.com/isaacstg/pairbar-codex/security/advisories/new) for suspected vulnerabilities. Include Pairbar version, provider app/version, safe reproduction steps, and expected versus observed behavior. Never include authentication tokens, cookies, account exports, profile storage, Keychain data, or other secrets. Prefer Pairbar's redacted diagnostics.
