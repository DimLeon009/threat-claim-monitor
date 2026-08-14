"""Validate local Markdown links and basic repository documentation hygiene."""

from __future__ import annotations

import re
import sys
from pathlib import Path
from urllib.parse import unquote


REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
MARKDOWN_LINK = re.compile(r"(?<!!)\[[^\]]+\]\(([^)]+)\)")
IGNORED_PREFIXES = ("http://", "https://", "mailto:", "#")


def markdown_files() -> list[Path]:
    return sorted(
        path
        for path in REPOSITORY_ROOT.rglob("*.md")
        if ".git" not in path.parts
    )


def validate_file(path: Path) -> list[str]:
    errors: list[str] = []
    content = path.read_text(encoding="utf-8")
    relative_path = path.relative_to(REPOSITORY_ROOT)

    if content and not content.endswith("\n"):
        errors.append(f"{relative_path}: missing final newline")

    for line_number, line in enumerate(content.splitlines(), start=1):
        if line.rstrip() != line:
            errors.append(f"{relative_path}:{line_number}: trailing whitespace")

    for match in MARKDOWN_LINK.finditer(content):
        target = match.group(1).strip()
        if target.startswith(IGNORED_PREFIXES) or target.startswith("<"):
            continue

        file_target = unquote(target.split("#", maxsplit=1)[0])
        if not file_target:
            continue

        resolved = (path.parent / file_target).resolve()
        if not resolved.exists():
            errors.append(f"{relative_path}: broken local link -> {target}")

    return errors


def main() -> int:
    errors = [error for path in markdown_files() for error in validate_file(path)]
    if errors:
        print("Documentation validation failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    print(f"Documentation validation passed ({len(markdown_files())} Markdown files).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

