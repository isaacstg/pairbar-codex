#!/usr/bin/env python3
"""Inventory duplicate Pairbar/ChatGPT applications and safely trash known test artifacts.

Default mode is read-only. Never inspects accounts, cookies, tokens or sessions.
Explicit --trash-safe and --trash-app move files into macOS Trash, not delete them.
"""
from __future__ import annotations
import argparse
import datetime as dt
import os
from pathlib import Path
import plistlib
import subprocess
import sys

PAIRBAR_ID = "io.isaacstg.codex-dual-account-switcher"
CHATGPT_ID = "com.openai.codex"
KNOWN_IDS = {PAIRBAR_ID, CHATGPT_ID}
SKIP_DIRS = {".git", ".build", "node_modules", ".swiftpm", ".venv", "venv", ".Trash", ".cache", "Pods", "work", "dist"}
DOWNLOAD_NAMES = (
    "Pairbar-2.0.1-Work-Fix.zip",
    "Pairbar-2.0.1-Work-Fix",
    "Pairbar-2.0.1-28-macos15-ci.zip",
    "pairbar-diagnose-mac.sh",
    "pairbar-work-probe.sh",
)


def app_info(path: Path) -> tuple[str, str] | None:
    plist = path / "Contents" / "Info.plist"
    if path.is_symlink() or not plist.is_file() or plist.is_symlink():
        return None
    try:
        with plist.open("rb") as file:
            data = plistlib.load(file)
    except (OSError, ValueError, TypeError, plistlib.InvalidFileException):
        return None
    ident = data.get("CFBundleIdentifier")
    if ident not in KNOWN_IDS:
        return None
    return ident, str(data.get("CFBundleShortVersionString", "?"))


def safe_downloads(home: Path) -> list[tuple[str, Path]]:
    downloads = home / "Downloads"
    if downloads.is_symlink():
        return []
    return [("unused-download", downloads / name) for name in DOWNLOAD_NAMES
            if (downloads / name).exists() and not (downloads / name).is_symlink()]


def safe_candidates(home: Path) -> list[tuple[str, Path]]:
    root = home / "Library/Application Support/Pairbar Candidate Builds"
    if not root.is_dir() or root.is_symlink():
        return []
    candidates = []
    for folder in root.glob("candidate.*"):
        if folder.is_symlink() or not folder.is_dir():
            continue
        if {p.name for p in folder.iterdir()} != {"Pairbar.app"}:
            continue
        info = app_info(folder / "Pairbar.app")
        if info is None or info[0] != PAIRBAR_ID:
            continue
        try:
            candidates.append((folder.stat().st_mtime, folder))
        except OSError:
            continue
    candidates.sort(key=lambda x: x[0], reverse=True)
    return [("older-build-candidate", folder) for _, folder in candidates[1:]]


def safe_backup_surplus(home: Path) -> list[tuple[str, Path]]:
    root = home / "Library/Application Support/Pairbar Backups"
    if not root.is_dir() or root.is_symlink():
        return []
    backups = []
    for folder in root.glob("original-app.*"):
        if folder.is_symlink() or not folder.is_dir():
            continue
        if {p.name for p in folder.iterdir()} != {"Pairbar.app"}:
            continue
        info = app_info(folder / "Pairbar.app")
        if info is None or info[0] != PAIRBAR_ID:
            continue
        try:
            backups.append((folder.stat().st_mtime, folder))
        except OSError:
            continue
    backups.sort(key=lambda x: x[0], reverse=True)
    # Keep newest original app; live rollback copies and manifest are untouched.
    return [("older-app-backup", folder) for _, folder in backups[1:]]


def install_exists(home: Path) -> bool:
    return any(app_info(p) is not None and app_info(p)[0] == PAIRBAR_ID for p in (
        Path("/Applications/Pairbar.app"), home / "Applications/Pairbar.app"))


