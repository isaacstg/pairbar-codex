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
if [[ "$mode" != "--build" && "$mode" != "--launch" && "$mode" != "--install-after-work-test" &&
      "$mode" != "--sync-install" && "$mode" != "--rollback" &&
      "$mode" != "--cleanup-preview" && "$mode" != "--cleanup-downloads" ]]; then
    echo "Usage: bash scripts/try-work-fix.sh [--sync-install | --build | --launch | --install-after-work-test | --rollback | --cleanup-preview | --cleanup-downloads]" >&2
    exit 2
fi

/bin/mkdir -p "$candidate_root" "$backup_root" "$repo/work"
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
    if /usr/bin/pgrep -f '[D]ualAccountSwitcher' >/dev/null; then
        echo "Quit the running Pairbar normally from its menu, then rerun:" >&2
        echo "  bash scripts/try-work-fix.sh $mode" >&2
        exit 3
    fi
}

# Bash 3.2 on macOS treats an empty array expansion as unbound under set -u.
# Avoid the empty 'sudo prefix' array entirely: invoke the desired command
# directly when the destination is writable, and use sudo only when needed.
verify_destination_permissions() {
    local app_path="$1"
    local parent_path
    parent_path="$(dirname "$app_path")"
    if [[ ! -w "$parent_path" ]]; then
        /usr/bin/sudo -v
    fi
}
run_destination_command() {
    local parent_path
    parent_path="$(dirname "$destination")"
    if [[ -w "$parent_path" ]]; then
        "$@"
    else
        /usr/bin/sudo "$@"
    fi
}

# Local Git source of truth: a fresh Mac-built binary avoids Gatekeeper quarantine
# inherited from downloaded, ad-hoc-signed ZIP artifacts.
if [[ "$mode" == "--sync-install" ]]; then
    cd "$repo"
    if [[ -n "$(/usr/bin/git status --porcelain --untracked-files=normal)" ]]; then
        echo "Local source has changes. Preserve them before updating." >&2; exit 2
    fi
    origin="$(/usr/bin/git remote get-url origin)"
    case "$origin" in
        https://github.com/isaacstg/pairbar-codex|https://github.com/isaacstg/pairbar-codex.git|git@github.com:isaacstg/pairbar-codex.git) ;;
        *) echo "Refusing to fetch from unexpected Git origin." >&2; exit 2 ;;
    esac
    branch="$(/usr/bin/git symbolic-ref --short HEAD)"
    case "$branch" in
        chatgpt/pairbar-resilient-profiles-20261116|main) ;;
        *) echo "Use the Pairbar hotfix branch or main." >&2; exit 2 ;;
    esac
    echo "Fetching latest Pairbar source from GitHub ($branch)..."
    /usr/bin/git pull --ff-only origin "$branch"
    # main is still the old broken release until the hotfix PR is merged.
    if [[ "$branch" == "main" ]] &&
       [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist)" == "27" ]]; then
        echo "main still has build 27; use the 2.0.1 hotfix branch." >&2; exit 2
    fi
    /bin/bash scripts/try-work-fix.sh --build
    read_candidate
    chatgpt="${CHATGPT_APP_PATH:-/Applications/ChatGPT.app}"
    if [[ ! -d "$chatgpt" ]]; then echo "Official ChatGPT.app not found: $chatgpt" >&2; exit 2; fi
    echo "Checking the installed ChatGPT against this locally built Pairbar..."
    set +e
    "$candidate/Contents/MacOS/DualAccountSwitcher" --check-app "$chatgpt" > "$repo/work/compatibility-check.txt" 2>&1
    check_exit=$?
    set -e
    if [[ $check_exit -ne 0 ]]; then
        /bin/cat "$repo/work/compatibility-check.txt"
        echo "Compatibility or macOS execution failed (exit $check_exit). No app was installed." >&2
        echo "Do not reset Work. A Killed: 9 here requires checking local code-signing/security logs." >&2
        exit 4
    fi
    echo "Official ChatGPT compatibility PASS."
    # The owner quits Pairbar normally; no forced quit of any process.
    require_pairbar_closed
    # Preserve a private metadata snapshot before replacing the app, not just
    # when starting a standalone trial. Never copy profile/session contents.
    if [[ -d "$metadata_root/Metadata" && ! -L "$metadata_root/Metadata" ]]; then
        metadata_snapshot="$(/usr/bin/mktemp -d "$backup_root/metadata.XXXXXX")"
        /usr/bin/ditto "$metadata_root/Metadata" "$metadata_snapshot/Metadata"
        echo "Pairbar metadata backup: $metadata_snapshot"
    fi
    /bin/bash scripts/try-work-fix.sh --install-after-work-test
    echo "Pairbar installed from source. Open it normally and verify Work and Personal."
    exit 0
