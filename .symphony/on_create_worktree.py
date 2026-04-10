#!/usr/bin/env python3

from __future__ import annotations

import shutil
import sys
from pathlib import Path

MANAGED_BINARIES = ("symphony", "sym-codex")


def ensure_managed_symlink(workspace: Path, binary_name: str) -> None:
    target = workspace / binary_name
    link_path = managed_link_path(workspace, binary_name)
    link_path.parent.mkdir(parents=True, exist_ok=True)

    if link_path.is_symlink():
        if link_path.readlink() == target:
            return

        link_path.unlink()
    elif link_path.exists():
        if link_path.is_dir():
            raise IsADirectoryError(f"cannot replace directory with symlink: {link_path}")

        link_path.unlink()

    link_path.symlink_to(target)


def managed_link_path(workspace: Path, binary_name: str) -> Path:
    return Path.home() / ".local" / "bin" / f"{binary_name}-{workspace.name}"


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        script_name = Path(argv[0]).name if argv else "on_create_worktree.py"
        print(f"usage: {script_name} <source_repo> <workspace>", file=sys.stderr)
        return 2

    source_repo = Path(argv[1]).expanduser().resolve()
    workspace = Path(argv[2]).expanduser().resolve()
    source_env = source_repo / ".symphony" / ".env.local"
    workspace_symphony = workspace / ".symphony"
    workspace_env = workspace_symphony / ".env.local"

    if source_env.is_file():
        workspace_symphony.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source_env, workspace_env)
        workspace_env.chmod(0o600)

    for binary_name in MANAGED_BINARIES:
        ensure_managed_symlink(workspace, binary_name)

    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
