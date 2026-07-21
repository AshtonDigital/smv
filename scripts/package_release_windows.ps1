<#
.SYNOPSIS
Build Smokeview and create a Windows installer executable.

.DESCRIPTION
Requires Visual Studio 2022 with C++ build tools, CMake, and NSIS 3.
#>
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

function Find-CMakeCommand {
    $Command = Get-Command cmake.exe -ErrorAction SilentlyContinue
    if ($Command) { return $Command.Source }

    $Candidates = @()
    if ($env:ProgramFiles) {
        $Candidates += Join-Path $env:ProgramFiles "CMake/bin/cmake.exe"
    }

    $VsWhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio/Installer/vswhere.exe"
    if (Test-Path -LiteralPath $VsWhere) {
        $VsPath = & $VsWhere -latest -products * -property installationPath
        if ($VsPath) {
            $Candidates += Join-Path $VsPath "Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe"
        }
    }

    $Result = $Candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if ($Result) { return $Result }

    throw "CMake was not found. Install the Visual Studio 'C++ CMake tools for Windows' component, then reopen PowerShell."
}

function Find-MakeNSISCommand {
    $Command = Get-Command makensis.exe -ErrorAction SilentlyContinue
    if ($Command) { return $Command.Source }

    $Candidates = @()
    if (${env:ProgramFiles(x86)}) {
        $Candidates += Join-Path ${env:ProgramFiles(x86)} "NSIS/makensis.exe"
    }
    if ($env:ProgramFiles) {
        $Candidates += Join-Path $env:ProgramFiles "NSIS/makensis.exe"
    }

    $Result = $Candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if ($Result) { return $Result }

    throw "NSIS was not found. Install NSIS 3 from https://nsis.sourceforge.io, then reopen PowerShell."
}

$ConfigFile = Get-RepoPath $ConfigFile
$BuildDir = Get-RepoPath $BuildDir
$OutputDir = Get-RepoPath $OutputDir

if (-not $Version) {
    $CMakeContents = Get-Content -LiteralPath (Join-Path $RepoRoot "CMakeLists.txt") -Raw
    $ProjectDeclaration = [regex]::Match(
        $CMakeContents,
        'project\(smv .*VERSION ([0-9]+\.[0-9]+\.[0-9]+)'
    )
    $AshtonDeclaration = [regex]::Match(
        $CMakeContents,
        'set\(ASHTON_RELEASE\s+"([^"]+)"\)'
    )
    if (-not $ProjectDeclaration.Success) {
        throw "Could not determine the upstream Smokeview version from CMakeLists.txt."
    }
    if (-not $AshtonDeclaration.Success) {
        throw "Could not determine the Ashton release from CMakeLists.txt."
    }
    $Version = $ProjectDeclaration.Groups[1].Value + "-" + $AshtonDeclaration.Groups[1].Value
}
$Version = $Version.TrimStart("v")
if ($Version -notmatch '^[0-9A-Za-z][0-9A-Za-z._-]*$') {
    throw "Invalid version: $Version"
}

$ObjectsFile = Join-Path $RepoRoot "Build/for_bundle/objects.svo"
$RootMarkerFile = Join-Path $RepoRoot "Build/for_bundle/.smokeview_bin"
$CaptureScript = Join-Path $RepoRoot "Utilities/Scripts/capture_result_slices.py"
$ColorbarsDir = Join-Path $RepoRoot "Build/for_bundle/colorbars"
$TexturesDir = Join-Path $RepoRoot "Build/for_bundle/textures"

foreach ($RequiredPath in @(
    $ConfigFile,
    $ObjectsFile,
    $RootMarkerFile,
    $CaptureScript,
    $ColorbarsDir,
    $TexturesDir
)) {
    if (-not (Test-Path -LiteralPath $RequiredPath)) {
        throw "Required package input is missing: $RequiredPath"
    }
}

