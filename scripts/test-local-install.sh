#!/usr/bin/env bash
# Non-destructive macOS integration test of the actual installation/rollback
# branches, using fake HOME and private app bundles. Never touches /Applications
# or any real Pairbar/ChatGPT profile.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$repo"
scratch="$(/usr/bin/mktemp -d "${TMPDIR:-/private/tmp/}pairbar-install-smoke.XXXXXX")"
pointer="$repo/work/pairbar-candidate-path"
old_pointer="$scratch/original-pointer"
had_pointer=0
if [[ -f "$pointer" ]]; then
    /bin/cp "$pointer" "$old_pointer"
    had_pointer=1
fi
cleanup() {
    if [[ $had_pointer -eq 1 ]]; then
        /bin/cp "$old_pointer" "$pointer"
    else
        /bin/rm -f -- "$pointer"
    fi
    /bin/rm -rf -- "$scratch"
}
trap cleanup EXIT

fake_home="$scratch/home"
candidate_dir="$fake_home/Library/Application Support/Pairbar Candidate Builds/candidate.smoke"
installed="$fake_home/Applications/Pairbar.app"
/bin/mkdir -p "$candidate_dir" "$fake_home/Applications" "$repo/work"
/usr/bin/ditto -x -k "$repo/dist/Pairbar.zip" "$candidate_dir"
/usr/bin/ditto "$candidate_dir/Pairbar.app" "$installed"
sentinel="$installed/Contents/Resources/previous-install-sentinel"
/usr/bin/touch "$sentinel"
printf '%s\n' "$candidate_dir/Pairbar.app" > "$pointer"

echo "Smoke-test Pairbar install under isolated temporary HOME..."
HOME="$fake_home" /bin/bash "$repo/scripts/try-work-fix.sh" --install-after-work-test
[[ -d "$installed" && ! -e "$sentinel" ]] || {
    echo "Staged candidate was not installed correctly" >&2; exit 1;
}
manifest="$fake_home/Library/Application Support/Pairbar Backups/last-installed-pairbar.txt"
[[ -f "$manifest" ]] || { echo "Missing rollback manifest" >&2; exit 1; }

echo "Smoke-test Pairbar rollback under isolated temporary HOME..."
HOME="$fake_home" /bin/bash "$repo/scripts/try-work-fix.sh" --rollback
[[ -e "$sentinel" ]] || { echo "Original installation was not restored" >&2; exit 1; }
echo "Pairbar local installer and rollback smoke-test PASS."
