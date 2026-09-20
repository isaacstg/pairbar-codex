#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p work/swift-cache work/clang-cache
export CLANG_MODULE_CACHE_PATH="$PWD/work/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/work/swift-cache"
build_args=(-c release --cache-path "$PWD/work/swift-cache")
if [[ "${SWITCHER_SWIFTPM_DISABLE_SANDBOX:-0}" == "1" ]]; then build_args+=(--disable-sandbox); fi

swift build "${build_args[@]}"
bin_dir="$(swift build "${build_args[@]}" --show-bin-path)"

mkdir -p dist
staging_dir="$(/usr/bin/mktemp -d /private/tmp/codex-account-switcher-build.XXXXXX)"
archive_temp="$PWD/dist/.Pairbar-$(/usr/bin/uuidgen).zip"
iconset=""
trap 'rm -rf -- "$staging_dir"; if [[ -n "$iconset" ]]; then rm -rf -- "$iconset"; fi; rm -f -- "$archive_temp"' EXIT

app="$staging_dir/Pairbar.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

swiftc Tools/AppIcon.swift -o work/build-app-icon
iconset="$PWD/work/AppIcon-$(/usr/bin/uuidgen).iconset"
work/build-app-icon "$iconset"
/usr/bin/iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"

cp "$bin_dir/DualAccountSwitcher" "$app/Contents/MacOS/DualAccountSwitcher"
cp Resources/Info.plist "$app/Contents/Info.plist"

[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" == "io.isaacstg.codex-dual-account-switcher" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$app/Contents/Info.plist")" == "Pairbar" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")" == "DualAccountSwitcher" ]]
app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
app_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")"
[[ "$app_version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]
[[ "$app_build" =~ ^[1-9][0-9]*$ ]]
[[ -x "$app/Contents/MacOS/DualAccountSwitcher" ]]

# Signs only OUR bundle. No entitlements and no modification of the official ChatGPT bundle.
signing_identity="${SWITCHER_SIGNING_IDENTITY:--}"
if [[ "$signing_identity" == "-" ]]; then
  /usr/bin/codesign --force --sign - --options runtime --timestamp=none "$app"
  signing_description="ad-hoc development signature; not notarized"
else
  /usr/bin/codesign --force --sign "$signing_identity" --options runtime --timestamp "$app"
  signing_description="named signing identity requested; notarization not performed by this script"
fi
/usr/bin/codesign --verify --strict --all-architectures "$app"

archive="$PWD/dist/Pairbar.zip"
/usr/bin/ditto -c -k --keepParent --norsrc --noextattr "$app" "$archive_temp"
/usr/bin/unzip -tq "$archive_temp"
/bin/mv -f "$archive_temp" "$archive"
checksum="$(/usr/bin/shasum -a 256 "$archive" | /usr/bin/awk '{print $1}')"
printf '%s  %s\n' "$checksum" "Pairbar.zip" > "$archive.sha256"
printf 'Built Pairbar %s (%s): %s (%s)\n' "$app_version" "$app_build" "$archive" "$signing_description"
printf 'SHA-256: %s\n' "$checksum"
