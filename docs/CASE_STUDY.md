# Pairbar: designing a conservative native account switcher

**Role:** product direction and implementation ownership — Isaac / [isaacstg](https://github.com/isaacstg). Developed with AI-assisted implementation, code review, and Mac validation.

**Stack:** Swift 5.9+, AppKit, SwiftUI, LaunchServices, Carbon hotkeys, Darwin process identity, Swift Package Manager, XCTest, GitHub Actions.

## The problem

A user who already has a working ChatGPT/Codex login wants a second account open at the same time. Repeated sign-outs interrupt work. Copying credentials introduces a different class of risk. A switcher should preserve the ordinary app and keep its own responsibilities small.

Pairbar adds one isolated instance around the existing official app. The everyday interaction is two shortcuts and Open Both.

## Decisions that shaped the product

### Preserve the existing account

Current uses normal Electron storage and `~/.codex`; the switcher never owns its lifecycle. Second alone receives private storage and a switcher-created process receipt. This asymmetric model makes uninstall and upgrade easier to explain and reduces accidental control of an existing session.

### Prefer blocked actions to uncertain ownership

A PID can be reused. A signed app can have been launched with a different profile. Pairbar therefore checks user ID, kernel start time, executable path, and expected private paths against its launch receipt. Only a verified Second PID is excluded from Current discovery. Multiple candidates or an interrupted Second launch produce a needs-attention state.

### Persist uncertainty before launching

The switcher writes pending metadata before LaunchServices creates Second. It verifies the returned process, persists the receipt, then rechecks the installed app fingerprint before clearing the pending marker. A crash or updater race leaves conservative recovery state rather than permitting another speculative launch.

### Make technical safeguards understandable

The first menu exposed too many actions and detached settings windows were difficult to find. Version 1.3 moved routine UI into one menu-bar popover. Two cards handle everyday use; Second's lifecycle actions appear only in its More menu. Settings says Set Up Second Account or Confirm ChatGPT Update instead of asking users to understand a fingerprint. Save Names has a separate metadata-only path that cannot approve a build.

## Verification and evidence

- 47 policy/storage/migration tests, including PID reuse rejection, legacy A ownership rejection, future-schema downgrade protection, and label changes preserving approval.
- Source audit that rejects network/credential access, argv/environment inspection, shell process control, force kills, Dock mutation, and private Current ownership/storage patterns.
- macOS 14/15 CI builds, strict bundle verification, SHA-pinned official Actions, artifact checksums, and build provenance.
- Live disposable Current + Second smoke validation: separate storage initialization, coexistence, graceful Second termination, and preservation of the pre-existing Current process.
- Installed 1.3 upgrade and native UI checks, including opening Second and repeated Open Both without duplicate processes.

See [VALIDATION.md](../VALIDATION.md) for exact evidence and unperformed acceptance cases. Test counts and static markers are not proof of OAuth/session isolation.

## Limits and next steps

The official app's isolation behavior can change. Both instances share one macOS user's permissions; this is not an OS security boundary. No account identities or usage limits are scraped. The project has no notarized binary release yet.

The next useful work is acceptance coverage, shortcut customization, localization, and signed/notarized distribution. [The roadmap](UX_IMPROVEMENT_PLAN.md) distinguishes proposals from shipped features.

## Explore the implementation

- [Pure state resolver](../Sources/SwitcherCore/AccountState.swift)
- [Ownership and launch model](../Sources/SwitcherCore/Model.swift)
- [Filesystem protections](../Sources/SwitcherCore/PrivateStore.swift)
- [Controller orchestration](../Sources/DualAccountSwitcher/Controller.swift)
- [Native popover](../Sources/DualAccountSwitcher/Views.swift)
- [Security model](../SECURITY.md)

Pairbar 1.3.2 uses the same name in its native interface and app bundle. Compatibility-sensitive identifiers and storage paths remain stable across the rename.