def safe_artifacts(home: Path) -> list[tuple[str, Path]]:
    items = safe_downloads(home)
    if install_exists(home):
        items += safe_candidates(home) + safe_backup_surplus(home)
    return items


def git_output(repo: Path, args: list[str]) -> str:
    try:
        proc = subprocess.run(["git", *args], cwd=repo, stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL, text=True, timeout=8)
        return proc.stdout if proc.returncode == 0 else ""
    except (OSError, subprocess.TimeoutExpired):
        return ""


def worktree_report(repo: Path) -> None:
    print("\nGit worktrees (read-only):")
    if not (repo / ".git").exists():
        print("  Pairbar checkout not found")
        return
    result = git_output(repo, ["worktree", "list", "--porcelain"])
    if not result:
        print("  No worktree metadata found")
    for line in result.splitlines():
        if line.startswith("worktree "):
            print("  " + line[len("worktree "):])
        elif line.startswith(("branch ", "detached", "prunable ")):
            print("    " + line)
    stale = git_output(repo, ["worktree", "prune", "--dry-run", "--verbose"])
    for line in stale.splitlines()[:20]:
        print("  stale worktree metadata (not deleted): " + line)


def find_app_bundles(home: Path, maxdepth: int = 7) -> list[tuple[Path, str, str]]:
    roots = [Path("/Applications"), home / "Applications", home / "Desktop",
             home / "Downloads", home / "Developer"]
    found = []
    seen = set()
    for root in roots:
        if not root.is_dir() or root.is_symlink():
            continue
        for current, dirs, _ in os.walk(root, topdown=True, followlinks=False):
            path = Path(current)
            depth = len(path.relative_to(root).parts)
            for name in list(dirs):
                child = path / name
                if child.is_symlink() or name in SKIP_DIRS:
                    dirs.remove(name)
                    continue
                if name.endswith(".app") or ".app.pairbar-previous-" in name:
                    dirs.remove(name)
                    info = app_info(child)
                    if info and str(child) not in seen:
                        seen.add(str(child))
                        found.append((child, info[0], info[1]))
            if depth >= maxdepth:
                dirs[:] = []
    return sorted(found, key=lambda item: str(item[0]).lower())


def protected_app(path: Path, home: Path) -> bool:
    return path in {
        Path("/Applications/ChatGPT.app"), Path("/Applications/Pairbar.app"),
        home / "Applications/ChatGPT.app", home / "Applications/Pairbar.app",
    }


def preview(home: Path, repo: Path) -> None:
    print("PAIRBAR MAC INVENTORY | READ-ONLY")
    print("Protected: installed apps, account profiles/sessions, live rollback copy.")
    print("\nPairbar/ChatGPT application bundles:")
    apps = find_app_bundles(home)
    if not apps:
        print("  None found in scanned app/development folders")
    for path, identity, version in apps:
        status = "KEEP: installed app" if protected_app(path, home) else "REVIEW: never auto-removed"
        print(f"  [{status}] {path}\n      bundle={identity} version={version}")
    print("\nKnown disposable files (can move to Trash after review):")
    items = safe_artifacts(home)
    for kind, path in items:
        print(f"  [{kind}] {path}")
    if not items:
        print("  No known disposable files")
    print("  Latest rollback and latest local build retained.")
    worktree_report(repo)
    print("\nCommands:")
    print("  python3 scripts/mac-cleanup.py --trash-safe")
    print("  python3 scripts/mac-cleanup.py --trash-app '/full/path/to/an/old-copy.app'")
    print("  Trash still occupies disk space until emptied. Profiles are never touched.")


