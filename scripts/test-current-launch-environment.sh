#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
scratch="$(mktemp -d /private/tmp/pairbar-current-launch.XXXXXX)"
cleanup() {
  # The fixture app has a 60-second independent normal-termination timer.
  # Preserve its executable until every instance of this unique synthetic bundle exits.
  if [[ -f "$scratch/bundle-id" ]]; then
    "$scratch/cleanup" "$scratch"
  fi
  rm -rf -- "$scratch"
}
trap cleanup EXIT
mkdir -p "$scratch/EnvironmentFixture.app/Contents/MacOS" "$scratch/records" "$scratch/home" "$scratch/tmp" "$scratch/module-cache"
CLANG_MODULE_CACHE_PATH="$scratch/module-cache" swiftc scripts/fixtures/current-launch/FixtureCleanup.swift -o "$scratch/cleanup"
bundle_id="io.isaacstg.pairbar.environment-fixture.$(uuidgen)"
printf '%s\n' "$bundle_id" > "$scratch/bundle-id"
cat > "$scratch/EnvironmentFixture.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$bundle_id</string>
<key>CFBundleExecutable</key><string>EnvironmentFixture</string>
<key>CFBundleName</key><string>Pairbar Environment Fixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
CLANG_MODULE_CACHE_PATH="$scratch/module-cache" swiftc scripts/fixtures/current-launch/FixtureApp.swift -o "$scratch/EnvironmentFixture.app/Contents/MacOS/EnvironmentFixture"
codesign --force --sign - --timestamp=none "$scratch/EnvironmentFixture.app"
CLANG_MODULE_CACHE_PATH="$scratch/module-cache" swiftc -parse-as-library \
  Sources/DualAccountSwitcher/PairbarInheritedEnvironmentSanitizer.swift \
  Sources/DualAccountSwitcher/CurrentCodexLaunchEnvironment.swift \
  Sources/DualAccountSwitcher/ProviderLaunchRequest.swift \
  scripts/fixtures/current-launch/FixtureDriver.swift -o "$scratch/driver"
sw_vers
# Clean synthetic parent environment; no access to actual HOME or provider stores.
env -i HOME="$scratch/home" USER=fixture LOGNAME=fixture PATH=/usr/bin:/bin:/usr/sbin:/sbin TMPDIR="$scratch/tmp/" "$scratch/driver" "$scratch"
