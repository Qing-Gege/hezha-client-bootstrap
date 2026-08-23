param(
    [ValidateSet("codex", "claude")]
    [string]$Client
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$SkillVersion = "1.6.0"
$SkillReleaseTag = "v1.0.9"
$SkillBundleName = "KaodaWoSkills-v$SkillVersion.zip"
$SkillBundleUrl = "https://github.com/Qing-Gege/hezha-client-bootstrap/releases/download/$SkillReleaseTag/$SkillBundleName"
$SkillBundleSize = [int64]18264
$SkillBundleSha256 = "b8102c5eb9014c8b61510c971c3f73abffca74e9533e0f0ca394ce8f5721ce6e"

function Stop-Install([string]$Message) {
    throw "HeZha kaoda-wo install failed: $Message"
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
$target = Join-Path $clientRoot "kaoda-wo"
foreach ($path in @($clientRoot, $target)) {
    if (Test-Path -LiteralPath $path) {
        $attributes = (Get-Item -LiteralPath $path -Force).Attributes
        if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Stop-Install "skill path must not be a reparse point"
        }
    }
}

$workRoot = Join-Path $env:TEMP "hezha-kaoda-wo-$PID"
$extract = Join-Path $workRoot "extract"
$bundle = Join-Path $workRoot $SkillBundleName
$staged = Join-Path $clientRoot ".kaoda-wo.new.$PID"
$backup = Join-Path $clientRoot ".kaoda-wo.backup.$PID"

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
    foreach ($required in @("manifest.json", "protocol.json", "clients\$Client\SKILL.md")) {
        if (-not (Test-Path -LiteralPath (Join-Path $extract $required) -PathType Leaf)) {
            Stop-Install "bundle is missing $required"
        }
    }

    $null = New-Item -ItemType Directory -Path $staged -Force
    Copy-Item -LiteralPath (Join-Path $extract "manifest.json") -Destination $staged -Force
    Copy-Item -LiteralPath (Join-Path $extract "protocol.json") -Destination $staged -Force
    Copy-Item -LiteralPath (Join-Path $extract "clients\$Client\SKILL.md") -Destination (Join-Path $staged "SKILL.md") -Force
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
    [ordered]@{
        status = "ready"
        skill_id = "kaoda-wo"
        version = $SkillVersion
        client = $Client
        path = $target
        user_scope_only = $true
    } | ConvertTo-Json -Compress
}
catch {
    if (Test-Path -LiteralPath $staged) { Remove-Item -LiteralPath $staged -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $workRoot) { Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue }
    if ($_.Exception.Message -like "HeZha kaoda-wo install failed:*") { throw }
    Stop-Install $_.Exception.Message
}
finally {
    if (Test-Path -LiteralPath $workRoot) { Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