if (-not $SkipBuild) {
    $CMakeCommand = Find-CMakeCommand
}
$MakeNSISCommand = Find-MakeNSISCommand
if (-not $SkipBuild) {
    Invoke-NativeCommand -Command $CMakeCommand -Arguments @(
        "-S", $RepoRoot,
        "-B", $BuildDir,
        "-A", "x64",
        "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded",
        "-DBUILD_SHARED_LIBS=OFF",
        "-DVENDORED_UI_LIBS=ON",
        "-DVENDORED_LIBS=ON"
    )
    Invoke-NativeCommand -Command $CMakeCommand -Arguments @(
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

$VersionOutput = (& $Binary "-version" 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0) {
    throw "Could not read the revision from the release executable."
}
$BinaryVersionMatch = [regex]::Match($VersionOutput, '(?m)^Revision\s*:\s*(\S+)\s*$')
if (-not $BinaryVersionMatch.Success) {
    throw "Could not read the revision from the release executable."
}
$BinaryVersion = $BinaryVersionMatch.Groups[1].Value
if ($BinaryVersion -ne $Version) {
    throw "Package version $Version does not match executable revision $BinaryVersion; rebuild after updating ASHTON_RELEASE in CMakeLists.txt."
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
    Copy-Item -LiteralPath $RootMarkerFile -Destination (Join-Path $PackageDir ".smokeview_bin")
    Copy-Item -LiteralPath $CaptureScript -Destination (Join-Path $PackageDir "capture_result_slices.py")
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

Capture every configured result-review slice with:

  python .\capture_result_slices.py C:\absolute\path\to\case.smv --overwrite

The capture utility requires Python 3.10 or newer. Model cropping requires
ImageMagick; install it from PowerShell with:

  winget install --id ImageMagick.Q16 -e --source winget

Use --no-crop if ImageMagick is intentionally unavailable. The case's associated
slice and data files must remain beside the .smv file.

Contact the Ashton Digital internal support channel for help with this build.
"@ | Set-Content -LiteralPath (Join-Path $PackageDir "README.txt") -Encoding UTF8

    $InstallerPath = Join-Path $OutputDir "$PackageName.exe"
    $ChecksumPath = "$InstallerPath.sha256"
    if (Test-Path -LiteralPath $InstallerPath) {
        Remove-Item -LiteralPath $InstallerPath -Force
    }

    $NsiPath = Join-Path $StageRoot "installer.nsi"
    $IconPath = Join-Path $RepoRoot "Build/for_bundle/icon.ico"
    $NsiTemplate = @'
Unicode True
!include "MUI2.nsh"

Name "Ashton Smokeview v@VERSION@"
OutFile "@OUTPUT@"
InstallDir "$LOCALAPPDATA\Ashton Digital\Smokeview"
InstallDirRegKey HKCU "Software\Ashton Digital\Smokeview" "InstallDir"
RequestExecutionLevel user
Icon "@ICON@"
UninstallIcon "@ICON@"

!define MUI_ABORTWARNING
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"

Section "Smokeview" SEC_SMOKEVIEW
    SetShellVarContext current
    SetOutPath "$INSTDIR"
    File /r "@PACKAGE@\*"

    WriteRegStr HKCU "Software\Ashton Digital\Smokeview" "InstallDir" "$INSTDIR"
    WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\AshtonSmokeview" "DisplayName" "Ashton Smokeview"
    WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\AshtonSmokeview" "DisplayVersion" "@VERSION@"
    WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\AshtonSmokeview" "DisplayIcon" "$INSTDIR\smokeview.exe"
    WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\AshtonSmokeview" "UninstallString" '"$INSTDIR\Uninstall.exe"'

    WriteRegStr HKCU "Software\Classes\.smv" "" "AshtonSmokeview.smv"
    WriteRegStr HKCU "Software\Classes\AshtonSmokeview.smv" "" "Smokeview case"
    WriteRegStr HKCU "Software\Classes\AshtonSmokeview.smv\DefaultIcon" "" "$INSTDIR\smokeview.exe,0"
    WriteRegStr HKCU "Software\Classes\AshtonSmokeview.smv\shell\open\command" "" '"$INSTDIR\smokeview.exe" "%1"'

    CreateDirectory "$SMPROGRAMS\Ashton Digital"
    CreateShortcut "$SMPROGRAMS\Ashton Digital\Smokeview.lnk" "$INSTDIR\smokeview.exe"
    WriteUninstaller "$INSTDIR\Uninstall.exe"
SectionEnd

Section "Uninstall"
    SetShellVarContext current
    Delete "$SMPROGRAMS\Ashton Digital\Smokeview.lnk"
    RMDir "$SMPROGRAMS\Ashton Digital"
    DeleteRegKey HKCU "Software\Classes\AshtonSmokeview.smv"
    DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\AshtonSmokeview"
    DeleteRegKey HKCU "Software\Ashton Digital\Smokeview"
    RMDir /r "$INSTDIR"
SectionEnd
'@
    $NsiContents = $NsiTemplate.Replace("@VERSION@", $Version)
    $NsiContents = $NsiContents.Replace("@OUTPUT@", $InstallerPath)
    $NsiContents = $NsiContents.Replace("@ICON@", $IconPath)
    $NsiContents = $NsiContents.Replace("@PACKAGE@", $PackageDir)
    $NsiContents | Set-Content -LiteralPath $NsiPath -Encoding UTF8
    Invoke-NativeCommand -Command $MakeNSISCommand -Arguments @($NsiPath)

    $Hash = (Get-FileHash -LiteralPath $InstallerPath -Algorithm SHA256).Hash.ToLowerInvariant()
    "$Hash  $([IO.Path]::GetFileName($InstallerPath))" |
        Set-Content -LiteralPath $ChecksumPath -Encoding ASCII

    Write-Host "Created $InstallerPath"
    Write-Host "Created $ChecksumPath"
}
finally {
    if (Test-Path -LiteralPath $StageRoot) {
        Remove-Item -LiteralPath $StageRoot -Recurse -Force
    }
}
