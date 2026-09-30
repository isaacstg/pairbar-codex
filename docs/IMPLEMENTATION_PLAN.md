# v1 Implementation & Orchestration Plan

## Product invariant

The user's existing ChatGPT/Codex installation is the primary account and remains normal and untouched. The switcher adds a secondary isolated account around it.

- **Current account (A):** normal official ChatGPT storage and normal `~/.codex`; discover/focus/launch only. Never copy, parse, migrate, or manage credentials. Never destructively control an ambiguous default instance.
- **Second account (B):** isolated Electron user data and isolated `CODEX_HOME`; strongly owned by verified launch receipts and safe to focus/quit/restart when ownership is proven.
- Never modify `ChatGPT.app`, scrape Keychain/browser/auth data, inspect another process's argv/environment, execute shell commands for process control, or force-kill ChatGPT.

## Phase 0 — Baseline and repair

1. Inspect repository head and recent commits, especially the partial A=current/B=isolated migration.
2. Make the model internally consistent: only B has isolated `ProfilePaths`; A has no private profile directory requirement.
3. Migrate old metadata: discard legacy A ownership receipts/pending markers without deleting legacy profile data; retain valid B metadata.
4. Establish explicit versioned metadata so future migrations are deterministic.

**Exit criteria:** old installs start safely; A is never treated as a switcher-owned isolated process; B ownership still validates.

## Phase 1 — State architecture

Replace stringly/scattered state with explicit domain types.

Suggested states:

- Current account: `.stopped`, `.running(pid)`, `.ambiguous(count)`, `.launching`, `.compatibilityBlocked(reason)`.
- Second account: `.stopped`, `.launching`, `.runningVerified(pid)`, `.quitting`, `.ownershipUncertain`, `.unverifiedLiveProcess`, `.compatibilityBlocked(reason)`.

Introduce services/protocols so logic is testable without launching real apps:

- `RunningApplicationProviding`
- `ProcessIdentityProviding`
- `OfficialAppLaunching`
- `CompatibilityChecking`
- `SwitcherMetadataStore`
- `AccountStateResolver`

Current-account resolution algorithm:

1. Enumerate official `com.openai.codex` applications.
2. Positively identify verified B from its receipt.
3. Exclude only that proven B process.
4. 0 remaining => stopped; 1 => current account candidate; >1 => ambiguous.
5. Never choose among multiple candidates.

Secondary resolution algorithm:

1. Read B receipt.
2. Verify PID + UID + process start time + exact official executable path + stored B paths.
3. Reject PID reuse, stale receipt, wrong UID/executable/path.
4. If a process is live at recorded PID but identity does not match, block destructive actions.

## Phase 2 — Launch/focus semantics

### Current account

`Open / Focus`:
- one resolved default process => activate it;
- none => launch the official app without explicit profile overrides, then re-resolve; Pairbar removes its own inherited managed Codex storage overrides at startup, while external custom values remain;
- multiple => show actionable ambiguity message; never guess.

No switcher-owned Quit/Restart for Current account. The official app remains responsible for its lifecycle.

### Second account

Launch a new official application instance with:

- `--user-data-dir=<private>/Profiles/b/electron`
- `CODEX_HOME=<private>/Profiles/b/codex`
- `CODEX_ELECTRON_USER_DATA_PATH=<private>/Profiles/b/electron`

Explicitly provide the managed profile's required launch variables. LaunchServices may retain other inherited variables. Persist launch intent before launch, then verify the returned process before persisting ownership. Keep graceful terminate with timeout; never force kill.

### Open Both

Resolve/focus Current first, then resolve/focus Secondary. Calls must be idempotent and serialized per account so repeated menu/hotkey presses do not create duplicate launches.

## Phase 3 — Crash/recovery and metadata

- Version settings/receipts/pending-launch metadata.
- Atomic writes with existing symlink/hardlink defenses and restrictive permissions.
- On startup, reconcile stale receipts without touching account data.
- Automatically clear a B receipt when its exact process is demonstrably gone.
- Preserve uncertainty when a launch may have succeeded but cannot be proven.
- Provide a safe recovery action that never requires deleting profile data.
- Legacy isolated-A directories remain untouched and can be manually removed later.

## Phase 4 — Compatibility/update gate

Keep OpenAI signature validation, expected bundle identity/team validation, marker detection and fingerprinting.

