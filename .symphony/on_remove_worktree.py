#!/usr/bin/env python3

from __future__ import annotations

import sys
from pathlib import Path

MANAGED_BINARIES = ("symphony", "sym-codex")


def managed_link_path(workspace: Path, binary_name: str) -> Path:
    return Path.home() / ".local" / "bin" / f"{binary_name}-{workspace.name}"


def remove_managed_symlink(workspace: Path, binary_name: str) -> None:
    target = workspace / binary_name
    link_path = managed_link_path(workspace, binary_name)

    if link_path.is_symlink() and link_path.readlink() == target:
        link_path.unlink()


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        script_name = Path(argv[0]).name if argv else "on_remove_worktree.py"
        print(f"usage: {script_name} <source_repo> <workspace>", file=sys.stderr)
        return 2

    _source_repo = Path(argv[1]).expanduser().resolve()
    workspace = Path(argv[2]).expanduser().resolve()

    for binary_name in MANAGED_BINARIES:
        remove_managed_symlink(workspace, binary_name)

    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
