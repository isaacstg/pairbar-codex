# Menu-bar experience plan

## Goal

The user has confirmed that opening and switching the accounts works. The next revision makes the daily interaction smaller and easier to understand while preserving every ownership and isolation invariant.

## Product decisions for 1.3

1. **One place for the interface.** Use a native popover attached to the menu-bar icon for Accounts, Settings, and Help. Dismiss with Escape, the close button, or a click outside. Double-clicking the running app brings the popover back. The switcher remains a menu-bar utility with no Dock item; there are no detached settings/diagnostic windows.
2. **Three daily actions.** Show one card per account and Open Both. Cards show user labels, friendly status, the shortcut, and Open/Switch. Show Second's quit/restart in its small More menu only while ownership is verified. Show troubleshooting only when needed.
3. **Understandable setup.** Check the official app automatically. Explain that setup opens a separate window for signing into the other account. Replace fingerprint/"approve build" copy with Set Up Second Account or Confirm ChatGPT Update. Keep the changed-build confirmation explicit and keep revalidation immediately before launch.
4. **Separate settings from approval.** Save Names changes labels only. It must not change the approved fingerprint, app path, setup state, or isolated data. Keep launch-at-login in Settings. Put app paths and detailed check results behind disclosure controls.
5. **Helpful, local feedback.** Show errors inside the popover, reopen it after shortcut errors, dismiss it after a successful account switch, and show progress during checks. Keep process IDs and fingerprints in Help's troubleshooting details.
6. **Safe Help.** Group shortcuts, recovery, diagnostics, reset/archive, uninstall, and version information. Reveal only the switcher's own data folder in Finder. Preserve confirmations and all disabled-state policy.
7. **Accessibility.** Use native controls, readable system fonts, text with status symbols, descriptive control labels, focusable buttons, and keyboard dismissal/back navigation.

## Worthwhile next additions, in priority order

These are proposals rather than promises for this revision. Add them only when a concrete need and safe implementation are demonstrated.

- **Custom shortcuts:** valuable when another app owns Option-Command-1/2; needs conflict detection, persistence, reset-to-default, and reliable registration tests.
- **Optional opening of both accounts at login:** a separate opt-in from starting the switcher, using the existing single-flight and compatibility policy. Default stays off.
- **Local project shortcuts:** user-selected workspace folders opened in the chosen instance only if the official app has a reviewed, reliable instance-targeting mechanism. Never guess an account from identity or profile contents.
- **Localization:** move UI text into resources after the interaction and copy settle; prioritize English and Spanish.
- **Signed/notarized releases and upgrade guidance:** reduce installation friction; requires an authorized Apple Developer ID and independent release acceptance.
- **Optional Dock presence:** reconsider only if users need a persistent independent workspace. A menu-bar-only popover solves the current detached-window confusion without adding a second app surface.

## Excluded from this roadmap

Account-email detection, quota polling through saved credentials, token swapping, Keychain/browser inspection, automatic update approval, force termination, three-plus accounts, and network-based auto-updating conflict with scope or the established security boundary.

## Validation and completion

Implementation status: the 1.3 changes above are implemented. Local source audit, 47 unit tests, release build/extraction/signature verification, and native scratch-preview checks passed. First run, ready, Settings, saved/invalid names, Help, long labels, pending recovery, and update confirmation were exercised; no live accounts or login items were controlled by preview. Shift-Command-B and Escape/reopening were verified. Native unavailable-build UI and full installed-app acceptance remain separate, explicitly unclaimed checks.

- Unit-test that label edits cannot grant approval or change setup/storage settings; test rejected labels and readiness gating.
- Run source audit, all unit tests, release build, and fresh extracted-bundle signature verification.
- Preview with scratch metadata and no live account actions: first run, ready, changed build, unavailable app, recovery, Settings, Help, keyboard navigation, dismissal, and long labels.
- Check native popover behavior and screen fit when native desktop access is available. Do not claim visual validation if the Mac is locked.
- Update README, SECURITY, VALIDATION, and implementation status; package a 1.3 build and push the coherent change to the private repository.
