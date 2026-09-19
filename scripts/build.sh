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
trap 'rm -rf -- "$staging_dir"' EXIT

app="$staging_dir/Pairbar.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

swiftc Tools/AppIcon.swift -o work/build-app-icon
iconset="$PWD/work/AppIcon-$(/usr/bin/uuidgen).iconset"
trap 'rm -rf -- "$staging_dir" "$iconset"' EXIT
work/build-app-icon "$iconset"
/usr/bin/iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"

cp "$bin_dir/DualAccountSwitcher" "$app/Contents/MacOS/DualAccountSwitcher"
cp Resources/Info.plist "$app/Contents/Info.plist"

# Signs only OUR bundle. No entitlements and no modification of the official ChatGPT bundle.
/usr/bin/codesign --force --sign "${SWITCHER_SIGNING_IDENTITY:--}" --options runtime "$app"
/usr/bin/codesign --verify --strict "$app"

archive="$PWD/dist/Pairbar.zip"
rm -f "$archive"
/usr/bin/ditto -c -k --keepParent --norsrc --noextattr "$app" "$archive"
printf 'Built signed app archive: %s\n' "$archive"
