from __future__ import annotations

import hashlib
import json
import platform
import re
import subprocess
import tempfile
import zipfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MACOS = ROOT / "bootstrap" / "macos.sh"
WINDOWS = ROOT / "bootstrap" / "windows.ps1"
MACOS_SKILL_INSTALLER = ROOT / "bootstrap" / "install-kaoda-macos.sh"
WINDOWS_SKILL_INSTALLER = ROOT / "bootstrap" / "install-kaoda-windows.ps1"
RUNTIME = ROOT / "runtime" / "1.0.0"
CATALOG = RUNTIME / "bootstrap.json"


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


class BootstrapContractTests(unittest.TestCase):
    def test_catalog_pins_published_entrypoints_and_runtime_files(self) -> None:
        catalog = json.loads(CATALOG.read_text(encoding="utf-8"))
        self.assertEqual(catalog["schema_version"], 1)
        self.assertEqual(catalog["bootstrap_version"], "1.0.5")
        self.assertEqual(catalog["runtime_version"], "1.0.0")
        self.assertFalse(catalog["policy"]["publishes_custom_binary"])
        self.assertTrue(catalog["policy"]["silent_preflight"])
        self.assertTrue(catalog["policy"]["modifies_path"])
        self.assertEqual(catalog["policy"]["path_scope"], "user")
        entrypoints = {item["os"]: item for item in catalog["entrypoints"]}
        self.assertEqual(set(entrypoints), {"macos", "windows"})
        for os_name, path in (("macos", MACOS), ("windows", WINDOWS)):
            item = entrypoints[os_name]
            self.assertEqual(item["size"], path.stat().st_size)
            self.assertEqual(item["sha256"], sha256(path))
            self.assertIn(catalog["source_commit"], item["url"])
            self.assertNotIn("/latest/", item["url"])
        for item in catalog["runtime_files"]:
            path = RUNTIME / item["name"]
            self.assertEqual(item["size"], path.stat().st_size)
            self.assertEqual(item["sha256"], sha256(path))
            self.assertIn(catalog["runtime_revision"], item["url"])

    def test_runtime_files_match_pinned_script_contract(self) -> None:
        expected = {
            "pixi.toml": (
                509,
                "43e641a0feab37c85f57d1fc578a7b990a59193cff8acb3e11594dd6df1b2428",
            ),
            "pixi.lock": (
                82251,
                "8e5f2fbe189c18ca9a4e42ab94a1eaf457c44b8b1e4534c6745ab6b91834515c",
            ),
        }
        scripts = MACOS.read_text(encoding="utf-8") + WINDOWS.read_text(
            encoding="utf-8"
        )
        for name, (size, digest) in expected.items():
            path = RUNTIME / name
            self.assertEqual(path.stat().st_size, size)
            self.assertEqual(sha256(path), digest)
            self.assertIn(str(size), scripts)
            self.assertIn(digest, scripts)

    def test_entrypoints_expose_only_install_and_inspect(self) -> None:
        macos = MACOS.read_text(encoding="utf-8")
        windows = WINDOWS.read_text(encoding="utf-8")
        self.assertIn("usage: macos.sh [install|inspect]", macos)
        self.assertRegex(
            windows,
            r'\[ValidateSet\("Install", "Inspect"\)\]',
        )

    def test_kaoda_skill_installers_are_pinned_and_client_scoped(self) -> None:
        macos = MACOS_SKILL_INSTALLER.read_text(encoding="utf-8")
        windows = WINDOWS_SKILL_INSTALLER.read_text(encoding="utf-8")
        combined = macos + windows
        self.assertIn('KaodaWoSkills-v${SKILL_VERSION}.zip', macos)
        self.assertIn('KaodaWoSkills-v$SkillVersion.zip', windows)
        self.assertIn('SKILL_VERSION="1.6.0"', macos)
        self.assertIn('$SkillVersion = "1.6.0"', windows)
        self.assertIn(
            "1ea0d60bcbcd13ecbb4294ece3de75f868c529ee9ff69ac0f7ceae4611e80496",
            combined,
        )
        self.assertIn("v1.0.7", combined)
        self.assertNotIn("/latest/", combined)
        self.assertNotIn("releases/latest", combined)
        self.assertIn("$HOME/.codex/skills", macos)
        self.assertIn("$HOME/.claude/skills", macos)
        self.assertIn(".codex\\skills", windows)
        self.assertIn(".claude\\skills", windows)
        self.assertIn("user_scope_only", macos)
        self.assertIn("user_scope_only", windows)

    def test_kaoda_bundle_is_deterministic_and_contains_both_clients(self) -> None:
        import sys

        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(
                [
                    sys.executable,
                    "scripts/build_kaoda_skills.py",
                    "--output-directory",
                    directory,
                ],
                cwd=ROOT,
                check=True,
                capture_output=True,
                text=True,
            )
            output = json.loads(result.stdout)
            path = Path(output["path"])
            self.assertEqual(path.name, "KaodaWoSkills-v1.6.0.zip")
            with zipfile.ZipFile(path) as archive:
                self.assertEqual(
                    set(archive.namelist()),
                    {
                        "manifest.json",
                        "protocol.json",
                        "clients/codex/SKILL.md",
                        "clients/claude/SKILL.md",
                    },
                )
                manifest = json.loads(archive.read("manifest.json"))
                self.assertEqual(manifest["skill_id"], "kaoda-wo")
                self.assertEqual(manifest["version"], "1.6.0")
                self.assertEqual(
                    manifest["protocol_sha256"],
                    sha256_bytes(archive.read("protocol.json")),
                )

    def test_entrypoints_preserve_security_contract(self) -> None:
        combined = (
            MACOS.read_text(encoding="utf-8")
            + WINDOWS.read_text(encoding="utf-8")
        )
        for forbidden in (
            "/latest/",
            "releases/latest",
            "brew install",
            "sudo ",
            "Authorization: Bearer",
            "LEGAL_MCP_",
            "run-post-link-scripts",
            "tls-no-verify",
        ):
            self.assertNotIn(forbidden, combined)
        for required in (
            "--locked",
            "--no-config",
            "environment.json",
            "chi_sim",
            "chi_tra",
            "Developer ID Application:",
            "minimum",
            "officecli_command_path",
            "path_entry",
        ):
            self.assertIn(required, combined)
        urls = re.findall(r'https://[^"\s]+', combined)
        self.assertTrue(urls)
        self.assertTrue(
            all(
                url.startswith("https://github.com/")
                or url.startswith("https://raw.githubusercontent.com/")
                for url in urls
            )
        )
        for pinned_path in (
            "releases/download/v0.76.2/",
            "799cc8e9e88c3293a2f38e40bf0cad93703d663e",
        ):
            self.assertIn(pinned_path, combined)

    def test_officecli_release_and_health_versions_are_separate(self) -> None:
        macos = MACOS.read_text(encoding="utf-8")
        windows = WINDOWS.read_text(encoding="utf-8")
        self.assertIn('OFFICECLI_RELEASE_VERSION="1.0.143"', macos)
        self.assertIn('OFFICECLI_MINIMUM_VERSION="1.0.143"', macos)
        self.assertIn('$OfficeCliReleaseVersion = "1.0.143"', windows)
        self.assertIn('$OfficeCliMinimumVersion = [Version]"1.0.143"', windows)
        self.assertIn(
            "releases/download/v${OFFICECLI_RELEASE_VERSION}/", macos
        )
        self.assertIn("releases/download/v$OfficeCliReleaseVersion/", windows)
        self.assertNotIn('-notlike "*$OfficeCliVersion*"', windows)
        self.assertIn("Get-FirstCapturedLine", windows)
        self.assertIn("Get-ReportedVersion", windows)

    def test_officecli_is_published_to_a_user_scoped_path(self) -> None:
        macos = MACOS.read_text(encoding="utf-8")
        windows = WINDOWS.read_text(encoding="utf-8")
        self.assertIn('BIN_DIR="${BASE_DIR}/bin"', macos)
        self.assertIn('local profile="${HOME}/.zprofile"', macos)
        self.assertIn("/bin/launchctl setenv PATH", macos)
        self.assertIn('$script:BinDir = Join-Path $baseDir "bin"', windows)
        self.assertIn(
            '[Environment]::SetEnvironmentVariable("Path", $updatedUserPath, "User")',
            windows,
        )
        self.assertIn("Publish-OfficeCliCommand", windows)
        self.assertIn("publish_officecli_command", macos)

    @unittest.skipUnless(platform.system() == "Darwin", "requires macOS")
    def test_macos_entrypoint_has_valid_zsh_syntax(self) -> None:
        subprocess.run(["/bin/zsh", "-n", str(MACOS)], check=True)

    @unittest.skipUnless(platform.system() == "Darwin", "requires macOS")
    def test_macos_inspect_is_read_only_json(self) -> None:
        result = subprocess.run(
            ["/bin/zsh", str(MACOS), "inspect"],
            check=True,
            capture_output=True,
            text=True,
        )
        payload = json.loads(result.stdout)
        self.assertEqual(payload["bootstrap_version"], "1.0.5")
        self.assertEqual(payload["runtime_version"], "1.0.0")
        self.assertEqual(payload["os"], "macos")
        self.assertTrue(payload["user_scope_only"])
        self.assertTrue(payload["modifies_path"])
        self.assertEqual(payload["path_scope"], "user")
        self.assertFalse(payload["requires_admin"])
        self.assertEqual(result.stderr, "")


if __name__ == "__main__":
    unittest.main()
