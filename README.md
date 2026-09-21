<p align="center">
  <img src="docs/brand/banner.svg" alt="Pairbar — perfiles de ChatGPT y Codex desde la barra de menús de macOS." width="100%">
</p>

# Pairbar · account profiles for ChatGPT/Codex on macOS

**Keep each provider's normal Current account. Save additional Codex profiles. Open only the ones you choose.**

[![macOS CI](https://github.com/isaacstg/pairbar-codex/actions/workflows/ci.yml/badge.svg)](https://github.com/isaacstg/pairbar-codex/actions/workflows/ci.yml) [![macOS 13+](https://img.shields.io/badge/macOS-13%2B-111827?logo=apple&logoColor=white)](#build-and-try-it) [![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-F05138?logo=swift&logoColor=white)](Package.swift) [![MIT](https://img.shields.io/badge/license-MIT-69DCC8)](LICENSE)

Pairbar is a native, local-only menu-bar utility for the official macOS apps. The current update keeps one ordinary **Current** account per provider and lets you save any number of additional **ChatGPT/Codex profiles**. It imposes no profile-count limit, but it never opens every saved profile automatically: you choose what to open, and memory-pressure warnings pause unsafe automatic openings.

Each additional Codex profile gets its own Electron storage and `CODEX_HOME`. Pairbar does not swap tokens, copy sessions, read credentials, or modify the official app. It is an independent, unofficial project and is not affiliated with or endorsed by OpenAI or Anthropic.

**[Build and try it](#build-and-try-it) · [User guide](docs/USER_GUIDE.md) · [Security model](SECURITY.md) · [Engineering case study](docs/CASE_STUDY.md)**

> **Development status:** Pairbar's source, automated suite, audit, and local packaging checks are complete. The archive is an ad-hoc development artifact; there is no Developer ID signed, notarized public release. Managed Claude profiles remain disabled until real signed-in tests prove that both Chat and Code are separated without account crossover. Cowork is also unvalidated. See [implementation status](docs/IMPLEMENTATION_STATUS.md).

<p align="center">
  <img src="docs/images/pairbar-profiles.png" alt="Pairbar profiles popover with synthetic preview data" width="46%">
  <img src="docs/images/pairbar-settings.png" alt="Pairbar settings in the inert native preview" width="46%">
</p>

These are real native screenshots from Pairbar's inert preview. All names and states are synthetic; the preview cannot open accounts, change login items, export data, or control provider processes.

## Everyday workflow

- Find profiles by name or filter the list by Codex or Claude.
- Keep frequently used profiles at the top with favorites.
- Open one profile, or select a specific group and open that group.
- Assign configurable global shortcuts to individual profiles.
- Opt individual profiles into opening at login only after enabling the separate global setting. Both settings are off by default.

Pairbar stays in a native popover. It has no permanent window and does not require a Dock icon. Profile creation, editing, ordering, shortcuts, lifecycle controls, diagnostics, recovery, export, and startup preferences remain inside the popover.

## Provider support

| Provider target | Current account | Additional managed profiles |
|---|---|---|
| ChatGPT/Codex | Opens or focuses the official app normally; Pairbar never closes, restarts, or resets it | Implemented with separate Electron storage and `CODEX_HOME`, compatibility approval, per-profile receipts, and conservative recovery |
| Claude.app | Opens or focuses the official app normally after verifying its official identity | **Disabled.** Static inspection is research evidence only; real Chat and Code isolation acceptance has not passed |
| Claude Cowork | Part of the normal Current app only | **Unvalidated.** Cloud, local VM, shared configuration, link routing, and credential boundaries still need explicit acceptance evidence |

“Current” is not a managed profile. It has no Pairbar storage directory or ownership receipt and never receives profile overrides. Pairbar will not use a managed process as Current when identity is uncertain.

## Safety properties

- **Verified ownership.** Managed lifecycle actions require a receipt matching profile, storage generation, PID, user, kernel start time, exact executable, provider identity, and expected private paths.
- **Conservative recovery.** Interrupted launches and unreadable or ambiguous processes block control. Pairbar never guesses ownership and never force-kills an app.
- **Durable intent.** Pairbar records a pending launch before asking LaunchServices to open a managed profile and clears it only after process and app-build checks succeed.
- **Recoverable reset.** Reset and removal archive the profile directory; they do not immediately delete it. Every official process for that provider must be closed before an archive transition.
- **Opaque migration.** Existing Current + Second installations migrate their Pairbar metadata while the contents of `Profiles/b` remain unread. The historical Second storage path is retained.
- **Redacted output.** Diagnostics contain Pairbar state and bounded event codes. Configuration export contains labels and preferences, never paths, receipts, PIDs, fingerprints, journals, account data, or credentials.
- **No switcher networking.** Pairbar contains no network client, telemetry, updater, credential reader, token copier, Keychain access, or inspection of another process's arguments or environment.

This is profile separation within one macOS user, not an operating-system security boundary. The official apps and their upstream behavior determine whether profile overrides provide real session separation. Pairbar therefore treats static compatibility checks as necessary evidence, never as proof of account isolation.

## Build and try it

You need macOS 13 or later, Xcode Command Line Tools with Swift 5.9 or later, and the official Electron-based `ChatGPT.app` with bundle identifier `com.openai.codex` for managed Codex profiles. The optional Claude Current integration expects the official `Claude.app` with bundle identifier `com.anthropic.claudefordesktop` and Team ID `Q6L2SF6YDW`.

```sh
git clone https://github.com/isaacstg/pairbar-codex.git
cd pairbar-codex
python3 scripts/audit.py
swift test
bash scripts/build.sh
```

Use a regular checkout location such as your home directory. Filesystem tests deliberately reject macOS symlink aliases such as `/tmp` and `/var`. The build script creates `dist/Pairbar.zip`; local archives are ad-hoc signed and must not be described as notarized releases. Do not disable Gatekeeper globally.

When upgrading from Codex Account Switcher or Pairbar 1.3.3, keep the existing application-support directory. Pairbar migrates switcher-owned metadata and preserves the legacy Second directory without reading the profile inside it. Review the in-app migration/recovery state before opening a managed profile.

## How managed Codex profiles work

```mermaid
flowchart LR
    P[Pairbar popover] --> CC[Codex Current]
    P --> C1[Chosen Codex profile]
    P --> C2[Another chosen Codex profile]
    P --> CL[Claude Current]
    CC --> D[Normal provider storage]
    CL --> D2[Normal Claude storage]
    C1 --> I1[Private Electron + CODEX_HOME]
    C2 --> I2[Private Electron + CODEX_HOME]
```

Only a chosen managed Codex profile receives `--user-data-dir`, `CODEX_ELECTRON_USER_DATA_PATH`, and `CODEX_HOME`. LaunchServices starts the official app unchanged with an allowlisted environment. Current receives no isolation override. Saved profiles consume metadata and storage but are not assumed to be simultaneously runnable; practical concurrency depends on memory and on the official app.

Before launch, Pairbar saves a profile-specific pending marker. After launch it verifies the returned process, saves a receipt, rechecks the approved app fingerprint, and then clears pending state. Any unreadable identity or mismatched state blocks focus, close, restart, archive, and recovery as appropriate.

Read the [security model](SECURITY.md) and [Claude acceptance protocol](docs/CLAUDE_ACCEPTANCE.md) for the exact boundaries.

## Repository structure

| Layer | Responsibility |
|---|---|
| `SwitcherCore/Dynamic` | Dynamic provider/profile model, schema-3 metadata, migration, receipts, state resolution, archive journal |
| `SwitcherCore/Providers/Claude` | Read-only static inspection and an explicit unsupported capability result for managed Claude profiles |
| AppKit / SwiftUI | Native popover, search, filters, favorites, configurable shortcuts, login choices, local feedback |
| Runtime controller | LaunchServices, process observations, ownership checks, memory pressure, and lifecycle orchestration |
| Tests and audit | Pure state/storage/compatibility tests, fake-runtime integration checks, source-policy guard, and packaging checks |

The audited Pairbar tree passed 133 Swift tests, including injected recovery at five archive durability boundaries and a language-change regression test, plus the source-policy audit, diff/plist/shell checks, universal release compilation, fresh extraction, and strict all-architectures signature verification. The current local Pairbar 2.0.0 (17) archive contains `x86_64` and `arm64`, has SHA-256 `fbd9891b696fac98b4b28e2ed4f9502db9705956632dd998fa7f3a6514ff8058`, and is ad-hoc signed with hardened runtime. It is not Developer ID signed or notarized.

The inert native preview was inspected in English and Spanish without constructing a controller, registering shortcuts, changing login items, or touching provider apps. Its Profiles, Settings, Help, search shortcut, filtering, accessibility labels, and public screenshots use the real native UI with synthetic account names. A later installed-app pass exercised full keyboard traversal, exposed labeled controls through VoiceOver, and checked light, dark, increased-contrast, and reduced-transparency modes. Human confirmation of VoiceOver announcements is still required.

Read-only checks outside the task sandbox verified the installed ChatGPT `26.915.31945 (9922)` and Claude `1.34493.1` bundles with strict all-architectures signing and Gatekeeper (`Notarized Developer ID`). Pairbar's own checks passed for both. Earlier failures were sandbox false negatives: the restricted process could not reach the system trust store. No official bundle was changed. Local migration, reinstall persistence, login-item registration, and several accessibility modes have now been exercised; signed-in account separation, owned lifecycle, recovery/archive/reset, an actual login event, and clean-user acceptance remain pending.

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) before changing security-sensitive behavior. Report reproducible bugs through [GitHub issues](https://github.com/isaacstg/pairbar-codex/issues/new?template=bug_report.yml) and use [private vulnerability reporting](https://github.com/isaacstg/pairbar-codex/security/advisories/new) for security issues. Never include account data or credentials.

## Credits and license

Created by **[Isaac · isaacstg](https://github.com/isaacstg)**. The implementation is independent. Existing account switchers were studied for product patterns; reused code must be separately identified and attributed.

**MIT** · [License](LICENSE) · [Changelog](CHANGELOG.md)
