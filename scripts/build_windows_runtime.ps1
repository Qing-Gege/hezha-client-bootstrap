param(
    [Parameter(Mandatory = $true)]
    [string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RuntimeVersion = "1.0.0"
$PixiVersion = "0.76.2"
$OfficeCliVersion = "1.0.143"
$PixiUrl = "https://github.com/prefix-dev/pixi/releases/download/v$PixiVersion/pixi-x86_64-pc-windows-msvc.zip"
$PixiSize = [int64]33438504
$PixiSha256 = "8e948f6b67104be30509ab7d91ac1878fdb7920e57e8b433dbfb7297468b102d"
$OfficeCliUrl = "https://github.com/iOfficeAI/OfficeCLI/releases/download/v$OfficeCliVersion/officecli-win-x64.exe"
$OfficeCliSize = [int64]33357736
$OfficeCliSha256 = "d4d4c10fced307e209744cf98a56b003a6e613424fd651b08469274704afd2c6"
$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot ".."))
$SourceRuntime = Join-Path $RepositoryRoot "runtime\$RuntimeVersion"
$PixiPackVersion = "0.7.10"
$PixiPackUrl = "https://github.com/Quantco/pixi-pack/releases/download/v$PixiPackVersion/pixi-pack-x86_64-pc-windows-msvc.exe"
$PixiPackSize = [int64]14036480
$PixiPackSha256 = "2cbfeea1c6eadedcfc29c041c90d48b52212d89fdf9b0a124fc137f73d12c29d"
$PixiUnpackUrl = "https://github.com/Quantco/pixi-pack/releases/download/v$PixiPackVersion/pixi-unpack-x86_64-pc-windows-msvc.exe"
$PixiUnpackSize = [int64]15029248
$PixiUnpackSha256 = "f0409bf7ba71ade130bc2f74aca2c7a923af207f7cfa40bad82b3bff2d20bd8b"
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$PackageName = "DocumentRuntime-win-x64"
$PackageRoot = Join-Path $OutputDirectory $PackageName
$WorkDirectory = Join-Path $OutputDirectory ".build-$PID"

function Get-Sha256([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-Download([string]$Path, [int64]$Size, [string]$Sha256, [string]$Label) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Label was not downloaded"
    }
    if ((Get-Item -LiteralPath $Path).Length -ne $Size) {
        throw "$Label size mismatch"
    }
    if ((Get-Sha256 $Path) -ne $Sha256) {
        throw "$Label SHA-256 mismatch"
    }
}

function Invoke-Captured([string]$Executable, [string[]]$Arguments) {
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $global:LASTEXITCODE = $null
        $output = @(& $Executable @Arguments 2>&1 | ForEach-Object { $_.ToString() })
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }
    if ($null -eq $exitCode) {
        throw "command could not be started: $Executable"
    }
    if ($exitCode -ne 0) {
        throw "command failed with exit code $exitCode: $Executable"
    }
    return $output
}

