#!/usr/bin/env python3
"""Static source-policy guard. This complements, but never replaces, tests and manual review."""
from pathlib import Path
import plistlib
import re
import sys

root = Path(__file__).resolve().parents[1]
source_files = sorted([*(root / 'Sources').rglob('*'), *(root / 'Tools').rglob('*')])
source_files = [p for p in source_files if p.suffix in {'.swift', '.c', '.h'}]

forbidden = {
    'network API': r'\b(?:URLSession|URLRequest|NSURLConnection|NWConnection|NWListener|CFNetwork|WebKit|WKWebView)\b|import\s+Network\b|#include\s*[<"](?:sys/socket|netinet|curl)',
    'telemetry or updater framework': r'\b(?:SentrySDK|TelemetryClient|Analytics|SUUpdater|SPUStandardUpdaterController)\b|import\s+(?:Sparkle|Sentry)\b',
    'credential API': r'\b(?:SecItem\w*|SecKeychain\w*|LAContext|ASAuthorization\w*)\b',
    'environment/argv inspection': r'ProcessInfo[^\n]*\.environment|\b(?:getenv|KERN_PROCARGS2?|sysctl|proc_pidargs)\b',
    'shell/subprocess execution': r'\bProcess\s*\(|\bNSTask\b|(?<![.\w])(?:system|popen|execve)\s*\(',
    'credential file access': r'auth\.json|Cookies|Login Data|Local Storage|Session Storage',
    'privilege/destructive process API': r'\b(?:AuthorizationCreate|setuid|seteuid|kill|forceTerminate)\s*\(',
    'process injection or memory inspection': r'\b(?:task_for_pid|ptrace|mach_vm_(?:read|write)|DYLD_INSERT_LIBRARIES)\b',
    'app/Dock mutation': r'com\.apple\.dock|persistent-apps|LSMultipleInstancesProhibited',
}

# These are architectural invariants, not just API bans. Current Account (.a) is discovery/focus
# only and must never get switcher-private storage or a switcher-owned launch receipt.
architecture_forbidden = {
    'private Current Account storage creation': r'\bprepare\s*\(\s*\.a\s*\)',
    'Current Account ownership receipt creation': r'LaunchReceipt\s*\(\s*profile\s*:\s*\.a\b',
    'managed Claude receipt construction': r'LaunchReceipt2\s*\(\s*provider\s*:\s*\.claude\b',
    'managed Claude launch recipe': r'\bstatic\s+func\s+claude\s*\(',
}

failures = []
for path in source_files:
    text = path.read_text()
    for label, pattern in forbidden.items():
        for match in re.finditer(pattern, text):
            line = text.count('\n', 0, match.start()) + 1
            failures.append(f'{path.relative_to(root)}:{line}: {label}')

    # Legacy model types may mention `.a`, but executable source must not construct ownership or
    # private storage for it. Tests intentionally construct old receipts to prove migration safety.
    if 'Sources' in path.parts:
        for label, pattern in architecture_forbidden.items():
            for match in re.finditer(pattern, text):
                line = text.count('\n', 0, match.start()) + 1
                failures.append(f'{path.relative_to(root)}:{line}: {label}')

if failures:
    print('\n'.join(failures), file=sys.stderr)
    sys.exit(1)

required_invariants = {
    root / 'Sources/SwitcherCore/Providers/Claude/ClaudeCompatibility.swift': [
        ('Claude compatibility gate must fail closed', r'public\s+var\s+managedLaunchAllowed:\s*Bool\s*\{\s*false\s*\}'),
        ('Claude preflight gate must fail closed', r'public\s+static\s+var\s+managedLaunchAllowed:\s*Bool\s*\{\s*false\s*\}'),
    ],
    root / 'Sources/SwitcherCore/Dynamic/DynamicStore.swift': [
        ('profile creation must remain Codex-only', r'guard\s+provider\s*==\s*\.codex\s+else\s*\{\s*throw\s+DynamicStoreError\.unsupportedProfile\s*\}'),
        ('private storage preparation must remain Codex-only', r'guard\s+!profile\.archived,\s*profile\.provider\s*==\s*\.codex\s+else\s*\{\s*throw\s+DynamicStoreError\.unsupportedProfile\s*\}'),
        ('archive must reject providers without managed-profile support', r'func\s+archive\s*\([^)]*\).*?guard\s+evidence\.provider\.managedProfilesEnabled\s+else\s*\{\s*throw\s+DynamicStoreError\.unsupportedProfile\s*\}'),
        ('archive recovery must reject providers without managed-profile support', r'func\s+recoverArchives\s*\([^)]*\).*?guard\s+evidence\.provider\.managedProfilesEnabled\s+else\s*\{\s*throw\s+DynamicStoreError\.unsupportedProfile\s*\}'),
    ],
    root / 'Sources/SwitcherCore/Dynamic/Models.swift': [
        ('Current must remain a target without a profile payload', r'enum\s+AccountTarget2[^}]*case\s+current\s*\(\s*ProviderID2\s*\)'),
        ('managed profiles must remain centrally Codex-only', r'var\s+managedProfilesEnabled:\s*Bool\s*\{\s*self\s*==\s*\.codex\s*\}'),
    ],
}