Refine policy:
- unchanged fingerprint => launch normally;
- changed but statically compatible build => explain update and allow explicit approval;
- missing required B-isolation capability/signature mismatch => block B launch;
- Current account should remain launchable normally where safe because it does not depend on isolation overrides.

Never silently weaken the B compatibility gate.

## Phase 5 — UX redesign

Replace A/B implementation terminology in normal UI with:

- **Current account** — Existing ChatGPT profile
- **Second account** — Isolated profile

Menu target:

```
Codex Account Switcher

● Current account — Running / Not running / Needs attention
  Open / Focus                         ⌥⌘1

● Second account — Running / Not running / Needs attention
  Open / Focus                         ⌥⌘2
  Restart…
  Quit…

Open Both
────────────
Settings…
Diagnostics…
Quit Switcher
```

First run should explain one invariant in plain language: existing ChatGPT remains untouched; only the second account gets separate storage. Automatically locate `/Applications/ChatGPT.app` when valid. The principal user action should be `Open Second Account & Sign In`.

Settings:
- account display names;
- shortcuts (initially retain ⌥⌘1/2; custom shortcuts only if robustly implementable);
- startup at login;
- official app location;
- compatibility approval/status.

## Phase 6 — Diagnostics and recovery UX

Diagnostics may show:
- switcher version;
- macOS version;
- official app path/version/build/fingerprint/signature status;
- Current state and candidate count/PID where unambiguous;
- Secondary verified PID/status;
- private secondary root;
- pending/recovery state;
- bounded switcher-owned logs.

Never show/read account identity, email, auth tokens, cookies, Keychain data, official app logs, or another process's environment/arguments.

Add `Copy Diagnostics` and clear recovery instructions. Add `Reset Second Account…` only with explicit confirmation; default uninstall preserves account data.

## Phase 7 — Test matrix

Unit/state tests:
- Current absent;
- Current already running;
- exactly one default after excluding verified B;
- multiple default candidates => ambiguous;
- B stopped/running verified;
- stale B PID;
- PID reuse;
- wrong UID/executable/start time/profile paths;
- B launch while Current exists;
- Current launch while B exists;
- both already running;
- switcher restart with both alive;
- legacy A receipt migration;
- legacy A pending marker migration;
- corrupted/duplicate receipts;
- concurrent ⌥⌘1 presses;
- concurrent ⌥⌘2 presses;
- concurrent Open Both;
- repeated Open Both idempotence;
- interrupted B launch;
- launch completion callback racing timeout;
- ChatGPT fingerprint update;
- incompatible updated app;
- settings/metadata symlink and hardlink attacks;
- permissions and controller lock contention.

Static security audit must continue rejecting networking/credential access/token-file access/process-env inspection/shell execution/force-kill patterns.

## Phase 8 — Refactor

Split the oversized controller after behavior is covered by tests:

- `AccountStateResolver.swift`
- `OfficialAppLauncher.swift`
- `SecondaryOwnership.swift`
- `MetadataMigration.swift`
- `Controller.swift` as orchestration/UI state only

Keep security-sensitive primitives in `SwitcherCore` where practical.

## Phase 9 — CI/release

CI on supported macOS runners:
1. source/security audit;
2. shell/plist validation;
3. Swift unit tests;
4. release build;
5. app-bundle validation/signature check suitable for CI;
6. archive artifact.

Local release validation additionally performs the real installed-app compatibility check and opt-in two-instance smoke test. Never claim CI proves account isolation.

Release packaging remains staged outside sync-prone folders and strips resource-fork/xattr metadata. Personal builds may be ad-hoc signed; public distribution requires Developer ID + notarization.

## Phase 10 — Documentation

Rewrite README around Current + Second account rather than symmetric profiles. Update `SECURITY.md` threat model and `VALIDATION.md` with exact tested build/environment and distinction between static, unit, and live smoke validation.

## Deferred power-user features

Only after v1 is stable:
- 3+ isolated accounts;
- customizable shortcuts;
- account/project quick actions;
- optional richer menu labels.

Do not identify accounts by scraping UI, credentials, browser state, or private stores.

## Orchestration / progress protocol

Implementation should be committed in coherent milestones rather than one giant commit. For each phase:

1. inspect affected code and invariants;
2. add/adjust tests first where practical;
3. implement;
4. run focused tests;
5. run full test + audit before milestone completion;
6. update `docs/IMPLEMENTATION_STATUS.md` with commit SHA, completed items, validation actually performed, failures/risks and next phase.

A phase is not marked complete merely because code was written. Validation evidence is required.
