#!/usr/bin/env python3

from __future__ import annotations

import shutil
import sys
from pathlib import Path


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

    if not source_env.is_file():
        return 0

    workspace_symphony.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source_env, workspace_env)
    workspace_env.chmod(0o600)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
