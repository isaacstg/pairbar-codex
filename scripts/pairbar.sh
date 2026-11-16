#!/usr/bin/env bash
# One entrypoint for Pairbar maintenance on the owner's Mac.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$repo"
command="${1:-help}"
shift || true

case "$command" in
    update)
        if [[ -n "$(/usr/bin/git status --porcelain --untracked-files=normal)" ]]; then
            echo "Local changes exist; refusing to switch branches or overwrite them." >&2
            exit 2
        fi
        origin="$(/usr/bin/git remote get-url origin)"
        case "$origin" in
            https://github.com/isaacstg/pairbar-codex|https://github.com/isaacstg/pairbar-codex.git|git@github.com:isaacstg/pairbar-codex.git) ;;
            *) echo "Unexpected GitHub origin. Aborted." >&2; exit 2 ;;
        esac
        # The initial clone fetched only the old hotfix branch. Fetch main explicitly.
        /usr/bin/git fetch origin main:refs/remotes/origin/main
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
        # Existing fail-closed native installation flow.
        /bin/bash "$repo/scripts/try-work-fix.sh" --sync-install
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
  bash scripts/pairbar.sh scan        Show duplicate apps and Git worktrees (read-only)
  bash scripts/pairbar.sh tidy        Trash only recognized old downloads/builds/backups
  bash scripts/pairbar.sh tidy-app /absolute/path/old-copy.app
                                      Trash one reviewed app copy (not the installed apps)
  bash scripts/pairbar.sh update      Pull main, test, build and install from GitHub
  bash scripts/pairbar.sh rollback    Restore the last previous Pairbar app
HELP
        ;;
esac
