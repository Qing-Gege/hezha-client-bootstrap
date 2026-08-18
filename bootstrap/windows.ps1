param(
    [ValidateSet("Install", "Inspect")]
    [string]$Command = "Install"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$BootstrapVersion = "1.0.5"
$RuntimeVersion = "1.0.0"
$PixiVersion = "0.76.2"
$OfficeCliReleaseVersion = "1.0.143"
$OfficeCliMinimumVersion = [Version]"1.0.143"
$MinimumFreeSpaceBytes = [int64]1610612736
$Repository = "Qing-Gege/hezha-client-bootstrap"
$RuntimeRevision = "799cc8e9e88c3293a2f38e40bf0cad93703d663e"
$RuntimeBaseUrl = "https://raw.githubusercontent.com/$Repository/$RuntimeRevision/runtime/$RuntimeVersion"
$ManifestUrl = "$RuntimeBaseUrl/pixi.toml"
$ManifestSize = [int64]509
$ManifestSha256 = "43e641a0feab37c85f57d1fc578a7b990a59193cff8acb3e11594dd6df1b2428"
$LockUrl = "$RuntimeBaseUrl/pixi.lock"
$LockSize = [int64]82251
$LockSha256 = "8e5f2fbe189c18ca9a4e42ab94a1eaf457c44b8b1e4534c6745ab6b91834515c"
$RequiredLanguages = @("eng", "chi_sim", "chi_tra", "osd")
$script:WorkDir = $null

function Write-Stage {
    param([int]$Number, [string]$Message)
    [Console]::Error.WriteLine("[$Number/6] $Message")
}

function Stop-Bootstrap {
    param([string]$Message)
    throw "LegalSkills bootstrap failed: $Message"
}

function Get-Sha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-File {
    param(
        [string]$Path,
        [int64]$ExpectedSize,
        [string]$ExpectedSha256,
        [string]$Label
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Stop-Bootstrap "$Label was not downloaded"
    }
    if ((Get-Item -LiteralPath $Path).Length -ne $ExpectedSize) {
        Stop-Bootstrap "$Label size mismatch"
    }
    if ((Get-Sha256 -Path $Path) -ne $ExpectedSha256) {
        Stop-Bootstrap "$Label SHA-256 mismatch"
    }
}

function Invoke-ParallelDownloads {
    param([array]$Downloads)
    $clients = @()
    $tasks = @()
    try {
        foreach ($download in $Downloads) {
            $client = New-Object System.Net.WebClient
            $clients += $client
            $tasks += $client.DownloadFileTaskAsync(
                [Uri]$download.Url,
                [string]$download.Path
            )
        }
        [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]$tasks)
    }
    finally {
        foreach ($client in $clients) {
            $client.Dispose()
        }
    }
}

function Install-AtomicFile {
    param([string]$Source, [string]$Destination)
    if (Test-Path -LiteralPath $Destination -PathType Leaf) {
        $backup = "$Destination.backup.$PID"
        [IO.File]::Replace($Source, $Destination, $backup, $true)
        Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
    }
    else {
        [IO.File]::Move($Source, $Destination)
    }
}

