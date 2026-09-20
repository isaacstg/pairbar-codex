# Changelog

## 2.0.0 — Development candidate

- Replace the fixed Current + Second interface with one protected Current entry per provider and any number of saved Codex profiles.
- Give every managed Codex profile independent Electron storage, `CODEX_HOME`, durable launch intent, and an exact ownership receipt.
- Add search, provider filters, favorites, ordering, explicit multi-select, configurable shortcuts, English/Spanish UI, and per-profile login selection.
- Migrate existing Pairbar metadata without reading profile contents; preserve the historical Second storage directory.
- Add conservative recovery and journaled archive/reset while keeping Current outside destructive lifecycle control.
- Add read-only Claude compatibility research. Claude Current remains available after identity verification; managed Claude profiles remain disabled pending real Chat, Code, and Cowork acceptance.
- Recheck provider ownership after asynchronous compatibility inspection, skip unsupported residual profiles during login launch, and let one optional provider failure leave later safe targets available.
- Keep focus of already-running verified profiles available under critical memory pressure while pausing new automatic launches.
- Use selector-based refresh scheduling for compatibility with the macOS 14 Swift concurrency checker.
- Expand the automated suite to 131 tests and the source-policy audit to the Pairbar 2 invariants.

This candidate is not a public binary release. Developer ID signing, notarization, clean-machine verification, and the real signed-in acceptance matrix remain open.

## 1.3.3 — A proper welcome

- Show a brief native menu-bar introduction once, including for users upgrading with completed account setup.
- Explain the menu-bar location, normal Current account, separate Second sign-in, shortcuts, and Open Both.
- Keep Get Started / Go to Accounts visible below the scrollable content, and allow replay from Help → Quick Start.
- Store only an introduction-completed preference in the switcher's own preferences; preserve setup approval, account data, and login-item state. Scratch previews never read or write the welcome preference.

## 1.3.2 — Pairbar on the Mac

- Use Pairbar in the native interface, menu-bar tooltip, accessibility labels, diagnostics, and application metadata.
- Package `Pairbar.app` as `Pairbar.zip`; update CI artifact names and upgrade instructions.
- Preserve the existing bundle identifier, executable, private storage root, settings, and account data.

## 1.3.1 — Stable account actions

- Align Current and Second Open/Switch actions in a fixed-width column.
- Put Second's ownership-gated More menu below its primary button alongside the shortcut; hide the extra menu chevron.
- Match the public interface illustration to the native dark/gray account cards and blue Open Both control.
- Rename the public repository to `isaacstg/pairbar-codex` and update repository links and clone instructions.

## Public project presentation

- Introduce Pairbar as the public project identity, with an original vector mark, banner, and social-preview asset.
- Make the README focus on the workflow, setup, security boundaries, and accurate validation evidence; move the detailed manual to `docs/USER_GUIDE.md`.
- Add an engineering case study documenting product decisions, implementation trade-offs, and AI-assisted development for portfolio readers.
- Rename the public repository to `isaacstg/pairbar-codex`; update badges, clone instructions, documentation links, and the project homepage. The old GitHub URL redirects.
- Retain compatibility-sensitive installed 1.3 names and identifiers.

## 1.3.0 — Menu-bar experience

- Replace the long menu and detached settings/diagnostics windows with a native menu-bar popover.
- Keep Accounts focused on two account cards and Open Both; move Second quit/restart into its ownership-gated More menu.
- Introduce clear Set Up Second Account and Confirm ChatGPT Update actions, with automatic app checking and technical details kept in Help.
- Separate Save Names from app-version confirmation; validate labels without modifying approval or setup.
- Show errors inline, reopen the popover after shortcut errors, and dismiss it after successful account activation.
- Group startup at login, diagnostics, recovery, archive/reset, uninstall, and version information into Settings/Help.
- Add keyboard dismissal, native Shift-Command-B back navigation, accessibility labels, long-label support, and safe scratch-preview validation.
- Refuse app-version confirmation during recovery or an account lifecycle action; recheck state after asynchronous inspection.
- Preserve the bundle identifier, private root, settings schema, existing sign-ins, storage isolation, hotkeys, and graceful-only process ownership policy.

## 1.2.0 — Current + Second architecture

- Preserve the user's normal Current account and isolate only Second.
- Add typed account state, conservative Current discovery, verified Second receipts, pending-launch quarantine, update fingerprint checks, metadata-only migration, and archive/reset.
- Expand static policy audit and unit tests; validate builds on macOS 14 and 15.
- Keep the switcher local-only and independent of credentials, cookies, Keychain data, process arguments/environments, and official-app modifications.
