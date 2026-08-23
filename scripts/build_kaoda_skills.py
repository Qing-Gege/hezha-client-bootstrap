#!/usr/bin/env python3
"""Build the deterministic user-level kaoda-wo skill bundle."""

from __future__ import annotations

import argparse
import hashlib
import json
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "skills" / "kaoda-wo"
CLIENTS = ("codex", "claude")


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def normalized_text(path: Path) -> bytes:
    """Keep the published text bundle identical on Unix and Windows runners."""
    return path.read_bytes().replace(b"\r\n", b"\n")


def read_source() -> tuple[dict, dict[str, bytes]]:
    protocol = json.loads((SOURCE / "protocol.json").read_text(encoding="utf-8"))
    version = protocol.get("version")
    if protocol.get("protocol_id") != "kaoda-wo" or not isinstance(version, str):
        raise SystemExit("invalid kaoda-wo protocol identity")

    files = {
        "protocol.json": normalized_text(SOURCE / "protocol.json"),
        **{
            f"clients/{client}/SKILL.md": normalized_text(SOURCE / client / "SKILL.md")
            for client in CLIENTS
        },
    }
    for name, content in files.items():
        if not content:
            raise SystemExit(f"empty kaoda-wo bundle file: {name}")
    return protocol, files


def build(output_directory: Path) -> Path:
    protocol, files = read_source()
    output_directory.mkdir(parents=True, exist_ok=True)
    version = protocol["version"]
    package_name = f"KaodaWoSkills-v{version}"
    output_path = output_directory / f"{package_name}.zip"
    manifest_files = [
        {"name": name, "size": len(content), "sha256": sha256(content)}
        for name, content in sorted(files.items())
    ]
    manifest = {
        "schema_version": 1,
        "package": package_name,
        "skill_id": protocol["protocol_id"],
        "version": version,
        "protocol_sha256": sha256(files["protocol.json"]),
        "clients": {
            "codex": {"source": "clients/codex/SKILL.md", "install_path": "~/.codex/skills/kaoda-wo/SKILL.md"},
            "claude": {"source": "clients/claude/SKILL.md", "install_path": "~/.claude/skills/kaoda-wo/SKILL.md"},
        },
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
        entries = {"manifest.json": json.dumps(manifest, ensure_ascii=False, indent=2).encode("utf-8") + b"\n", **files}
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
    print(json.dumps({"path": str(path), "size": path.stat().st_size, "sha256": sha256(path.read_bytes())}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
