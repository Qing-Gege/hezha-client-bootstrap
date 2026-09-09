#!/usr/bin/env python3
"""Build the deterministic user-level core skill bundle."""

from __future__ import annotations

import argparse
import hashlib
import json
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "skills" / "core"
CLIENTS = ("codex", "claude")


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def normalized_text(path: Path) -> bytes:
    """Keep the published text bundle identical on Unix and Windows runners."""
    return path.read_bytes().replace(b"\r\n", b"\n")


def read_source() -> tuple[dict, dict[str, bytes]]:
    catalog = json.loads((SOURCE / "manifest.json").read_text(encoding="utf-8"))
    version = catalog.get("version")
    skills = catalog.get("skills")
    if catalog.get("pack_id") != "core" or not isinstance(version, str):
        raise SystemExit("invalid core skill pack identity")
    if not isinstance(skills, list) or not skills:
        raise SystemExit("core skill pack has no skills")

    files: dict[str, bytes] = {
        "pack.manifest.json": normalized_text(SOURCE / "manifest.json"),
    }
    seen: set[str] = set()
    for item in skills:
        if not isinstance(item, dict):
            raise SystemExit("invalid core skill entry")
        skill_id = item.get("skill_id")
        skill_version = item.get("version")
        if not isinstance(skill_id, str) or not isinstance(skill_version, str):
            raise SystemExit("core skill identity is incomplete")
        if skill_id in seen:
            raise SystemExit(f"duplicate core skill: {skill_id}")
        seen.add(skill_id)
        skill_source = SOURCE / skill_id / "SKILL.md"
        if not skill_source.is_file():
            raise SystemExit(f"missing core skill: {skill_id}")
        body = normalized_text(skill_source)
        if not body:
            raise SystemExit(f"empty core skill: {skill_id}")
        skill_manifest = (
            json.dumps(
                {
                    "schema_version": 1,
                    "pack_id": "core",
                    "skill_id": skill_id,
                    "version": skill_version,
                    "title": item.get("title"),
                },
                ensure_ascii=False,
                indent=2,
            )
            + "\n"
        ).encode("utf-8")
        files[f"skills/{skill_id}/manifest.json"] = skill_manifest
        for client in CLIENTS:
            files[f"skills/{skill_id}/clients/{client}/SKILL.md"] = body
    return catalog, files


def build(output_directory: Path) -> Path:
    catalog, files = read_source()
    output_directory.mkdir(parents=True, exist_ok=True)
    version = catalog["version"]
    package_name = f"CoreSkills-v{version}"
    output_path = output_directory / f"{package_name}.zip"
    manifest_files = [
        {"name": name, "size": len(content), "sha256": sha256(content)}
        for name, content in sorted(files.items())
    ]
    skills = []
    for item in catalog["skills"]:
        skill_id = item["skill_id"]
        skills.append(
            {
                "skill_id": skill_id,
                "version": item["version"],
                "title": item.get("title"),
                "clients": {
                    "codex": {
                        "source": f"skills/{skill_id}/clients/codex/SKILL.md",
                        "install_path": f"~/.codex/skills/{skill_id}/SKILL.md",
                    },
                    "claude": {
                        "source": f"skills/{skill_id}/clients/claude/SKILL.md",
                        "install_path": f"~/.claude/skills/{skill_id}/SKILL.md",
                    },
                },
            }
        )
    manifest = {
        "schema_version": 1,
        "package": package_name,
        "pack_id": "core",
        "version": version,
        "pack_manifest_sha256": sha256(files["pack.manifest.json"]),
        "skills": skills,
        "files": manifest_files,
    }
    if output_path.exists():
        output_path.unlink()
    with zipfile.ZipFile(
        output_path,
        mode="w",
        compression=zipfile.ZIP_DEFLATED,
        compresslevel=9,
    ) as archive:
        entries = {
            "manifest.json": json.dumps(manifest, ensure_ascii=False, indent=2).encode("utf-8")
            + b"\n",
            **files,
        }
        for name, content in sorted(entries.items()):
            info = zipfile.ZipInfo(name, date_time=(2020, 1, 1, 0, 0, 0))
            info.create_system = 0
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o600 << 16
            archive.writestr(info, content)
    return output_path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-directory", type=Path, required=True)
    args = parser.parse_args()
    path = build(args.output_directory)
    print(
        json.dumps(
            {
                "path": str(path),
                "size": path.stat().st_size,
                "sha256": sha256(path.read_bytes()),
            }
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