fi

if [[ "$mode" == "--cleanup-preview" || "$mode" == "--cleanup-downloads" ]]; then
    # Exact files created by the earlier downloadable diagnostic / installer attempts.
    # Never remove the Git checkout, Pairbar backups, application, or Profiles/b.
    disposable=(
        "$HOME/Downloads/Pairbar-2.0.1-Work-Fix.zip"
        "$HOME/Downloads/Pairbar-2.0.1-Work-Fix"
        "$HOME/Downloads/pairbar-diagnose-mac.sh"
        "$HOME/Downloads/pairbar-work-probe.sh"
    )
    echo "Known disposable Pairbar downloads:"
    for item in "${disposable[@]}"; do
        if [[ -e "$item" && ! -L "$item" ]]; then
            /usr/bin/du -sh "$item" 2>/dev/null || true
            if [[ "$mode" == "--cleanup-downloads" ]]; then /bin/rm -rf -- "$item"; fi
        fi
    done
    echo "Protected: Pairbar Backups, Pairbar Candidate Builds, source checkout, and all ChatGPT profile directories."
    [[ "$mode" == "--cleanup-preview" ]] && echo "Remove only listed downloads: bash scripts/try-work-fix.sh --cleanup-downloads"
    exit 0
fi

if [[ "$mode" == "--rollback" ]]; then
    require_pairbar_closed
    manifest="$backup_root/last-installed-pairbar.txt"
    if [[ ! -f "$manifest" || -L "$manifest" ]]; then
        echo "No saved previous-install manifest; no changes made." >&2; exit 2
    fi
    destination="$(sed -n '1p' "$manifest")"
    previous="$(sed -n '2p' "$manifest")"
    if [[ "$destination" != "/Applications/Pairbar.app" &&
          "$destination" != "$HOME/Applications/Pairbar.app" ]] ||
       [[ "$previous" != "$destination.pairbar-previous-"* ]] ||
       [[ ! -d "$previous" || -L "$previous" ]]; then
        echo "Unexpected rollback locations; nothing changed." >&2; exit 2
    fi
    previous_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$previous/Contents/Info.plist" 2>/dev/null || true)"
    current_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$destination/Contents/Info.plist" 2>/dev/null || true)"
    if [[ "$previous_id" != "io.isaacstg.codex-dual-account-switcher" ||
          "$current_id" != "io.isaacstg.codex-dual-account-switcher" ]]; then
        echo "App identity check failed. No rollback performed." >&2; exit 2
    fi
    verify_destination_permissions "$destination"
    displaced="$destination.pairbar-rollback-new-$(/usr/bin/uuidgen)"
    run_destination_command /bin/mv "$destination" "$displaced"
    if ! run_destination_command /bin/mv "$previous" "$destination"; then
        run_destination_command /bin/mv "$displaced" "$destination"
        echo "Rollback failed; the newer app was put back." >&2; exit 1
    fi
    echo "Previous Pairbar restored at: $destination"
    echo "Newer app retained at: $displaced"
    echo "Personal and Work sessions were untouched."
    exit 0
fi

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
    printf '%s\n' "$candidate" > "$pointer"
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
verify_destination_permissions "$destination"
run_destination_command /usr/bin/ditto "$candidate" "$staged"
run_destination_command /usr/bin/codesign --verify --strict --all-architectures "$staged"
run_destination_command /bin/mv "$destination" "$previous"
if ! run_destination_command /bin/mv "$staged" "$destination"; then
    echo "Could not complete installation, restoring the previous application..." >&2
    run_destination_command /bin/mv "$previous" "$destination"
    exit 1
fi
echo "Installed trial Pairbar: $destination"
echo "Rollback copy preserved at: $previous"
if [[ -d "$previous" ]]; then
    printf '%s\n%s\n' "$destination" "$previous" > "$backup_root/last-installed-pairbar.txt"
    echo "Rollback: bash scripts/try-work-fix.sh --rollback"
fi
echo "No provider session or profile storage was deleted or moved."
echo "Launch Pairbar normally and verify Personal and Work."