for path, invariants in required_invariants.items():
    if not path.is_file():
        failures.append(f'{path.relative_to(root)}: required safety module is missing')
        continue
    text = path.read_text()
    for label, pattern in invariants:
        if re.search(pattern, text, re.DOTALL) is None:
            failures.append(f'{path.relative_to(root)}: {label}')

controller_path = root / 'Sources/DualAccountSwitcher/PairbarController.swift'
if controller_path.is_file():
    controller = controller_path.read_text()
    open_function = re.search(r'func\s+open\s*\([^)]*\).*?(?=\n\s*@discardableResult\s*\n\s*func\s+close)', controller, re.DOTALL)
    managed_gate = r'case\s+\.managed\s*\([^)]*\):.*?guard\s+provider\.managedProfilesEnabled\s+else\s*\{\s*fail\s*\(\s*"claude-unvalidated"\s*\)\s*;\s*return\s+false\s*\}'
    if open_function is None:
        failures.append('Sources/DualAccountSwitcher/PairbarController.swift: managed/current open function could not be audited')
    elif re.search(managed_gate, open_function.group(0), re.DOTALL) is None:
        failures.append('Sources/DualAccountSwitcher/PairbarController.swift: managed launch must retain its explicit Codex-only gate')
    current_open = None if open_function is None else re.search(
        r'switch\s+target\s*\{\s*case\s+\.current\s*:?(.*?)case\s+\.managed\s*\(',
        open_function.group(0), re.DOTALL)
    if current_open is None:
        failures.append('Sources/DualAccountSwitcher/PairbarController.swift: Current launch branch could not be audited')
    else:
        for token in ('LaunchReceipt2(', 'prepareStorage(', 'runtime.terminate(', 'store.archive('):
            if token in current_open.group(1):
                failures.append(f'Sources/DualAccountSwitcher/PairbarController.swift: Current launch branch contains prohibited authority {token}')
    lifecycle_gates = {
        'close': r'guard\s+provider\.managedProfilesEnabled\s+else',
        'restart': r'guard\s+record\.provider\.managedProfilesEnabled\s+else',
        'recover': r'guard\s+provider\.managedProfilesEnabled\s+else',
        'archive': r'guard\s+record\.provider\.managedProfilesEnabled\s+else',
    }
    for function_name, gate in lifecycle_gates.items():
        function = re.search(rf'func\s+{function_name}\s*\([^)]*\).*?(?=\n\s*(?:@discardableResult\s*)?func\s+|\Z)', controller, re.DOTALL)
        if function is None or re.search(gate, function.group(0)) is None:
            failures.append(f'Sources/DualAccountSwitcher/PairbarController.swift: {function_name} must retain the central managed-provider gate')
else:
    failures.append('Sources/DualAccountSwitcher/PairbarController.swift: required dynamic controller is missing')

try:
    with (root / 'Resources/Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    expected_info = {
        'CFBundleIdentifier': 'io.isaacstg.codex-dual-account-switcher',
        'CFBundleName': 'Pairbar',
        'CFBundleDisplayName': 'Pairbar',
        'CFBundleExecutable': 'DualAccountSwitcher',
        'LSUIElement': True,
    }
    for key, expected in expected_info.items():
        if info.get(key) != expected:
            failures.append(f'Resources/Info.plist: expected {key}={expected!r}')
    if not re.fullmatch(r'[0-9]+(?:\.[0-9]+){1,2}', str(info.get('CFBundleShortVersionString', ''))):
        failures.append('Resources/Info.plist: CFBundleShortVersionString must be an explicit numeric release version')
    if not re.fullmatch(r'[1-9][0-9]*', str(info.get('CFBundleVersion', ''))):
        failures.append('Resources/Info.plist: CFBundleVersion must be a positive integer')
    for key in ('SUFeedURL', 'SUEnableAutomaticChecks', 'NSAppTransportSecurity'):
        if key in info:
            failures.append(f'Resources/Info.plist: prohibited updater/network configuration {key}')
except (OSError, plistlib.InvalidFileException) as error:
    failures.append(f'Resources/Info.plist: unreadable or invalid ({type(error).__name__})')

try:
    manifest = (root / 'Package.swift').read_text()
    if re.search(r'\.package\s*\(', manifest):
        failures.append('Package.swift: remote or external package dependencies require explicit source-policy review')
except OSError as error:
    failures.append(f'Package.swift: unreadable ({type(error).__name__})')

if failures:
    print('\n'.join(failures), file=sys.stderr)
    sys.exit(1)

print('Source policy guard passed: prohibited network, telemetry, updater, credential, foreign environment/argv, shell, injection, force-kill, Dock mutation, Current ownership/storage, managed-Claude launch, and unreviewed package patterns are absent; fail-closed provider, version, and menu-bar invariants are present.')
