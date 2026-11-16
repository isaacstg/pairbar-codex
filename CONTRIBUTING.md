# Contributing

Thanks for considering a contribution. Pairbar is intentionally conservative because its job touches real account sessions. Changes must preserve the boundary between each provider's unmanaged Current entry and receipt-owned managed profiles.

## Before opening a pull request

Use macOS 13 or later with Xcode Command Line Tools, then run:

```sh
python3 scripts/audit.py
swift test
scripts/build.sh
```

The source-policy audit is required. Do not weaken it to accommodate a feature.

Use a checkout with no symbolic-link ancestors, such as a folder in your home directory. Filesystem tests create private scratch directories inside the checkout and intentionally fail under macOS aliases such as `/tmp` or `/var`.

For an opt-in integration check, start exactly one normal ChatGPT process and choose a **new path whose ancestors are not symbolic links** as scratch storage:

```sh
swift run SwitcherSmokeTest /Applications/ChatGPT.app "$HOME/Desktop/pairbar-smoke-$(date +%s)" --disposable-macos-user
```

Run that command only in a disposable macOS user or dedicated machine with exactly one normal Current process. It starts one disposable managed Codex process and gracefully quits only that verified process. It never signs in or reads profile data. Do not use `/tmp` or `/var` as its root: macOS exposes those through symbolic links and the private-store safety guard rejects them by design.

## Non-negotiable boundaries

Contributions must not:

- modify, copy, patch, inject into, or re-sign the official ChatGPT app;
- read, move, parse, log, or upload tokens, cookies, browser data, Keychain data, account identity, process arguments, or process environments;
- introduce networking, subprocess/shell control of ChatGPT, forced termination, Dock rewriting, or a private Current profile;
- terminate or restart Current, or control a managed process without a verified profile receipt;
- make ambiguous process ownership succeed by guessing.

Read [SECURITY.md](SECURITY.md) and [docs/STATE_MACHINE.md](docs/STATE_MACHINE.md) before changing process, storage, compatibility, or recovery logic.

## Pull-request expectations

- Keep a change focused and explain the user-visible behavior and its security effect.
- Add or update tests for `SwitcherCore` policy changes.
- Update `README.md`, `SECURITY.md`, `VALIDATION.md`, and status documentation when behavior or evidence changes.
- Never add real account data, diagnostics with private information, signing certificates, provisioning profiles, or built app archives to Git.
- Do not claim that a static inspection proves account isolation. Runtime evidence belongs in `VALIDATION.md` only after it was performed.

## Reporting a security issue

Do not open a public issue containing credentials or private diagnostic output. Follow the reporting guidance in [SECURITY.md](SECURITY.md). Maintainers should enable GitHub private vulnerability reporting before making the repository public.
