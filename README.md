# HeZha Client Bootstrap

`hezha-client-bootstrap` provides the deterministic, user-scoped local document
runtime and the client-level `kaoda-wo` controller used by HeZha legal-skill MCP
clients. It installs and verifies OfficeCLI, Poppler, Tesseract, the required
Chinese and English OCR data, and the local client skill before an MCP
connection is added and the client is restarted once.

This repository does **not** publish a custom installer or executable. The two
entrypoints are reviewable text:

- `bootstrap/macos.sh`, executed by the system `/bin/zsh` on macOS 11+.
- `bootstrap/windows.ps1`, executed by Windows PowerShell on Windows 10+.

The entrypoints download only pinned upstream Pixi and OfficeCLI releases plus
the versioned `pixi.toml` and `pixi.lock` in this repository. Every download is
checked for exact size and SHA-256 before extraction or execution. macOS also
checks the upstream Developer ID and pinned Team ID for both native
executables.

## Trust model

The customer installation prompt must pin an immutable repository version,
file size, and SHA-256 for the selected entrypoint. It must never execute the
default branch, `latest`, or an unverified network stream. The bootstrap files
contain no MCP URL, law-firm identity, bearer token, case data, or user file
path.

The bootstrap process:

1. checks the supported OS, native architecture, install path, and free space;
2. reuses a healthy fixed-path runtime without downloading anything;
3. downloads the four pinned inputs in parallel when installation is needed;
4. verifies sizes, SHA-256 values, archive contents, and macOS signatures;
5. installs the locked Pixi environment without post-link scripts;
6. checks OfficeCLI, four Poppler commands, Tesseract, and
   `eng/chi_sim/chi_tra/osd`;
7. publishes the verified OfficeCLI into the stable user-scoped
   `LegalSkills/bin` directory, prepends that directory to the user's PATH,
   and atomically writes `environment.json`;
8. removes the rebuildable download and package cache.

The calling Agent may configure a user-level MCP connection only after the
bootstrap exits successfully.

The `kaoda-wo` bundle is a text-only, versioned client skill. Its Codex and
Claude Code adapters are installed separately at user scope by the pinned
`bootstrap/install-kaoda-macos.sh` or `bootstrap/install-kaoda-windows.ps1`
entrypoint. The controller must be present before a HeZha legal task can load
an entity or document skill.

The OfficeCLI release tag and asset digest stay pinned exactly. Health checks
parse the binary's reported semantic version and require it to be at least the
declared minimum, because platform assets from one release may report a newer
compatible build version. Health failures name the failing command or missing
language instead of collapsing every cause into one generic message.

On macOS, the PATH entry is persisted in `~/.zprofile` and synchronized to the
current login GUI session. On Windows, it is persisted in the User environment
and synchronized to the bootstrap process. Healthy runtime reuse also repairs
the stable OfficeCLI command and PATH entry. Pixi, Poppler, and Tesseract remain
behind the absolute command arrays in `environment.json`; they are not exposed
through PATH.

## Interfaces

```text
/bin/zsh bootstrap/macos.sh install
/bin/zsh bootstrap/macos.sh inspect
/bin/zsh bootstrap/install-kaoda-macos.sh [codex|claude]

powershell.exe -NoLogo -NoProfile -NonInteractive \
  -ExecutionPolicy Bypass -File bootstrap/windows.ps1 Install
powershell.exe -NoLogo -NoProfile -NonInteractive \
  -ExecutionPolicy Bypass -File bootstrap/windows.ps1 Inspect
powershell.exe -NoLogo -NoProfile -NonInteractive \
  -ExecutionPolicy Bypass -File bootstrap/install-kaoda-windows.ps1 -Client [codex|claude]
```

`ExecutionPolicy Bypass` is limited to the one bootstrap process. The script
does not change machine or user policy. A Group Policy or application-control
block is a hard failure; the bootstrap does not weaken or work around it.

Progress is written to stderr. A successful invocation writes one compact JSON
result to stdout. Neither stream may contain credentials.

## Development

Run the contract suite with the standard-library Python available to
maintainers:

```bash
python3 -m unittest discover -s tests -v
/bin/zsh -n bootstrap/macos.sh
/bin/zsh bootstrap/macos.sh inspect
```

Windows syntax and `Inspect` are also checked by the GitHub Actions Windows
runner. Full cold-install validation remains a real-machine release gate.

## Release discipline

1. Publish changed runtime files in a dedicated commit and pin its full commit
   hash in both entrypoints.
2. Update the runtime version, pinned upstream assets, lock file, and tests.
3. Validate cold install and healthy reuse on each claimed platform.
4. Generate `runtime/<version>/bootstrap.json` with final entrypoint sizes and
   SHA-256 values.
5. Commit and create an immutable `v<version>` tag.
6. Pin the customer installation prompt to the tagged raw URL, size, and
   SHA-256. Never pin to a branch.

The same release also carries the deterministic `KaodaWoSkills-v<version>.zip`
asset. Pin its release URL, size, and SHA-256 in the customer installation
catalog; do not fetch a default branch or an unverified raw skill file.
