# Pairbar user guide

Pairbar installs as `Pairbar.app` from `Pairbar.zip`. The bundle identifier and private storage root remain unchanged, preserving existing labels, setup approval, and Second Account data. When upgrading from Codex Account Switcher, quit only the old switcher and replace its app bundle. If startup at login was enabled, disable it before replacement and enable it again in Pairbar's Settings.

Version 1.3.3 introduces a welcome guide that opens once, even if account setup was completed in an older version. Choose Get Started (or Go to Accounts for existing setup) to continue. Reopen it any time from Help → Quick Start. Completing the welcome never approves a ChatGPT build or changes your saved accounts; any required app confirmation is shown on the Accounts page afterward.

An independent, unofficial native menu-bar utility for keeping **your normal ChatGPT/Codex account** and **one additional isolated account** open at the same time in the official OpenAI macOS app. It is not affiliated with or endorsed by OpenAI.

The project deliberately optimizes for one simple daily workflow:

- **⌥⌘1** → your existing/current ChatGPT account.
- **⌥⌘2** → one additional isolated ChatGPT account.

It does not clone your primary profile or move authentication data around.

## Requirements and availability

- macOS 13 or later. CI builds on macOS 14 and 15; runtime evidence and remaining acceptance cases are recorded in [VALIDATION.md](../VALIDATION.md).
- The official Electron-based OpenAI app named `ChatGPT.app`, with bundle identifier `com.openai.codex`. Other OpenAI desktop apps are not interchangeable with this build.
- Xcode Command Line Tools with Swift 5.9 or later to build from source. There are no third-party package dependencies.

