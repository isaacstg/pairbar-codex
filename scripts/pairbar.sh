#!/usr/bin/env bash
# One entrypoint for Pairbar maintenance on the owner's Mac.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$repo"
command="${1:-help}"
shift || true

case "$command" in
    update|sync)
        pending_changes="$(/usr/bin/git status --porcelain --untracked-files=normal)"
        if [[ -n "$pending_changes" ]]; then
            echo "Local source files or untracked files require review (no files changed by updater):" >&2
            printf '%s\n' "$pending_changes" >&2
            echo "Run: git status --short ; then preserve intentional edits. Do NOT run git clean/reset blindly." >&2
            exit 2
        fi
        origin="$(/usr/bin/git remote get-url origin)"
        case "$origin" in
            https://github.com/isaacstg/pairbar-codex|https://github.com/isaacstg/pairbar-codex.git|git@github.com:isaacstg/pairbar-codex.git) ;;
            *) echo "Unexpected GitHub origin. Aborted." >&2; exit 2 ;;
        esac
        # The original --single-branch clone only tracked the hotfix refspec.
        # Fetching main into refs/remotes/origin/main alone does NOT make
        # origin/main eligible for git switch -c --track. Teach origin about
        # main before fetching so subsequent pulls have a real upstream.
        if ! /usr/bin/git config --get-all remote.origin.fetch |
             /usr/bin/grep -Fqx '+refs/heads/main:refs/remotes/origin/main'; then
            if ! /usr/bin/git config --get-all remote.origin.fetch |
                 /usr/bin/grep -Fqx '+refs/heads/*:refs/remotes/origin/*'; then
                /usr/bin/git remote set-branches --add origin main
            fi
        fi
        /usr/bin/git fetch origin main
        branch="$(/usr/bin/git branch --show-current)"
        if [[ "$branch" != "main" ]]; then
            if [[ "$branch" != "chatgpt/pairbar-resilient-profiles-20261116" ]]; then
                echo "Refusing to leave an unrelated development branch ($branch)." >&2
                exit 2
            fi
            if ! /usr/bin/git merge-base --is-ancestor HEAD refs/remotes/origin/main; then
                echo "Old hotfix branch contains unmerged commits; refusing to switch." >&2
                exit 2
            fi
            if /usr/bin/git show-ref --verify --quiet refs/heads/main; then
                /usr/bin/git switch main
            else
                /usr/bin/git switch --create main --track origin/main
            fi
        fi
        if ! /usr/bin/git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' >/dev/null 2>&1; then
            /usr/bin/git branch --set-upstream-to=origin/main main
        fi
        if [[ "$command" == "sync" ]]; then
            /usr/bin/git pull --ff-only origin main
            echo "Pairbar source scripts updated from main; installed apps and account sessions untouched."
            exit 0
        fi
        # Existing fail-closed native installation flow.
        /bin/bash "$repo/scripts/try-work-fix.sh" --sync-install
        ;;
    status)
        echo "Git branch and tracking:"
        /usr/bin/git branch -vv
        echo "Git state (filenames only; no files modified):"
        /usr/bin/git status --short --untracked-files=normal
        echo "Origin fetch refspecs:"
        /usr/bin/git config --get-all remote.origin.fetch
        ;;
    scan)
        /usr/bin/python3 "$repo/scripts/mac-cleanup.py" --scan
        ;;
    tidy)
        /usr/bin/python3 "$repo/scripts/mac-cleanup.py" --trash-safe
        ;;
    tidy-app)
        if [[ $# -ne 1 ]]; then echo "Usage: bash scripts/pairbar.sh tidy-app '/full/path/to/old.app'" >&2; exit 2; fi
        /usr/bin/python3 "$repo/scripts/mac-cleanup.py" --trash-app "$1"
        ;;
    rollback)
        /bin/bash "$repo/scripts/try-work-fix.sh" --rollback
        ;;
    *)
        cat <<'HELP'
Pairbar commands:
  bash scripts/pairbar.sh status      Diagnose branch tracking and local generated files (read-only)
  bash scripts/pairbar.sh scan        Show duplicate apps and Git worktrees (read-only)
  bash scripts/pairbar.sh tidy        Trash only recognized old downloads/builds/backups
  bash scripts/pairbar.sh tidy-app /absolute/path/old-copy.app
                                      Trash one reviewed app copy (not the installed apps)
  bash scripts/pairbar.sh sync        Pull main without compiling or reinstalling
  bash scripts/pairbar.sh update      Pull main, test, build and install from GitHub
  bash scripts/pairbar.sh rollback    Restore the last previous Pairbar app
HELP
        ;;
esac