try {
    $null = New-Item -ItemType Directory -Path $OutputDirectory -Force
    $null = New-Item -ItemType Directory -Path $WorkDirectory -Force
    $null = New-Item -ItemType Directory -Path $PackageRoot -Force
    $extractRoot = Join-Path $WorkDirectory "pixi"
    $null = New-Item -ItemType Directory -Path $extractRoot -Force
    $pixiArchive = Join-Path $WorkDirectory "pixi.zip"
    $officecliDownload = Join-Path $WorkDirectory "officecli.exe"
    $pixiPackDownload = Join-Path $WorkDirectory "pixi-pack.exe"
    $pixiUnpackDownload = Join-Path $WorkDirectory "pixi-unpack.exe"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -UseBasicParsing -Uri $PixiUrl -OutFile $pixiArchive
    Invoke-WebRequest -UseBasicParsing -Uri $OfficeCliUrl -OutFile $officecliDownload
    Invoke-WebRequest -UseBasicParsing -Uri $PixiPackUrl -OutFile $pixiPackDownload
    Invoke-WebRequest -UseBasicParsing -Uri $PixiUnpackUrl -OutFile $pixiUnpackDownload
    Assert-Download $pixiArchive $PixiSize $PixiSha256 "Pixi archive"
    Assert-Download $officecliDownload $OfficeCliSize $OfficeCliSha256 "OfficeCLI"
    Assert-Download $pixiPackDownload $PixiPackSize $PixiPackSha256 "pixi-pack"
    Assert-Download $pixiUnpackDownload $PixiUnpackSize $PixiUnpackSha256 "pixi-unpack"

    Expand-Archive -LiteralPath $pixiArchive -DestinationPath $extractRoot -Force
    $pixiSource = Join-Path $extractRoot "pixi.exe"
    if (-not (Test-Path -LiteralPath $pixiSource -PathType Leaf)) {
        throw "Pixi archive did not contain pixi.exe"
    }

    Copy-Item -LiteralPath (Join-Path $SourceRuntime "pixi.toml") -Destination $PackageRoot -Force
    Copy-Item -LiteralPath (Join-Path $SourceRuntime "pixi.lock") -Destination $PackageRoot -Force
    Copy-Item -LiteralPath $pixiSource -Destination (Join-Path $PackageRoot "pixi.exe") -Force
    Copy-Item -LiteralPath $officecliDownload -Destination (Join-Path $PackageRoot "officecli.exe") -Force
    Copy-Item -LiteralPath $pixiUnpackDownload -Destination (Join-Path $PackageRoot "pixi-unpack.exe") -Force
    Copy-Item -LiteralPath (Join-Path $RepositoryRoot "package\install.cmd") -Destination $PackageRoot -Force
    # package.json is generated below from the verified OfficeCLI output.
    $manifestPath = Join-Path $SourceRuntime "pixi.toml"
    $officecliPath = $officecliDownload
    $environmentArchive = Join-Path $PackageRoot "environment.tar"
    & $pixiPackDownload --platform win-64 --output-file $environmentArchive $manifestPath
    if ($LASTEXITCODE -ne 0) {
        throw "pixi-pack failed with exit code $LASTEXITCODE"
    }

    $officeVersion = (Invoke-Captured $officecliPath @("--version"))[0].Trim()
    $null = Invoke-Captured $officecliPath @("help")
    $packageJsonPath = Join-Path $PackageRoot "package.json"
    $packageManifest = [ordered]@{
        schema_version = 1
        package = $PackageName
        runtime_version = $RuntimeVersion
        os = "windows"
        arch = "x64"
        pixi_version = $PixiVersion
        pixi_pack_version = $PixiPackVersion
        officecli_version = $officeVersion
        environment_archive = "environment.tar"
        install_command = "install.cmd"
    }
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($packageJsonPath, ($packageManifest | ConvertTo-Json -Depth 8), $utf8)

    $packageManifestRows = @(
        Get-ChildItem -LiteralPath $PackageRoot -File |
            Where-Object { $_.Name -ne "package-manifest.json" } |
            Sort-Object Name |
            ForEach-Object {
                [ordered]@{
                    name = $_.Name
                    size = $_.Length
                    sha256 = Get-Sha256 $_.FullName
                }
            }
    )
    [IO.File]::WriteAllText(
        (Join-Path $PackageRoot "package-manifest.json"),
        ([ordered]@{
            schema_version = 1
            package = $PackageName
            files = $packageManifestRows
        } | ConvertTo-Json -Depth 8),
        $utf8
    )
    $zipPath = Join-Path $OutputDirectory "$PackageName.zip"
    if (Test-Path -LiteralPath $zipPath) {
        Remove-Item -LiteralPath $zipPath -Force
    }
    & tar.exe -a -c -f $zipPath -C $OutputDirectory $PackageName
    if ($LASTEXITCODE -ne 0) {
        throw "tar failed with exit code $LASTEXITCODE"
    }
    Write-Output ($zipPath)
}
finally {
    if (Test-Path -LiteralPath $WorkDirectory) {
        Remove-Item -LiteralPath $WorkDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}
