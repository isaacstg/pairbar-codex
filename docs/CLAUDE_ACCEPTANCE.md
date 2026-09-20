# Claude Desktop isolation acceptance

## Status and release gate

Managed Claude profiles are **unavailable and unvalidated**. The current implementation provides an offline identity/packaged-code inspector, findings and a fail-closed compatibility gate. It has no approved managed launch recipe. Current Account may open the unchanged official Claude app normally; this is not a claim of multiple-account support.

Passing unit tests, finding directory override strings, verifying Anthropic's signature, obtaining different PIDs or creating different directories does not prove session separation. Chat **and** Code must pass real signed-in acceptance for the exact provider build before a release may claim managed Claude support. Cowork must be investigated even if its UI is not exposed by Pairbar. If it can contaminate Chat/Code account state, it blocks managed Claude entirely.

The initial installation observed during planning was Claude 1.34493.1, bundle ID `com.anthropic.claudefordesktop`, Team ID `Q6L2SF6YDW`. Packaged markers for `CLAUDE_USER_DATA_DIR`, `CLAUDE_CONFIG_DIR` and `CLAUDE_SECURESTORAGE_CONFIG_DIR` were present. Inspection also identified removal of the user-data override in the production entry point and local-pairing behavior affected by relocated storage. These are static findings, not a working recipe or isolation approval. A later installation needs fresh inspection.

## Concrete risks that remain open

| Surface | Evidence or uncertainty | Consequence for Pairbar |
| --- | --- | --- |
| Electron user data | The reviewed packaged entry point removes `CLAUDE_USER_DATA_DIR` in an ordinary production path. A marker elsewhere in the archive does not prove reachability. | Pairbar has no accepted way to assign an independent Electron session to a managed profile. |
| Claude configuration and secure storage | `CLAUDE_CONFIG_DIR` and `CLAUDE_SECURESTORAGE_CONFIG_DIR` exist in packaged code, but every Chat, Code, helper and authentication consumer has not been proven to honor them. | A visible separate window or history is insufficient; authentication or configuration may still cross profiles. |
| OAuth and deep links | macOS routes provider URLs at application/bundle scope. The official link behavior does not establish which of several instances receives a callback. | Sign-in can complete in, replace or focus the wrong account unless a real multi-instance callback matrix passes. |
| Desktop Code | Official documentation describes configuration, project and MCP behavior that can involve locations outside one chat window. The exact app build's account binding and resume behavior remain untested. | Chat cannot be approved alone; Code must preserve the same profile/account boundary across open, resume and restart. |
| Local pairing and helpers | Packaged code reports a relocation-related local-pairing restriction, and helper/singleton routing has not been validated per instance. | A managed recipe that breaks Code or redirects it through a shared helper fails acceptance even if Chat appears separate. |
| Cowork | Cowork can involve cloud execution, local execution/VM components, connectors and Chat-integrated routes depending on build and plan. Their credential and task namespaces are not proven independent. | Any shared account, connector, task or inseparable route keeps managed Claude blocked. |
| OS-scoped state | Accessibility, folder permissions, notifications, URL handlers and organizational policy can be shared by the macOS user. | Evidence must distinguish expected OS-wide state from account/session state and may not label the whole environment isolated. |
| Provider updates | Static code, routing and helpers can change without Pairbar changing. A stored fingerprint is evidence for one reviewed build only. | Every new Claude build returns to blocked until the required inspection and signed-in regression matrix pass. |

## Safe execution boundary

The existing Second Account hosts the development task. Do not close, restart, reset, archive or run provider-wide recovery against it. Do not run a test that requires all Codex processes to exit in that macOS user. Merely moving the task to Current Account does not make existing accounts disposable.

Run the full matrix in a separate macOS user or machine with test accounts and a fresh Pairbar root. A newly created disposable profile may be used for narrowly scoped lifecycle tests in an existing user only if its ID, fresh storage generation, new process identity and receipt are proven, and the test never closes other processes or changes shared settings. Provider-wide recovery, logout/login, login-item, update and archive tests belong in the separate environment.

The production Claude gate stays closed during this work. Before attempting signed-in tests, a developer must review and implement a specific recipe in a dedicated experimental build restricted to the test environment. There is no supported flag, metadata edit or UI approval that bypasses the gate. If no admissible recipe exists, record the blocker and stop the managed-Claude experiment.

Every experiment must satisfy these constraints:

- Keep the official app unchanged: no patching, resigning, copying credentials, injected code or disabling its security checks.
- Do not impersonate an internal vendor authorization or change the user's `HOME` to influence behavior.
- Use launch arguments and environment keys authored explicitly by Pairbar; never inspect or forward another process's argv or environment.
- Read only Pairbar metadata, official packaged program assets and permitted process identity metadata. Do not inspect provider profile contents, cookies, tokens, Keychain, credential files or provider logs.
- Have a human sign in through the official UI and judge account separation. Save only test aliases and pass/fail observations; do not capture real account identifiers.
- Close only processes whose complete identity and receipt are proven. Use normal app termination; never force kill. A timeout or identity error ends the action conservatively.
- Use non-sensitive test projects, harmless unique markers and folders created for this run. Never use production connectors, repositories or documents.

## Preflight and stop conditions

