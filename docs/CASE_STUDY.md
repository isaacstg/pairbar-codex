# Pairbar: designing a conservative multi-profile switcher

**Role:** product direction and implementation ownership — Isaac / [isaacstg](https://github.com/isaacstg). Developed with AI-assisted implementation, adversarial review, and Mac validation.

**Stack:** Swift 5.9+, AppKit, SwiftUI, LaunchServices, Carbon hotkeys, Darwin process identity, Swift Package Manager, XCTest, and GitHub Actions.

## The problem

People who work across several ChatGPT/Codex accounts lose context when they repeatedly sign out. Copying authentication material would create a worse trust model, and controlling an already-running official app by guesswork could close the wrong work.

The original Pairbar solved one narrow case: one ordinary Current account plus one isolated Second account. Pairbar 2 generalizes that design without weakening its asymmetric safety boundary. Each provider keeps one untouched Current account, while additional Codex profiles receive independent storage and can be controlled only when Pairbar proves ownership.

The product does not impose a limit on how many profiles can be saved. That is a data-model capability, not a promise that arbitrary numbers of Electron processes can stay open. Users choose the profiles to launch, and memory pressure affects new openings without disturbing existing sessions.

## Product decisions

### Current remains ordinary

Every provider has one Current entry. It uses the official app's normal storage and receives no Pairbar launch override. Pairbar can verify, open, and focus Current; it never creates a receipt for it and never closes, restarts, archives, or resets it.

This property makes uninstall and provider updates easier to reason about. It also prevents “Current” from quietly becoming another Pairbar-managed profile.

### Profiles are dynamic metadata, not fixed slots

Pairbar 2 replaces the A/B product model with provider records and per-profile records. A managed record carries a generated identifier, display metadata, an immutable storage locator and generation, and optional pending/receipt state. Names, favorites, ordering, shortcuts, and login choices remain metadata; none are used as paths or proof of ownership.

Each record is bounded in size, while the store has no artificial count ceiling. Metadata is written atomically through descriptor-relative filesystem operations with owner, mode, type, link-count, and path checks.

### Ownership is stronger than a PID

A PID is reusable and reveals nothing about the profile selected inside an Electron app. Pairbar combines a kernel process snapshot with provider, profile, storage generation, launch ID, current user, exact executable, expected private paths, app identity, approved fingerprint, and launch-policy version. Unknown or unreadable observations are different from “absent.”

This receipt still proves only that Pairbar launched and can identify that process. It does not prove that the official app honored every profile override. Runtime signed-in isolation is a separate acceptance gate.

### Intent is durable before launch

Pairbar writes a pending launch before asking LaunchServices to create a managed instance. After launch it identifies a newly created process, saves its receipt, rechecks the app build, and clears the pending marker last. A crash at any point leaves a conservative state that blocks another speculative launch.

Recovery can adopt only a process that matches all durable intent and live identity checks. Otherwise the user closes every official process for that provider manually, and Pairbar rechecks quiescence before changing metadata.

### Reset means archive

Immediate deletion would turn one classification bug into data loss. Pairbar writes an archive operation, atomically moves the opaque profile directory to an archive area, and only then commits the new record state. Reset creates a fresh storage generation while retaining the archived directory. Pairbar never reads profile contents during migration or archival.

### Migration preserves the old Second profile opaquely

Current + Second installations are mapped into the dynamic schema without inspecting their account data. Current remains normal. The old `Profiles/b` directory becomes the legacy managed Codex profile, and its safe Pairbar metadata is retained. Legacy A profile contents are left alone; receipts and pending state that could imply Pairbar ownership of Current are discarded.

### Provider support is capability-gated

The provider model includes Codex and Claude, but capability is intentionally asymmetric. The official Claude.app can have a normal Current entry after identity verification. Managed Claude profiles are compiled unavailable.

Read-only inspection of the installed Claude bundle found packaged references to `CLAUDE_USER_DATA_DIR`, `CLAUDE_CONFIG_DIR`, and `CLAUDE_SECURESTORAGE_CONFIG_DIR`. It also found production behavior that removes an override and disables local pairing in relocated-data situations. Neither finding proves how Chat, Code, secure storage, OAuth, extensions, deep links, or Cowork behave across real signed-in profiles.

The release gate therefore requires repeatable Chat and Code separation with no crossover. Cowork has a distinct gate because it includes cloud execution, local VM behavior, shared configuration, and transitions with Chat. Until that evidence exists, the UI says unavailable and contains no managed Claude launch path.

### The interface scales without becoming a windowed manager

Pairbar remains a menu-bar app with one native popover. Favorites keep common entries near the top; search and Codex/Claude filters handle larger lists; explicit multi-select opens only chosen profiles; configurable shortcuts provide direct access. Creation, editing, lifecycle controls, recovery, diagnostics, export, and startup choices remain in the popover.

Startup is deliberately two-stage. Starting Pairbar at login and opening selected profiles are separate options, both off by default. Each profile must also be individually selected. Pairbar never translates “start at login” into “open every saved profile.”

English and Spanish strings, keyboard navigation, accessible names, native confirmation dialogs, and an inert preview mode keep the same interface reviewable without touching live account state.

## Security architecture

Pairbar contains no network client, telemetry, updater, credential reader, token copier, Keychain integration, or inspection of another process's arguments or environment. It never patches or re-signs an official provider app. Launches use LaunchServices and an allowlisted environment; termination is graceful and limited to a receipt-owned managed process.

The dynamic state resolver is pure. It combines durable records, observed official processes, verified kernel snapshots, in-flight controller state, archive journals, and unexplained storage into provider-wide state. One uncertain managed profile can block Current classification because a visible official process might actually be an orphaned managed launch.

Diagnostics use bounded event codes and aggregate state. Configuration export includes display preferences but excludes IDs, paths, PIDs, receipts, fingerprints, journals, and profile contents.

## Evidence and honest limits

Before Pairbar 2 work began, the consolidated 1.3.3 baseline passed 47 tests, the source-policy audit, release compilation, and local ad-hoc bundle verification. Earlier disposable Current + Second smoke tests established that the legacy mechanism could initialize separate storage and preserve Current. Those results remain historical rather than evidence for the dynamic architecture.

The audited Pairbar 2 source passed 131 Swift tests, including dynamic storage/state, fake-runtime controller, suspended-inspection ownership, memory-pressure behavior, independent batch failures, synthetic Claude, explicit Claude lifecycle/archive denial, and panel-model suites. The source audit, diff/plist/shell checks, release build, ZIP integrity, fresh extraction, and strict all-architectures signature verification also passed. The 2.0.0 (17) development archive has SHA-256 `3fb1070595328e5ae6d296da77c75222fff50ce4e65d4aefce681ab6bd893c12` and an ad-hoc hardened-runtime signature.

The earlier implementation pass recorded a successful static inspection of ChatGPT `26.915.31945 (9922)`. During the audit, strict read-only checks of that installed ChatGPT version and Claude `1.34493.1` both failed because macOS reported modified signatures; Pairbar blocked both and left the bundles untouched. The inert native preview rendered and exposed its accessibility labels. No smoke, live lifecycle, signed-in isolation, login-item, keyboard, or VoiceOver test was performed, which preserved the Second Account hosting development. Those cases remain prepared for Current or new disposable profiles on a safe user or machine.

The ad-hoc archive is not represented as Developer ID signed, notarized, or published. The ChatGPT static result and synthetic Claude fixtures are not represented as runtime session isolation.

## Explore the implementation

- [Dynamic profile model](../Sources/SwitcherCore/Dynamic/Models.swift)
- [Dynamic state resolver](../Sources/SwitcherCore/Dynamic/StateResolver.swift)
- [Metadata and archive store](../Sources/SwitcherCore/Dynamic/DynamicStore.swift)
- [Provider runtime](../Sources/DualAccountSwitcher/ProviderRuntime.swift)
- [Controller orchestration](../Sources/DualAccountSwitcher/PairbarController.swift)
- [Native panel model](../Sources/DualAccountSwitcher/UI/PairbarPanelModel.swift)
- [Claude static compatibility](../Sources/SwitcherCore/Providers/Claude/ClaudeCompatibility.swift)
- [Security model](../SECURITY.md)
- [Claude acceptance protocol](CLAUDE_ACCEPTANCE.md)

Pairbar's implementation is independent. Switchers in the same product category were reviewed for interaction patterns; any code reused in the future must be identified and attributed explicitly.
