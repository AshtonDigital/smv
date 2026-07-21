[CmdletBinding()]
param(
    [string]$Version,
    [string]$ConfigFile = "Build/for_bundle/smokeview.ini",
    [string]$BuildDir = "cbuild/release-windows",
    [string]$OutputDir = "dist",
    [switch]$SkipBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($env:OS -ne "Windows_NT") {
    throw "This script must be run on Windows."
}

$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))

function Get-RepoPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([IO.Path]::IsPathRooted($Path)) {
        return [IO.Path]::GetFullPath($Path)
    }
    return [IO.Path]::GetFullPath((Join-Path $RepoRoot $Path))
}

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Command failed with exit code $LASTEXITCODE."
    }
}

$ConfigFile = Get-RepoPath $ConfigFile
$BuildDir = Get-RepoPath $BuildDir
$OutputDir = Get-RepoPath $OutputDir

if (-not $Version) {
    $ProjectDeclaration = Select-String `
        -Path (Join-Path $RepoRoot "CMakeLists.txt") `
        -Pattern 'project\(smv .*VERSION ([0-9]+\.[0-9]+\.[0-9]+)' |
        Select-Object -First 1
    if (-not $ProjectDeclaration) {
        throw "Could not determine the version from CMakeLists.txt."
    }
    $Version = $ProjectDeclaration.Matches[0].Groups[1].Value
}
$Version = $Version.TrimStart("v")
if ($Version -notmatch '^[0-9A-Za-z][0-9A-Za-z._-]*$') {
    throw "Invalid version: $Version"
}

$ObjectsFile = Join-Path $RepoRoot "Build/for_bundle/objects.svo"
$ColorbarsDir = Join-Path $RepoRoot "Build/for_bundle/colorbars"
$TexturesDir = Join-Path $RepoRoot "Build/for_bundle/textures"

foreach ($RequiredPath in @($ConfigFile, $ObjectsFile, $ColorbarsDir, $TexturesDir)) {
    if (-not (Test-Path -LiteralPath $RequiredPath)) {
        throw "Required package input is missing: $RequiredPath"
    }
}

if (-not $SkipBuild) {
    Invoke-NativeCommand -Command cmake -Arguments @(
        "-S", $RepoRoot,
        "-B", $BuildDir,
        "-A", "x64",
        "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded",
        "-DBUILD_SHARED_LIBS=OFF",
        "-DVENDORED_UI_LIBS=ON",
        "-DVENDORED_LIBS=ON"
    )
    Invoke-NativeCommand -Command cmake -Arguments @(
        "--build", $BuildDir,
        "--config", "Release",
        "--target", "smokeview",
        "--parallel"
    )
}

$BinaryCandidates = @(
    (Join-Path $BuildDir "Release/smokeview.exe"),
    (Join-Path $BuildDir "smokeview.exe")
)
$Binary = $BinaryCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $Binary) {
    throw "Release executable not found under $BuildDir."
}

$Architecture = "x64"
$PackageName = "ashton-smokeview-v$Version-windows-$Architecture"
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$StageRoot = Join-Path ([IO.Path]::GetTempPath()) ("smv-package-" + [guid]::NewGuid().ToString("N"))
$PackageDir = Join-Path $StageRoot $PackageName

try {
    New-Item -ItemType Directory -Force -Path $PackageDir | Out-Null
    Copy-Item -LiteralPath $Binary -Destination (Join-Path $PackageDir "smokeview.exe")
    Copy-Item -LiteralPath $ConfigFile -Destination (Join-Path $PackageDir "smokeview.ini")
    Copy-Item -LiteralPath $ObjectsFile -Destination (Join-Path $PackageDir "objects.svo")
    Copy-Item -LiteralPath $ColorbarsDir -Destination (Join-Path $PackageDir "colorbars") -Recurse
    Copy-Item -LiteralPath $TexturesDir -Destination (Join-Path $PackageDir "textures") -Recurse

    $Commit = (& git -C $RepoRoot rev-parse --short=12 HEAD).Trim()
    if ($LASTEXITCODE -ne 0) { $Commit = "unknown" }
    $DirtyOutput = & git -C $RepoRoot status --porcelain --untracked-files=no
    $Dirty = if ($DirtyOutput) { "yes" } else { "no" }

    @"
Version: v$Version
Git commit: $Commit
Git working tree dirty: $Dirty
Build date: $([DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ"))
Platform: Windows $Architecture
Compiler/runtime: MSVC with static multithreaded runtime
"@ | Set-Content -LiteralPath (Join-Path $PackageDir "VERSION") -Encoding UTF8

    @"
Ashton Smokeview
================

Keep this directory together. Run Smokeview with an absolute path to a case:

  .\smokeview.exe C:\absolute\path\to\case.smv

The packaged smokeview.ini and objects.svo files are loaded from this directory.
Contact the Ashton Digital internal support channel for help with this build.
"@ | Set-Content -LiteralPath (Join-Path $PackageDir "README.txt") -Encoding UTF8

    $ArchivePath = Join-Path $OutputDir "$PackageName.zip"
    $ChecksumPath = "$ArchivePath.sha256"
    if (Test-Path -LiteralPath $ArchivePath) {
        Remove-Item -LiteralPath $ArchivePath -Force
    }
    Compress-Archive -LiteralPath $PackageDir -DestinationPath $ArchivePath -CompressionLevel Optimal

    $Hash = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    "$Hash  $([IO.Path]::GetFileName($ArchivePath))" |
        Set-Content -LiteralPath $ChecksumPath -Encoding ASCII

    Write-Host "Created $ArchivePath"
    Write-Host "Created $ChecksumPath"
}
finally {
    if (Test-Path -LiteralPath $StageRoot) {
        Remove-Item -LiteralPath $StageRoot -Recurse -Force
    }
}
