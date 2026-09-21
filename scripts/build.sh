#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

build_archs="${SWITCHER_BUILD_ARCHS:-universal}"
case "$build_archs" in
  universal) architectures=(arm64 x86_64) ;;
  native) architectures=("$(/usr/bin/uname -m)") ;;
  arm64|x86_64) architectures=("$build_archs") ;;
  *) printf 'Unsupported SWITCHER_BUILD_ARCHS: %s\n' "$build_archs" >&2; exit 2 ;;
esac

binaries=()
for architecture in "${architectures[@]}"; do
  triple="${architecture}-apple-macosx13.0"
  scratch="$PWD/work/build-$architecture"
  cache="$PWD/work/swift-cache-$architecture"
  clang_cache="$PWD/work/clang-cache-$architecture"
  mkdir -p "$cache" "$clang_cache"
  build_args=(-c release --triple "$triple" --scratch-path "$scratch" --cache-path "$cache" --product DualAccountSwitcher)
  if [[ "${SWITCHER_SWIFTPM_DISABLE_SANDBOX:-0}" == "1" ]]; then build_args+=(--disable-sandbox); fi
  CLANG_MODULE_CACHE_PATH="$clang_cache" SWIFTPM_MODULECACHE_OVERRIDE="$cache" swift build "${build_args[@]}"
  bin_dir="$(CLANG_MODULE_CACHE_PATH="$clang_cache" SWIFTPM_MODULECACHE_OVERRIDE="$cache" swift build "${build_args[@]}" --show-bin-path)"
  binaries+=("$bin_dir/DualAccountSwitcher")
done

mkdir -p dist
staging_dir="$(/usr/bin/mktemp -d /private/tmp/codex-account-switcher-build.XXXXXX)"
archive_temp="$PWD/dist/.Pairbar-$(/usr/bin/uuidgen).zip"
iconset=""
trap 'rm -rf -- "$staging_dir"; if [[ -n "$iconset" ]]; then rm -rf -- "$iconset"; fi; rm -f -- "$archive_temp"' EXIT

app="$staging_dir/Pairbar.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

mkdir -p work/clang-cache-native
CLANG_MODULE_CACHE_PATH="$PWD/work/clang-cache-native" swiftc Tools/AppIcon.swift -o work/build-app-icon
iconset="$PWD/work/AppIcon-$(/usr/bin/uuidgen).iconset"
work/build-app-icon "$iconset"
/usr/bin/iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"

if [[ "${#binaries[@]}" -eq 1 ]]; then
  cp "${binaries[0]}" "$app/Contents/MacOS/DualAccountSwitcher"
else
  /usr/bin/lipo -create "${binaries[@]}" -output "$app/Contents/MacOS/DualAccountSwitcher"
fi
cp Resources/Info.plist "$app/Contents/Info.plist"

[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" == "io.isaacstg.codex-dual-account-switcher" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$app/Contents/Info.plist")" == "Pairbar" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")" == "DualAccountSwitcher" ]]
app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
app_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")"
[[ "$app_version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]
[[ "$app_build" =~ ^[1-9][0-9]*$ ]]
[[ -x "$app/Contents/MacOS/DualAccountSwitcher" ]]
actual_architectures="$(/usr/bin/lipo -archs "$app/Contents/MacOS/DualAccountSwitcher")"
for architecture in "${architectures[@]}"; do
  [[ " $actual_architectures " == *" $architecture "* ]]
done

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
printf 'Architectures: %s\n' "$actual_architectures"
printf 'SHA-256: %s\n' "$checksum"
