param(
    [ValidateSet("codex", "claude")]
    [string]$Client
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$SkillVersion = "0.6.0"
$SkillReleaseTag = "v1.0.15"
$SkillBundleName = "CoreSkills-v$SkillVersion.zip"
$SkillBundleUrl = "https://github.com/Qing-Gege/hezha-client-bootstrap/releases/download/$SkillReleaseTag/$SkillBundleName"
$SkillBundleSize = [int64]70658
$SkillBundleSha256 = "ae0fed1c3305ef621ef3009e8cc3cdc2f4e44b20f78de0ca0a36f1bc2cf12972"

function Stop-Install([string]$Message) {
    throw "HeZha core skills install failed: $Message"
}

if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
    Stop-Install "USERPROFILE is not available"
}

$clientRoot = if ($Client -eq "codex") {
    Join-Path $env:USERPROFILE ".codex\skills"
}
else {
    Join-Path $env:USERPROFILE ".claude\skills"
}

if (Test-Path -LiteralPath $clientRoot) {
    $attributes = (Get-Item -LiteralPath $clientRoot -Force).Attributes
    if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Stop-Install "skill path must not be a reparse point"
    }
}

$workRoot = Join-Path $env:TEMP "hezha-core-skills-$PID"
$extract = Join-Path $workRoot "extract"
$bundle = Join-Path $workRoot $SkillBundleName

try {
    $null = New-Item -ItemType Directory -Path $clientRoot -Force
    $null = New-Item -ItemType Directory -Path $extract -Force
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -UseBasicParsing -Uri $SkillBundleUrl -OutFile $bundle
    $downloaded = Get-Item -LiteralPath $bundle
    if ($downloaded.Length -ne $SkillBundleSize) {
        Stop-Install "bundle size mismatch"
    }
    if ((Get-FileHash -LiteralPath $bundle -Algorithm SHA256).Hash.ToLowerInvariant() -ne $SkillBundleSha256) {
        Stop-Install "bundle SHA-256 mismatch"
    }
    Expand-Archive -LiteralPath $bundle -DestinationPath $extract -Force
    $manifestPath = Join-Path $extract "manifest.json"
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        Stop-Install "bundle is missing manifest.json"
    }
    $skillIds = @("document-operations", "document-ocr", "diagramming", "source", "skill-authoring")
    $installed = @()
    foreach ($skillId in $skillIds) {
        $skillManifest = Join-Path $extract "skills\$skillId\manifest.json"
        $skillBody = Join-Path $extract "skills\$skillId\clients\$Client\SKILL.md"
        foreach ($required in @($skillManifest, $skillBody)) {
            if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
                Stop-Install "bundle is missing $required"
            }
        }
        $target = Join-Path $clientRoot $skillId
        if (Test-Path -LiteralPath $target) {
            $attributes = (Get-Item -LiteralPath $target -Force).Attributes
            if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                Stop-Install "$skillId target must not be a reparse point"
            }
        }
        $staged = Join-Path $clientRoot ".$skillId.new.$PID"
        $backup = Join-Path $clientRoot ".$skillId.backup.$PID"
        if (Test-Path -LiteralPath $staged) { Remove-Item -LiteralPath $staged -Recurse -Force }
        $null = New-Item -ItemType Directory -Path $staged -Force
        Copy-Item -LiteralPath $skillManifest -Destination (Join-Path $staged "manifest.json") -Force
        Copy-Item -LiteralPath $skillBody -Destination (Join-Path $staged "SKILL.md") -Force
        if (Test-Path -LiteralPath $target) {
            [IO.Directory]::Move($target, $backup)
        }
        try {
            [IO.Directory]::Move($staged, $target)
        }
        catch {
            if (Test-Path -LiteralPath $backup) {
                [IO.Directory]::Move($backup, $target)
            }
            throw
        }
        if (Test-Path -LiteralPath $backup) {
            Remove-Item -LiteralPath $backup -Recurse -Force
        }
        $installed += $target
    }

    [ordered]@{
        status = "ready"
        pack_id = "core"
        version = $SkillVersion
        client = $Client
        skill_ids = $skillIds
        paths = $installed
        user_scope_only = $true
    } | ConvertTo-Json -Compress
}
catch {
    if (Test-Path -LiteralPath $workRoot) { Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue }
    if ($_.Exception.Message -like "HeZha core skills install failed:*") { throw }
    Stop-Install $_.Exception.Message
}
finally {
    if (Test-Path -LiteralPath $workRoot) { Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