function Add-PathEntry {
    param([AllowNull()][string]$PathValue, [string]$Entry)
    $entries = @()
    if (-not [string]::IsNullOrWhiteSpace($PathValue)) {
        $entries = @(
            $PathValue -split ";" |
                ForEach-Object { $_.Trim() } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
    }
    $normalizedEntry = $Entry.TrimEnd("\")
    foreach ($existing in $entries) {
        if ($existing.TrimEnd("\") -ieq $normalizedEntry) {
            return ($entries -join ";")
        }
    }
    return (@($Entry) + $entries) -join ";"
}

function Publish-OfficeCliCommand {
    if (Test-Path -LiteralPath $script:BinDir) {
        $attributes = (Get-Item -LiteralPath $script:BinDir -Force).Attributes
        if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Stop-Bootstrap "OfficeCLI command directory must not be a reparse point"
        }
    }
    $null = New-Item -ItemType Directory -Path $script:BinDir -Force
    if (Test-Path -LiteralPath $script:OfficeCliCommandPath) {
        $commandAttributes = (
            Get-Item -LiteralPath $script:OfficeCliCommandPath -Force
        ).Attributes
        if (($commandAttributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Stop-Bootstrap "OfficeCLI command path must not be a reparse point"
        }
    }
    $runtimeSha256 = Get-Sha256 -Path $script:OfficeCliPath
    if (
        (-not (Test-Path -LiteralPath $script:OfficeCliCommandPath -PathType Leaf)) -or
        ((Get-Sha256 -Path $script:OfficeCliCommandPath) -ne $runtimeSha256)
    ) {
        $staged = "$script:OfficeCliCommandPath.new.$PID"
        Copy-Item -LiteralPath $script:OfficeCliPath -Destination $staged -Force
        if ((Get-Sha256 -Path $staged) -ne $runtimeSha256) {
            Remove-Item -LiteralPath $staged -Force -ErrorAction SilentlyContinue
            Stop-Bootstrap "published OfficeCLI SHA-256 mismatch"
        }
        Install-AtomicFile -Source $staged -Destination $script:OfficeCliCommandPath
    }
    $publishedVersion = Get-FirstCapturedLine `
        -Executable $script:OfficeCliCommandPath `
        -Arguments @("--version") `
        -Label "Published OfficeCLI --version"
    if ($publishedVersion -ne $script:OfficeCliActualVersion) {
        Stop-Bootstrap "published OfficeCLI version mismatch"
    }

    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $updatedUserPath = Add-PathEntry -PathValue $userPath -Entry $script:BinDir
    if ($updatedUserPath -cne $userPath) {
        [Environment]::SetEnvironmentVariable("Path", $updatedUserPath, "User")
    }
    $env:Path = Add-PathEntry -PathValue $env:Path -Entry $script:BinDir
}

function Invoke-Captured {
    param([string]$Executable, [string[]]$Arguments)
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $global:LASTEXITCODE = $null
        $output = @(& $Executable @Arguments 2>&1 | ForEach-Object { $_.ToString() })
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($null -eq $exitCode) {
        throw "command could not be started"
    }
    if ($exitCode -ne 0) {
        throw "command failed with exit code $exitCode"
    }
    return $output
}

function Invoke-PixiTool {
    param([string]$Tool, [string[]]$ToolArguments)
    $arguments = @(
        "run", "--locked", "--no-config", "--manifest-path", $script:ManifestPath
    )
    if ($script:Architecture -eq "arm64") {
        $arguments += @("--platform", "win-64")
    }
    $arguments += @("-x", $Tool)
    $arguments += $ToolArguments
    return Invoke-Captured -Executable $script:PixiPath -Arguments $arguments
}

function Get-FirstCapturedLine {
    param([string]$Executable, [string[]]$Arguments, [string]$Label)
    $output = @(Invoke-Captured -Executable $Executable -Arguments $Arguments)
    if ($output.Count -eq 0) {
        throw "$Label returned no output"
    }
    return $output[0].Trim()
}

function Get-ReportedVersion {
    param([string]$Output)
    $match = [Regex]::Match($Output, '(?<!\d)(\d+\.\d+\.\d+)(?!\d)')
    if (-not $match.Success) {
        return $null
    }
    try {
        return [Version]::Parse($match.Groups[1].Value)
    }
    catch {
        return $null
    }
}

function Test-Health {
    $script:HealthError = $null
    $healthStep = "OfficeCLI --version"
    try {
        $script:OfficeCliActualVersion = Get-FirstCapturedLine `
            -Executable $script:OfficeCliPath `
            -Arguments @("--version") `
            -Label $healthStep
        $reportedVersion = Get-ReportedVersion -Output $script:OfficeCliActualVersion
        if ($null -eq $reportedVersion) {
            $script:HealthError = (
                "OfficeCLI returned an unrecognized version " +
                "'$script:OfficeCliActualVersion'; minimum required is " +
                "$OfficeCliMinimumVersion"
            )
            return $false
        }
        if ($reportedVersion -lt $OfficeCliMinimumVersion) {
            $script:HealthError = (
                "OfficeCLI reported $reportedVersion; minimum required is " +
                "$OfficeCliMinimumVersion"
            )
            return $false
        }
        $healthStep = "OfficeCLI help"
        $null = Invoke-Captured -Executable $script:OfficeCliPath -Arguments @("help")

        $healthStep = "pdftotext -v"
        $popplerOutput = @(
            Invoke-PixiTool -Tool "pdftotext" -ToolArguments @("-v")
        )
        if ($popplerOutput.Count -eq 0) {
            throw "$healthStep returned no output"
        }
        $script:PopplerActualVersion = $popplerOutput[0].Trim()
        $healthStep = "pdftoppm -v"
        $null = Invoke-PixiTool -Tool "pdftoppm" -ToolArguments @("-v")
        $healthStep = "pdfseparate -v"
        $null = Invoke-PixiTool -Tool "pdfseparate" -ToolArguments @("-v")
        $healthStep = "pdfunite -v"
        $null = Invoke-PixiTool -Tool "pdfunite" -ToolArguments @("-v")

        $healthStep = "tesseract --version"
        $tesseractOutput = @(
            Invoke-PixiTool -Tool "tesseract" -ToolArguments @("--version")
        )
        if ($tesseractOutput.Count -eq 0) {
            throw "$healthStep returned no output"
        }
        $script:TesseractActualVersion = $tesseractOutput[0].Trim()
        $healthStep = "tesseract --list-langs"
        $languages = @(
            Invoke-PixiTool -Tool "tesseract" -ToolArguments @("--list-langs")
        )
        foreach ($language in $RequiredLanguages) {
            if ($languages -notcontains $language) {
                $script:HealthError = "Tesseract language '$language' is missing"
                return $false
            }
        }
        return $true
    }
    catch {
        $script:HealthError = "$healthStep failed: $($_.Exception.Message)"
        return $false
    }
}

function Test-ReusableRuntime {
    if (-not (
        (Test-Path -LiteralPath $script:PixiPath -PathType Leaf) -and
        (Test-Path -LiteralPath $script:OfficeCliPath -PathType Leaf) -and
        (Test-Path -LiteralPath $script:ManifestPath -PathType Leaf) -and
        (Test-Path -LiteralPath $script:LockPath -PathType Leaf)
    )) {
        return $false
    }
    try {
        if ((Get-Sha256 -Path $script:ManifestPath) -ne $ManifestSha256) {
            return $false
        }
        if ((Get-Sha256 -Path $script:LockPath) -ne $LockSha256) {
            return $false
        }
        $pixiActual = Get-FirstCapturedLine `
            -Executable $script:PixiPath `
            -Arguments @("--version") `
            -Label "Pixi --version"
        if ($pixiActual -notlike "*$PixiVersion*") {
            return $false
        }
        return Test-Health
    }
    catch {
        return $false
    }
}

function Write-State {
    param([bool]$Reused)
    $runPrefix = @(
        $script:PixiPath,
        "run",
        "--locked",
        "--no-config",
        "--manifest-path",
        $script:ManifestPath
    )
    if ($script:Architecture -eq "arm64") {
        $runPrefix += @("--platform", "win-64")
    }
    $runPrefix += "-x"

    $state = [ordered]@{
        schema_version = 1
        runtime_version = $RuntimeVersion
        os = "windows"
        arch = $script:Architecture
        verified_at = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
        pixi_path = $script:PixiPath
        manifest_path = $script:ManifestPath
        officecli_path = $script:OfficeCliPath
        officecli_command_path = $script:OfficeCliCommandPath
        path_entry = $script:BinDir
        commands = [ordered]@{
            officecli = @($script:OfficeCliPath)
            pdftotext = @($runPrefix + "pdftotext")
            pdftoppm = @($runPrefix + "pdftoppm")
            pdfseparate = @($runPrefix + "pdfseparate")
            pdfunite = @($runPrefix + "pdfunite")
            tesseract = @($runPrefix + "tesseract")
        }
        versions = [ordered]@{
            officecli = $script:OfficeCliActualVersion
            poppler = $script:PopplerActualVersion
            tesseract = $script:TesseractActualVersion
        }
        ocr_languages = $RequiredLanguages
    }
    $temporaryState = "$script:StateFile.tmp.$PID"
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText(
        $temporaryState,
        ($state | ConvertTo-Json -Depth 8),
        $utf8
    )
    $null = Get-Content -LiteralPath $temporaryState -Raw | ConvertFrom-Json
    Install-AtomicFile -Source $temporaryState -Destination $script:StateFile

    [ordered]@{
        status = "ready"
        reused = $Reused
        runtime_version = $RuntimeVersion
        state_file = $script:StateFile
    } | ConvertTo-Json -Compress
}

function Get-NativeArchitecture {
    $value = if ($env:PROCESSOR_ARCHITEW6432) {
        $env:PROCESSOR_ARCHITEW6432
    }
    else {
        $env:PROCESSOR_ARCHITECTURE
    }
    switch ($value.ToUpperInvariant()) {
        "AMD64" { return "x64" }
        "ARM64" { return "arm64" }
        default { Stop-Bootstrap "unsupported Windows architecture: $value" }
    }
}

function Invoke-Inspect {
    $version = [Environment]::OSVersion.Version
    [ordered]@{
        bootstrap_version = $BootstrapVersion
        runtime_version = $RuntimeVersion
        os = "windows"
        os_version = $version.ToString()
        machine = Get-NativeArchitecture
        user_scope_only = $true
        modifies_path = $true
        path_scope = "user"
        requires_admin = $false
    } | ConvertTo-Json -Compress
}

function Invoke-Install {
    Write-Stage 1 "Checking platform, existing runtime, and free space"
    if ($env:OS -ne "Windows_NT") {
        Stop-Bootstrap "Windows is required"
    }
    $windowsVersion = [Environment]::OSVersion.Version
    if ($windowsVersion.Major -lt 10) {
        Stop-Bootstrap "Windows 10 or later is required"
    }
    $script:Architecture = Get-NativeArchitecture
    if ($script:Architecture -eq "arm64" -and $windowsVersion.Build -lt 26100) {
        Stop-Bootstrap "Windows ARM64 requires Windows 11 24H2 or later with Prism"
    }
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        Stop-Bootstrap "LOCALAPPDATA is not available"
    }

    $baseDir = Join-Path $env:LOCALAPPDATA "LegalSkills"
    $script:InstallRoot = Join-Path $baseDir "runtime\$RuntimeVersion"
    $script:StateFile = Join-Path $baseDir "environment.json"
    $script:BinDir = Join-Path $baseDir "bin"
    $script:PixiPath = Join-Path $script:InstallRoot "pixi.exe"
    $script:OfficeCliPath = Join-Path $script:InstallRoot "officecli.exe"
    $script:OfficeCliCommandPath = Join-Path $script:BinDir "officecli.exe"
    $script:ManifestPath = Join-Path $script:InstallRoot "pixi.toml"
    $script:LockPath = Join-Path $script:InstallRoot "pixi.lock"

    foreach ($path in @($baseDir, $script:InstallRoot, $script:BinDir)) {
        if (Test-Path -LiteralPath $path) {
            $attributes = (Get-Item -LiteralPath $path -Force).Attributes
            if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                Stop-Bootstrap "install path must not be a reparse point"
            }
        }
    }
    $null = New-Item -ItemType Directory -Path $script:InstallRoot -Force

    if (Test-ReusableRuntime) {
        Write-Stage 6 "Publishing OfficeCLI to the user PATH and refreshing environment state"
        Publish-OfficeCliCommand
        Write-State -Reused $true
        return
    }

    $driveRoot = [IO.Path]::GetPathRoot($script:InstallRoot)
    $drive = New-Object IO.DriveInfo($driveRoot)
    if ($drive.AvailableFreeSpace -lt $MinimumFreeSpaceBytes) {
        Stop-Bootstrap "at least 1.5 GiB of free space is required"
    }

    if ($script:Architecture -eq "arm64") {
        $pixiUrl = "https://github.com/prefix-dev/pixi/releases/download/v0.76.2/pixi-aarch64-pc-windows-msvc.zip"
        $pixiSize = [int64]31131134
        $pixiSha256 = "cc7b2e50b2a81b6e46e55ee576d6319e03a9111400d4b35462a7088e32733c2e"
        $officeCliUrl = "https://github.com/iOfficeAI/OfficeCLI/releases/download/v$OfficeCliReleaseVersion/officecli-win-arm64.exe"
        $officeCliSize = [int64]33800116
        $officeCliSha256 = "51baf511fe136ee216fcc13cf0da9d18078da42212b22805c3a81f4163a4d7b9"
    }
    else {
        $pixiUrl = "https://github.com/prefix-dev/pixi/releases/download/v0.76.2/pixi-x86_64-pc-windows-msvc.zip"
        $pixiSize = [int64]33438504
        $pixiSha256 = "8e948f6b67104be30509ab7d91ac1878fdb7920e57e8b433dbfb7297468b102d"
        $officeCliUrl = "https://github.com/iOfficeAI/OfficeCLI/releases/download/v$OfficeCliReleaseVersion/officecli-win-x64.exe"
        $officeCliSize = [int64]33357736
        $officeCliSha256 = "d4d4c10fced307e209744cf98a56b003a6e613424fd651b08469274704afd2c6"
    }

    $script:WorkDir = Join-Path $script:InstallRoot ".bootstrap.$PID"
    $extractDir = Join-Path $script:WorkDir "pixi-extract"
    $cacheDir = Join-Path $script:WorkDir "cache"
    $null = New-Item -ItemType Directory -Path $extractDir -Force
    $null = New-Item -ItemType Directory -Path $cacheDir -Force
    $pixiArchive = Join-Path $script:WorkDir "pixi.zip"
    $officeCliDownload = Join-Path $script:WorkDir "officecli.exe"
    $manifestDownload = Join-Path $script:WorkDir "pixi.toml"
    $lockDownload = Join-Path $script:WorkDir "pixi.lock"

    Write-Stage 2 "Downloading four pinned runtime files in parallel"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-ParallelDownloads -Downloads @(
        @{ Url = $pixiUrl; Path = $pixiArchive },
        @{ Url = $officeCliUrl; Path = $officeCliDownload },
        @{ Url = $ManifestUrl; Path = $manifestDownload },
        @{ Url = $LockUrl; Path = $lockDownload }
    )

    Write-Stage 3 "Verifying sizes, SHA-256 values, and archive contents"
    Assert-File -Path $pixiArchive -ExpectedSize $pixiSize -ExpectedSha256 $pixiSha256 -Label "Pixi archive"
    Assert-File -Path $officeCliDownload -ExpectedSize $officeCliSize -ExpectedSha256 $officeCliSha256 -Label "OfficeCLI"
    Assert-File -Path $manifestDownload -ExpectedSize $ManifestSize -ExpectedSha256 $ManifestSha256 -Label "pixi.toml"
    Assert-File -Path $lockDownload -ExpectedSize $LockSize -ExpectedSha256 $LockSha256 -Label "pixi.lock"
    Expand-Archive -LiteralPath $pixiArchive -DestinationPath $extractDir -Force
    $archiveFiles = @(Get-ChildItem -LiteralPath $extractDir -Recurse -File)
    if ($archiveFiles.Count -ne 1 -or $archiveFiles[0].Name -ne "pixi.exe") {
        Stop-Bootstrap "Pixi archive contains unexpected entries"
    }

    Install-AtomicFile -Source $archiveFiles[0].FullName -Destination $script:PixiPath
    Install-AtomicFile -Source $officeCliDownload -Destination $script:OfficeCliPath
    Install-AtomicFile -Source $manifestDownload -Destination $script:ManifestPath
    Install-AtomicFile -Source $lockDownload -Destination $script:LockPath

    Write-Stage 4 "Installing the locked Poppler and Tesseract environment"
    $env:PIXI_CACHE_DIR = $cacheDir
    $installArguments = @(
        "install", "--locked", "--no-config", "--manifest-path", $script:ManifestPath
    )
    if ($script:Architecture -eq "arm64") {
        $installArguments += @("--platform", "win-64")
    }
    $null = Invoke-Captured -Executable $script:PixiPath -Arguments $installArguments

    Write-Stage 5 "Running OfficeCLI, Poppler, Tesseract, and OCR language health checks"
    if (-not (Test-Health)) {
        Stop-Bootstrap $script:HealthError
    }

    Write-Stage 6 "Publishing OfficeCLI to the user PATH and writing environment state"
    Publish-OfficeCliCommand
    Write-State -Reused $false
}

try {
    if ($Command -eq "Inspect") {
        Invoke-Inspect
    }
    else {
        Invoke-Install
    }
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
finally {
    if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir)) {
        Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