def trash_batch(items: list[tuple[str, Path]], home: Path) -> int:
    if not items:
        print("No qualifying artifacts; nothing changed.")
        return 0
    trash = home / ".Trash"
    if trash.is_symlink():
        print("NOT MOVED: Trash is a symlink", file=sys.stderr)
        return 2
    dest = trash / ("Pairbar-cleanup-" + dt.datetime.now().strftime("%Y%m%d-%H%M%S")
                    + "-" + str(os.getpid()))
    dest.mkdir(parents=True, exist_ok=False)
    moved = 0
    for label, source in items:
        if source.is_symlink() or not source.exists():
            continue
        target = dest / f"{moved+1:02d}-{source.name}"
        try:
            # Atomic on one volume; refuse cross-volume copies or deletions.
            source.rename(target)
        except OSError as exc:
            print(f"Skipped {source}: {exc}", file=sys.stderr)
            continue
        moved += 1
        print(f"  {label}: {source} -> {target}")
    if moved == 0:
        dest.rmdir()
    print(f"Moved {moved}/{len(items)} items to macOS Trash.")
    return 0 if moved == len(items) else 1


def explicit_app(home: Path, candidate: Path) -> tuple[str, Path]:
    if not candidate.is_absolute() or ".." in candidate.parts or candidate.is_symlink():
        raise ValueError("Provide a non-symlink absolute application path")
    allowed = [Path("/Applications"), home / "Applications", home / "Desktop",
               home / "Downloads", home / "Developer"]
    if not any(candidate != root and root in candidate.parents for root in allowed):
        raise ValueError("Outside scanned app folders")
    if protected_app(candidate, home):
        raise ValueError("The installed app is protected")
    if any(p in candidate.parts for p in (".git", ".Trash", "node_modules")):
        raise ValueError("Protected or generated directory")
    info = app_info(candidate)
    if not info:
        raise ValueError("Unrecognized Pairbar/ChatGPT app bundle metadata")
    if info[0] == CHATGPT_ID and not any(
        app_info(p) and app_info(p)[0] == CHATGPT_ID for p in (
            Path("/Applications/ChatGPT.app"), home / "Applications/ChatGPT.app")):
        raise ValueError("No other normal ChatGPT installation exists")
    if info[0] == PAIRBAR_ID and not install_exists(home):
        raise ValueError("No normal Pairbar installation exists")
    # Refuse while either app is running, including if a clone might be used.
    try:
        statuses = [
            subprocess.run(["/usr/bin/pgrep", "-x", name],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode
            for name in ("ChatGPT", "DualAccountSwitcher")
        ]
    except OSError as exc:
        raise ValueError("Cannot verify running app processes") from exc
    if 0 in statuses:
        raise ValueError("Close Pairbar and ChatGPT normally before moving a clone")
    manifest = home / "Library/Application Support/Pairbar Backups/last-installed-pairbar.txt"
    try:
        references = manifest.read_text().splitlines() if manifest.is_file() else []
    except OSError:
        references = []
    if str(candidate) in references:
        raise ValueError("App is referenced by the current rollback manifest")
    return "explicit-reviewed-app", candidate


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--scan", action="store_true", help="Read-only inventory (default)")
    modes.add_argument("--trash-safe", action="store_true", help="Move only known downloads and surplus test builds/backups to Trash")
    modes.add_argument("--trash-app", metavar="ABSOLUTE_PATH", help="Move one explicitly reviewed old app to Trash")
    args = parser.parse_args()
    home, repo = Path.home(), Path(__file__).resolve().parent.parent
    if args.trash_safe:
        items = safe_downloads(home)
        try:
            running = subprocess.run(["/usr/bin/pgrep", "-x", "DualAccountSwitcher"],
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
        except OSError:
            running = True
        if running:
            print("Pairbar is running: retaining app backups and build candidates.")
        elif install_exists(home):
            items += safe_candidates(home) + safe_backup_surplus(home)
        return trash_batch(items, home)
    if args.trash_app:
        try:
            item = explicit_app(home, Path(args.trash_app))
        except ValueError as exc:
            print("NOT MOVED:", exc, file=sys.stderr)
            return 2
        return trash_batch([item], home)
    preview(home, repo)
    return 0


if __name__ == "__main__":
    sys.exit(main())
