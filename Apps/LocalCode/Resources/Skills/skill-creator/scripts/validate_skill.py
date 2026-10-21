#!/usr/bin/env python3
"""Validate a workspace skill without modifying it."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

import yaml


NAME_PATTERN = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
LINK_PATTERN = re.compile(r"\[[^\]]*\]\(([^)]+)\)")


def parse_frontmatter(text: str) -> dict[str, object]:
    normalized = text.replace("\r\n", "\n").replace("\r", "\n")
    lines = normalized.split("\n")
    if not lines or lines[0].strip() != "---":
        raise ValueError("Missing YAML frontmatter delimited by ---. ")
    try:
        closing = next(index for index, line in enumerate(lines[1:], 1) if line.strip() == "---")
    except StopIteration as error:
        raise ValueError("Missing closing YAML frontmatter delimiter.") from error
    value = yaml.safe_load("\n".join(lines[1:closing]))
    if not isinstance(value, dict):
        raise ValueError("Frontmatter must be a YAML mapping.")
    return value


def is_within(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("skill", help="Project-relative path under .agents/skills")
    args = parser.parse_args()

    cwd = Path.cwd().resolve()
    supplied = Path(args.skill)
    errors: list[str] = []
    warnings: list[str] = []
    if supplied.is_absolute():
        errors.append("Skill path must be project-relative.")
    if ".." in supplied.parts:
        errors.append("Skill path must not contain '..'.")
    logical_skill_dir = cwd / supplied
    skill_dir = logical_skill_dir.resolve()
    if not is_within(skill_dir, cwd):
        errors.append("Skill path resolves outside the selected project.")
    parts = skill_dir.parts
    valid_location = any(
        parts[index : index + 2] == (".agents", "skills") and index + 3 == len(parts)
        for index in range(len(parts) - 2)
    )
    if not valid_location:
        errors.append("Skill must be stored under .agents/skills/<skill-name>.")
    if not supplied.is_absolute():
        current = cwd
        for component in supplied.parts:
            if component in {"", ".", ".."}:
                continue
            current /= component
            if current.is_symlink():
                errors.append(f"Skill path contains a symbolic link: {current.relative_to(cwd)}")
                break

    skill_file = skill_dir / "SKILL.md"
    if skill_file.is_symlink():
        errors.append("SKILL.md must not be a symbolic link.")
    if not skill_file.is_file():
        errors.append("SKILL.md does not exist.")
        text = ""
        metadata: dict[str, object] = {}
    else:
        try:
            text = skill_file.read_text(encoding="utf-8")
        except (OSError, UnicodeError) as error:
            errors.append(f"Unable to read UTF-8 SKILL.md: {error}")
            text = ""
        try:
            metadata = parse_frontmatter(text) if text else {}
        except (ValueError, yaml.YAMLError) as error:
            errors.append(str(error))
            metadata = {}

    name = metadata.get("name")
    description = metadata.get("description")
    unknown_fields = sorted(str(key) for key in metadata if key not in {"name", "description"})
    if unknown_fields:
        errors.append(f"Unsupported frontmatter field(s): {', '.join(unknown_fields)}")
    if not isinstance(name, str) or not name.strip():
        errors.append("Frontmatter field 'name' must be a nonempty string.")
    else:
        name = " ".join(name.split())
        if len(name) > 64:
            errors.append("Skill name exceeds the 64-character limit.")
        if not NAME_PATTERN.fullmatch(name):
            errors.append("Skill name must use lowercase letters, digits, and single hyphens.")
        if skill_dir.name != name:
            errors.append("Skill directory name must match frontmatter 'name'.")

    if not isinstance(description, str) or not description.strip():
        errors.append("Frontmatter field 'description' must be a nonempty string.")
    else:
        description = " ".join(description.split())
        if len(description) > 1024:
            errors.append("Description exceeds the 1,024-character limit.")

    if skill_file.is_file() and skill_file.stat().st_size > 8000:
        warnings.append(
            "SKILL.md exceeds the 8,000-byte direct-injection limit; loading it requires a file read."
        )

    metadata_file = skill_dir / "agents" / "openai.yaml"
    if metadata_file.exists():
        errors.append("agents/openai.yaml is not part of the supported skill format.")

    for target in LINK_PATTERN.findall(text):
        target = target.strip().strip("<>").split("#", 1)[0]
        if not target or "://" in target or target.startswith("#"):
            continue
        logical_linked = skill_dir / target
        linked = logical_linked.resolve()
        if not is_within(linked, skill_dir):
            errors.append(f"Linked resource resolves outside the skill directory: {target}")
        elif logical_linked.is_symlink():
            errors.append(f"Linked resource must not be a symbolic link: {target}")
        elif not linked.exists():
            errors.append(f"Linked resource does not exist: {target}")

    result = {
        "description_length": len(description) if isinstance(description, str) else None,
        "errors": errors,
        "name": name if isinstance(name, str) else None,
        "skill": supplied.as_posix(),
        "skill_bytes": skill_file.stat().st_size if skill_file.is_file() else None,
        "valid": not errors,
        "warnings": warnings,
    }
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0 if not errors else 1


if __name__ == "__main__":
    raise SystemExit(main())