This is a public-source project under the MIT license. There is currently no notarized binary release. Build locally, or use the ad-hoc personal-build artifacts from [GitHub Actions](https://github.com/isaacstg/pairbar-codex/actions). Review the security model before using the utility with sensitive work.

```sh
git clone https://github.com/isaacstg/pairbar-codex.git
cd pairbar-codex
python3 scripts/audit.py
swift test
bash scripts/build.sh
```

Use a checkout in a regular directory, such as your home directory. Filesystem tests create scratch storage under the checkout; macOS symlink locations such as `/tmp` and `/var` are intentionally rejected by the private-storage guard.

## The model

The switcher is intentionally asymmetric:

| | Current Account | Second Account |
|---|---|---|
| ChatGPT storage | Normal/default | Switcher-private isolated directory |
| Codex home | Normal `~/.codex` | Switcher-private `CODEX_HOME` |
| Existing login | Kept as-is | Sign in once separately |
| Switcher may discover/focus/open | Yes | Yes |
| Switcher may quit/restart | **No** | Yes, only with verified ownership |
| Needs isolation fingerprint approval | No | Yes |

Your current installation is not cloned, migrated, rewritten, imported, or replaced. If you remove the switcher, normal ChatGPT continues to use the same profile it used before.

## Daily use

Click the two-person menu-bar icon for a compact popover. Everything lives there, including Settings and Help; there are no detached settings windows or Dock icon.

- **⌥⌘1** — open/focus Current Account.
- **⌥⌘2** — open/focus Second Account.
- **Open Both** — ensure both are open when both states are safe.
- Account cards show your labels and Running, Closed, or Needs attention.
- Second's **More** menu contains graceful quit/restart and is shown only with verified ownership.

Successful switching dismisses the popover. Errors reopen it with an inline explanation. Escape or a click outside dismisses it; Shift-Command-B returns from Settings/Help to Accounts while the switcher is active.

If Current is already open, the switcher focuses it. If it is closed, the official app is opened normally with no profile overrides.

If Second is already running and its ownership is verified, the switcher focuses it. Otherwise it launches a new official app instance with separate Electron and Codex directories.

Repeated shortcut/menu requests are guarded by per-account in-flight state so an already-running launch is not intentionally duplicated.

## First run

1. Put `Pairbar.app` in `/Applications` or `~/Applications`.
2. Open it. It appears in the menu bar and has no Dock icon.
3. The switcher automatically checks the official ChatGPT app, normally `/Applications/ChatGPT.app`. It can also recover the standard `~/Applications/ChatGPT.app` location after verifying OpenAI's signature.
4. Click **Set Up Second Account**. This confirms the checked app version and opens a separate ChatGPT window.
5. Sign into your other account in that window and verify the intended account appears in each window.
6. Optionally use **Settings → Save Names** to rename the cards, for example Personal and Work.

Saving names changes labels only. It never confirms an app version, moves account data, or changes setup status. App location and rechecking are under Settings → App details.

After a ChatGPT update, the switcher checks the new version before a new Second launch. If the setup checks pass, **Confirm ChatGPT Update** explains and confirms the changed version. Confirmation remains explicit; failed checks or pending recovery cannot be bypassed by this action.

Current Account does **not** need the Second Account compatibility fingerprint in order to open. It only needs the selected app to verify as the genuine expected OpenAI app.

Browser OAuth may initially select the browser account most recently used. Choose the intended second account deliberately during sign-in.

## How isolation works

Only Second receives these overrides:

```text
--user-data-dir=~/Library/Application Support/Codex Dual Account Switcher/Profiles/b/electron
CODEX_ELECTRON_USER_DATA_PATH=~/Library/Application Support/Codex Dual Account Switcher/Profiles/b/electron
CODEX_HOME=~/Library/Application Support/Codex Dual Account Switcher/Profiles/b/codex
```

Current receives none of them.

The private directory keeps the historical `Codex Dual Account Switcher` name on purpose so upgrading the application display name does not strand existing Second Account data.

The switcher launches the official app through macOS LaunchServices. It does not patch, copy, re-sign, inject into, or rewrite `ChatGPT.app`.

## Official app identity vs. isolation compatibility

There are two intentionally separate checks:

### Current Account identity check

Before opening Current itself, the switcher verifies the expected official bundle identity/signature and executable. This is enough because Current is launched normally with no isolation overrides.

### Second Account compatibility gate

Before creating a new isolated Second process, the switcher additionally checks the expected Electron profile override and `CODEX_HOME` support and compares the installed build fingerprint with the build you approved.

Therefore an upstream change can block **new Second launches** without unnecessarily blocking normal Current Account use.

## Process safety

Second-account ownership is accepted only when the switcher can verify all of the following switcher-owned metadata:

- recorded role is Second (`b`);
- PID;
- macOS user ID;
- kernel process start time;
- exact official executable path;
- expected private Codex and Electron paths.

PID reuse, wrong users, changed start times, wrong executable paths, wrong private paths, and legacy Current receipts are rejected.

Current is discovered conservatively. The switcher enumerates official ChatGPT application instances and excludes only a **positively verified** Second PID.

- 0 safe default candidates → Current is not running.
- 1 safe default candidate → it may be focused as Current.
- More than 1 → Current is ambiguous; the switcher refuses to guess.
- If Second ownership is uncertain → Current discovery is temporarily blocked too, because an apparent single process could actually be an orphaned Second launch.

Current is never terminated or restarted by the switcher. That lifecycle stays with the official ChatGPT app.

Second quits gracefully. The switcher waits for it to exit and never escalates to a forced kill.

## Crash and interrupted-launch recovery

Before asking macOS to launch Second, the switcher persists a pending marker. It clears that marker only after a new process has been strongly verified, a receipt has been saved, and the official app fingerprint is confirmed not to have changed during the launch.

A pending launch blocks another Second launch.

Recovery has two safe paths:

1. **Verified receipt + still-approved installed build.** If the switcher crashed after saving the exact Second receipt but before clearing the pending marker, recovery can re-check the approved fingerprint and safely restore ownership without closing Current.
2. **No trusted process identity.** If an orphan cannot be proven, recovery requires every official ChatGPT instance to be closed manually. Only then can the switcher conclude no orphan remains and clear ownership/pending metadata.

If the installed ChatGPT build changed while a launch was pending, a valid PID receipt alone is **not** enough to trust the process as isolated. Automatic recovery stays blocked until the risky process situation is manually resolved.

Dead, strongly stale Second receipts can be cleared automatically when no uncertainty marker exists. Isolated account data is not deleted by receipt cleanup.

## Fresh Second Account / reset

Help → Second Account data includes **Archive & Reset** for Second Account.

For maximum safety it is enabled only when:

- every official ChatGPT instance is closed;
- Second has no live/owned process;
- no launch is pending;
- no ownership receipt remains.

Reset does not immediately delete the old profile. It atomically renames the entire `Profiles/b` directory into `Profiles/Archived/...` without inspecting its contents. The next Second launch creates a fresh isolated directory and requires signing in again.

This gives you a recoverable reset rather than a destructive “delete account data” button.

## Upgrading from the original two-isolated-profile build

Older versions created private A and B directories. The new design treats A as Current/default and B as Second/isolated.

On startup:

- legacy A process receipts are discarded;
- legacy A pending markers are discarded;
- legacy A private directories are left untouched;
- valid B metadata is retained;
- duplicate B receipts are rejected rather than guessed through.

Migration reads switcher metadata only. It never imports the contents of the old A profile into Current.

Settings metadata now carries a schema version. Older schemas are upgraded with defaults, while settings written by a **future/newer** switcher version are not silently downgraded and rewritten.

## Privacy and security

The switcher does **not**:

- read, copy, parse, or migrate authentication tokens;
- inspect account emails or identities;
- read cookies, browser stores, Keychain credentials, or ChatGPT logs;
- inspect another process's command-line arguments or environment;
- make network requests;
- modify the official ChatGPT app;
- run shell commands to control ChatGPT;
- force-kill ChatGPT processes;
- create a switcher-private Current Account profile;
- create an ownership receipt for Current Account.

The static source audit also rejects source patterns that would reintroduce private Current storage or Current ownership.

This is **profile separation inside one macOS user account**, not an operating-system security boundary. Both ChatGPT instances still share the permissions and shared OS resources available to that macOS user.

See `SECURITY.md` for the detailed threat model.

## Diagnostics

Help → Troubleshooting details shows switcher-owned state such as:

- switcher version/build and settings schema;
- Current/Second process state;
- approved and last-checked isolation fingerprints;
- official app path;
- Second receipt PID/pending state;
- whether Second/legacy-A private storage exists;
- startup-at-login state;
- bounded in-memory switcher logs.

It deliberately does not collect account identity or authentication data. **Copy Diagnostics** copies only this switcher-generated text.

## Startup at login

Startup at Login is opt-in. It starts the switcher itself, not both ChatGPT accounts automatically.

The option lives in Settings as **Start switcher at login**.

## Uninstall

1. Finish work in Second and quit it from its More menu.
2. Disable Start switcher at login in Settings.
3. Quit the switcher from Help.
4. Move `Pairbar.app` to Trash.

Current ChatGPT is unaffected. Second-account data is preserved by default at:

```text
~/Library/Application Support/Codex Dual Account Switcher
```

Delete that directory manually only if you explicitly want to purge all switcher data and after relevant ChatGPT processes are closed.

## Development

The project is a Swift Package containing:

- `SwitcherCore` — security-sensitive model, settings migration, compatibility, state policy and private storage;
- `DualAccountSwitcher` — native AppKit/SwiftUI menu-bar app (the executable target keeps its historical internal name for compatibility);
- `OfficialAppRuntime` — the small LaunchServices/AppKit mechanism wrapper used by the controller;
- `ProcessIdentity` — minimal Darwin process identity snapshot helper;
- `SwitcherCoreTests` — pure/state/security tests;
- `SwitcherSmokeTest` — explicit opt-in live validation helper.

Repository design/status documents:

- `docs/IMPLEMENTATION_PLAN.md`
- `docs/IMPLEMENTATION_STATUS.md`
- `docs/STATE_MACHINE.md`
- `docs/PUBLIC_RELEASE_CHECKLIST.md`
- `docs/UX_IMPROVEMENT_PLAN.md`
- `VALIDATION.md`

Typical local validation after checking out the repository:

```text
python3 scripts/audit.py
swift test
bash scripts/build.sh
```

The live smoke test is separate and opt-in because it launches a real isolated official app process beside one pre-existing normal Current process. Static/unit tests do not prove runtime account isolation.

## Build artifact

The release script produces:

```text
dist/Pairbar.zip
```

Personal builds and CI artifacts are ad-hoc signed. Public distribution should use an authorized Apple Developer ID and notarization. Do not globally disable Gatekeeper to install this utility.

## Inspiration

The project was inspired by the general idea of multi-account Codex switchers, including `edihasaj/codex-account-switcher`. This implementation is independent and focuses on preserving one normal/default account while isolating only the additional instance.

## License

MIT. See `LICENSE`.

Contributions are welcome; read [CONTRIBUTING.md](../CONTRIBUTING.md) and [CHANGELOG.md](../CHANGELOG.md).