1. Record the Pairbar source commit, experimental policy revision, provider version/build/fingerprint, macOS version, architecture and test account plan categories. Record no account names or emails.
2. Confirm the application identity and signature offline. Recheck after inspection to detect replacement during a scan.
3. Review the entry point and reachable consumers of all proposed paths, singleton/IPC behavior, secure-storage namespace, helper configuration and pairing. A marker search alone cannot pass this step.
4. Document exactly which paths are independently configured and which settings are shared by design. Ordinary organizational policy is not profile isolation and must remain respected.
5. Establish a launch recipe that makes no forbidden modification. Verify that the signed-in test can be run without bypassing the production gate for ordinary users.
6. Prepare Current and two disposable managed profiles, named only C, A and B in the evidence. Use distinct authorized test accounts.

Stop immediately on an account crossover, callback delivered to the wrong profile, a shared logout, an unowned process, unknown identity, unexpected storage path, provider update during the run or a requirement to inspect credentials. Preserve Pairbar metadata and sanitized findings. Do not recover by copying data, deleting provider storage or modifying the official app.

## Acceptance matrix

All rows below are **pending** until a dated, build-specific result is recorded. An unavailable capability is not a pass.

| ID | Test | Required observation |
| --- | --- | --- |
| C01 | Open Current normally, then A and B individually. | Three distinct intended account UIs; Current has no Pairbar receipt or private paths; A/B have separate storage generations and exact receipts. |
| C02 | Sign in sequentially, with all three instances present. Repeat changing foreground instance before the OAuth callback. | Each callback completes the initiating session only. Browser/URL routing cannot sign in or replace another profile. |
| C03 | In Chat, create harmless unique markers in C, A and B. Switch repeatedly through UI and shortcuts. | Each human sees only the expected account/history; no marker crosses sessions. Screenshots or transcripts containing identities are not collected. |
| C04 | Close and reopen only disposable A, then B. | Their intended sign-ins and histories persist independently; the other instances stay unchanged. |
| C05 | Log out only A from the official app and sign it into a different authorized test account. | B and C retain their identities and sessions; A displays only its new intended account. |
| C06 | Start Code work in a separate harmless test project per profile; pause and resume independently. | Desktop Code uses the corresponding account, correct project and correct conversation after reopening; no account switching in another instance. |
| C07 | Change a harmless profile-scoped Code preference through supported UI, if available. | Scope is documented and observed. Shared project/organizational settings are explicitly distinguished; shared authentication or session state fails acceptance. |
| C08 | Restart Pairbar only while C/A/B remain running. | Receipt-backed ownership is recovered without adopting by PID alone. Current remains unmanaged; no profile is reopened or terminated. |
| C09 | Make repeated open requests and start a selected A/B batch. | Requests deduplicate, create no extra instance and never focus a wrong account. Only selected IDs open. |
| C10 | Simulate unreadable identity, stale receipt, late callback and partial metadata writes with a fake runtime. | The provider enters recovery/uncertainty, preserves pending intent and refuses destructive control or unsafe Current classification. |
| C11 | In the separate test user, exercise an app update and an interrupted launch. | New build invalidates managed-launch compatibility/evidence; existing ownership is not inferred from user approval. Recovery preserves data. |
| C12 | In the separate user, close disposable instances manually and exercise reset/archive. | The opaque directory is archived, not deleted; a new storage generation starts fresh; interrupted archive resumes safely. |
| C13 | Test login selection with A selected and B unselected. | Selection is off by default. Only A opens after actual login, once, if approved and safe; manual Pairbar launch and wake do not repeat it. |
| C14 | Exercise Chat/Code features that enter Cowork, if available for the tested plans. | The combined route obeys the same account boundaries. An inseparable unvalidated route prevents Chat approval. |

## Cowork investigation

Investigate local and cloud execution separately wherever offered by the exact build and plan. Observe account identity, task creation/resumption, connector selection, requested folder access and local pairing through the official UI, using disposable content only. Document which helpers or VM components are involved from packaged program code and allowed identity metadata; do not inspect their credentials, argv, environments or private data.

For each mode, verify that starting, resuming or disconnecting a task in A has no effect on B/C; a connector configured for A cannot be selected silently under B; and changing pairing or a shared setting cannot redirect execution to the wrong account. OS permissions and organization policies may be common to the macOS user and must be reported accurately rather than called isolated.

If shared authentication, a global pairing singleton, shared tasks or an inseparable Chat/Cowork route remains unexplained, managed Claude remains blocked. Do not advertise full isolation based solely on Chat's visible history.

## Evidence record

Use one sanitized record per exact build and environment:

```text
Pairbar commit:
Launch policy revision:
Provider version/build:
Official bundle/team identifiers:
Packaged-code fingerprint:
macOS / architecture:
Test environment: separate macOS user | separate machine
Plan categories for C/A/B (no identifiers):
Recipe reviewed by / date:
Chat matrix results:
Code matrix results:
Cowork local/cloud/integrated-route results:
Unresolved sharing or routing findings:
Decision: blocked | more evidence required | approved scope
Reviewer / date:
```

Evidence must distinguish a human observation, a synthetic test and static analysis. Never paste provider logs, credential values, account exports, full personal paths or screenshots of signed-in identities. Any future support decision requires code review, explicit build/capability evidence and a regression run; editing a stored fingerprint cannot grant support.

The planning investigation used these official references; recheck them for the exact acceptance build: [Claude Desktop Code](https://code.claude.com/docs/en/desktop), [Claude configuration directory](https://code.claude.com/docs/en/claude-directory), [Claude Desktop links](https://support.claude.com/en/articles/14729294-open-claude-desktop-with-a-link), [Cowork architecture](https://support.claude.com/en/articles/14479288-claude-cowork-architecture-overview) and [enterprise configuration](https://support.claude.com/en/articles/12622667-enterprise-configuration-for-claude-desktop). These references do not themselves certify Pairbar isolation.
