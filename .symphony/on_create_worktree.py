#!/usr/bin/env python3

from __future__ import annotations

import shlex
import shutil
import sys
from pathlib import Path

MANAGED_BINARIES = ("symphony", "sym-codex")
LINEAR_PROJECT_SLUG = "LINEAR_PROJECT_SLUG"
LINEAR_TEST_PROJECT_SLUG = "LINEAR_TEST_PROJECT_SLUG"


def copy_env_local(source: Path, target: Path) -> None:
    if not source.is_file():
        return

    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, target)
    target.chmod(0o600)


def read_env_value(path: Path, key: str) -> str | None:
    if not path.is_file():
        return None

    for raw_line in path.read_text(encoding="utf-8").splitlines():
        parsed = parse_env_assignment(raw_line)

        if parsed is None:
            continue

        name, value = parsed

        if name == key:
            return value

    return None


def parse_env_assignment(raw_line: str) -> tuple[str, str] | None:
    try:
        tokens = shlex.split(raw_line, comments=True, posix=True)
    except ValueError:
        return None

    if not tokens:
        return None

    if tokens[0] == "export":
        tokens = tokens[1:]

    if not tokens or "=" not in tokens[0]:
        return None

    name, value = tokens[0].split("=", 1)
    return name.strip(), value


def set_env_value(path: Path, key: str, value: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    assignment = f"{key}={quote_env_value(value)}"

    if path.is_file():
        lines = path.read_text(encoding="utf-8").splitlines()
    else:
        lines = []

    replaced = False
    updated_lines = []

    for line in lines:
        parsed = parse_env_assignment(line)

        if parsed is not None and parsed[0] == key:
            updated_lines.append(assignment)
            replaced = True
        else:
            updated_lines.append(line)

    if not replaced:
        updated_lines.append(assignment)

    path.write_text("\n".join(updated_lines) + "\n", encoding="utf-8")
    path.chmod(0o600)


def quote_env_value(value: str) -> str:
    escaped = (
        value.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\n", "\\n")
        .replace("\r", "\\r")
        .replace("\t", "\\t")
    )

    return f'"{escaped}"'


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
    copy_env_local(
        source_repo / ".symphony" / ".env.local",
        workspace / ".symphony" / ".env.local",
    )
    test_project_slug = read_env_value(
        source_repo / ".symphony" / ".env",
        LINEAR_TEST_PROJECT_SLUG,
    )

    if test_project_slug:
        set_env_value(
            workspace / ".symphony" / ".env.local",
            LINEAR_PROJECT_SLUG,
            test_project_slug,
        )

    copy_env_local(source_repo / ".env.local", workspace / ".env.local")

    for binary_name in MANAGED_BINARIES:
        ensure_managed_symlink(workspace, binary_name)

    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
