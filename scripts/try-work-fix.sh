#!/usr/bin/env bash
# Build and trial a Pairbar candidate without overwriting the installed app or profile data.
set -euo pipefail
umask 077

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$repo"
mode="${1:---build}"
candidate_root="$HOME/Library/Application Support/Pairbar Candidate Builds"
backup_root="$HOME/Library/Application Support/Pairbar Backups"
metadata_root="$HOME/Library/Application Support/Codex Dual Account Switcher"
pointer="$repo/work/pairbar-candidate-path"

if [[ "$(/usr/bin/uname -s)" != "Darwin" ]]; then
    echo "This workflow runs only on macOS." >&2
    exit 2
fi
if [[ "$mode" != "--build" && "$mode" != "--launch" && "$mode" != "--install-after-work-test" ]]; then
    echo "Usage: bash scripts/try-work-fix.sh [--build | --launch | --install-after-work-test]" >&2
    exit 2
fi

/usr/bin/mkdir -p "$candidate_root" "$backup_root" "$repo/work"
/bin/chmod 700 "$candidate_root" "$backup_root"

read_candidate() {
    if [[ ! -f "$pointer" ]]; then
        echo "No candidate found. Run: bash scripts/try-work-fix.sh --build" >&2
        exit 2
    fi
    candidate="$(/bin/cat "$pointer")"
    if [[ "$candidate" != "$candidate_root/"*"/Pairbar.app" || -L "$candidate" || ! -d "$candidate" ]]; then
        echo "The stored candidate is missing or outside the private build directory." >&2
        exit 2
    fi
    local identity
    identity="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$candidate/Contents/Info.plist")"
    if [[ "$identity" != "io.isaacstg.codex-dual-account-switcher" ]]; then
        echo "Candidate bundle identity is incorrect." >&2
        exit 2
    fi
    /usr/bin/codesign --verify --strict --all-architectures "$candidate"
}

require_pairbar_closed() {
    # Do not terminate the user's installed Pairbar or any ChatGPT process.
    if /usr/bin/pgrep -f '/Pairbar.app/Contents/MacOS/DualAccountSwitcher' >/dev/null; then
        echo "Quit the running Pairbar normally from its menu, then rerun:" >&2
        echo "  bash scripts/try-work-fix.sh $mode" >&2
        exit 3
    fi
}

if [[ "$mode" == "--build" ]]; then
    echo "Checking the source and running the Swift test suite..."
    if [[ -n "$(/usr/bin/git status --porcelain --untracked-files=normal)" ]]; then
        echo "Use a clean checkout before packaging the test candidate." >&2
        exit 2
    fi
    /usr/bin/python3 scripts/audit.py
    /usr/bin/swift test
    SWITCHER_BUILD_ARCHS=native /bin/bash scripts/build.sh
    build_dir="$(/usr/bin/mktemp -d "$candidate_root/candidate.XXXXXX")"
    /usr/bin/ditto -x -k "$repo/dist/Pairbar.zip" "$build_dir"
    candidate="$build_dir/Pairbar.app"
    /usr/bin/codesign --verify --strict --all-architectures "$candidate"
    /bin/printf '%s\n' "$candidate" > "$pointer"
    echo "Candidate built: $candidate"
    echo "Run: bash scripts/try-work-fix.sh --launch"
    exit 0
fi

read_candidate
if [[ "$mode" == "--launch" ]]; then
    require_pairbar_closed
    # Back up *only* Pairbar's metadata. Work's session directories are never read or moved.
    if [[ -d "$metadata_root/Metadata" && ! -L "$metadata_root/Metadata" ]]; then
        snapshot="$(/usr/bin/mktemp -d "$backup_root/metadata.XXXXXX")"
        /usr/bin/ditto "$metadata_root/Metadata" "$snapshot/Metadata"
        echo "Metadata backed up privately to: $snapshot"
    fi
    echo "Opening trial Pairbar. Choose Work and verify it uses the correct account."
    /usr/bin/open -n "$candidate"
    echo "The installed Pairbar was not replaced."
    echo "After verifying Work, quit Pairbar and run:"
    echo "  bash scripts/try-work-fix.sh --install-after-work-test"
    exit 0
fi

# Explicit second-phase installation, after the owner has checked Work in the trial build.
require_pairbar_closed
destination="${PAIRBAR_APP_PATH:-}"
if [[ -z "$destination" ]]; then
    if [[ -d /Applications/Pairbar.app ]]; then destination="/Applications/Pairbar.app"
    elif [[ -d "$HOME/Applications/Pairbar.app" ]]; then destination="$HOME/Applications/Pairbar.app"
    else
        echo "Could not find the installed Pairbar. Set PAIRBAR_APP_PATH to its full .app path." >&2
        exit 2
    fi
fi
if [[ "$destination" != /* || "$destination" != *.app || -L "$destination" || ! -d "$destination" ]]; then
    echo "Refusing an unexpected installation destination." >&2
    exit 2
fi
installed_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$destination/Contents/Info.plist")"
if [[ "$installed_id" != "io.isaacstg.codex-dual-account-switcher" ]]; then
    echo "Existing app identity is not Pairbar. Nothing was replaced." >&2
    exit 2
fi

snapshot="$(/usr/bin/mktemp -d "$backup_root/original-app.XXXXXX")"
/usr/bin/ditto "$destination" "$snapshot/Pairbar.app"
echo "Previous app backed up to: $snapshot/Pairbar.app"

# Stage on the destination volume before swapping the app bundles.
suffix="$(/usr/bin/uuidgen)"
staged="$destination.pairbar-staging-$suffix"
previous="$destination.pairbar-previous-$suffix"
if [[ -e "$staged" || -e "$previous" ]]; then
    echo "Installation staging path is not free." >&2
    exit 2
fi
if [[ -w "$(dirname "$destination")" ]]; then
    elevate=()
else
    /usr/bin/sudo -v
    elevate=(/usr/bin/sudo)
fi
"${elevate[@]}" /usr/bin/ditto "$candidate" "$staged"
"${elevate[@]}" /usr/bin/codesign --verify --strict --all-architectures "$staged"
"${elevate[@]}" /bin/mv "$destination" "$previous"
if ! "${elevate[@]}" /bin/mv "$staged" "$destination"; then
    echo "Could not complete installation, restoring the previous application..." >&2
    "${elevate[@]}" /bin/mv "$previous" "$destination"
    exit 1
fi
echo "Installed trial Pairbar: $destination"
echo "Rollback copy preserved at: $previous"
echo "No provider session or profile storage was deleted or moved."
echo "Launch Pairbar normally and verify Personal and Work."
