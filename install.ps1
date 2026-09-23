#!/usr/bin/env pwsh

# Stop executing script on any error
$ErrorActionPreference = 'Stop'
# Do not show download progress
$ProgressPreference = 'SilentlyContinue'

# Taken from https://stackoverflow.com/a/34559554/6537420
function New-TemporaryDirectory {
  $parent = [System.IO.Path]::GetTempPath()
  [string] $name = [System.Guid]::NewGuid()
  New-Item -ItemType Directory -Path (Join-Path $parent $name)
}

$platform = $null
$architecture = $null
$pnpmName = $null
$libcSuffix = ''

# Detect the OS portion of the target triplet using `process.platform`-style
# names (`linux`, `darwin`, `win32`) - the scheme pnpm's own platform packages
# and release assets use from v11.0.0-rc.3 onward.

# PowerShell versions before 6.* were only for Windows OS
if ($PSVersionTable.PSVersion.Major -eq 5) {
  $platform = 'win32'
}

if ($PSVersionTable.PSVersion.Major -ge 6) {
  if ($PSVersionTable.Platform -eq 'Unix') {
    switch -Wildcard ($PSVersionTable.OS) {
      'Darwin*' {
        $platform = 'darwin'
      }
      # PowerShell 7.6+ (built on .NET 10) reports a friendly name like
      # "macOS 26.4" instead of the Darwin kernel string.
      'macOS*' {
        $platform = 'darwin'
      }
      'Linux*' {
        $platform = 'linux'
      }
      'Ubuntu*' {
        $platform = 'linux'
      }
    }

    # PowerShell does not seem to have normal cmdlets for retrieving system information, so we use UNAME(1) for this.
    $arch = uname -m
    switch -Wildcard ($arch) {
      'x86_64' { $architecture = 'x64'; Break }
      'amd64' { $architecture = 'x64'; Break }
      'armv*' { $architecture = 'arm'; Break }
      'arm64' { $architecture = 'arm64'; Break }
      'aarch64' { $architecture = 'arm64'; Break }
    }

    # 'uname -m' in some cases mis-reports 32-bit OS as 64-bit, so double check
    if ([System.Environment]::Is64BitOperatingSystem -eq $false) {
      if ($architecture -eq 'x64') {
        $architecture = 'i686'
      }

      if ($architecture -eq 'arm64') {
        $architecture = 'arm'
      }
    }

    # Detect musl on Linux hosts. getconf prints GLIBC info on glibc systems;
    # no output (or a failure) indicates musl or similar.
    if ($platform -eq 'linux') {
      $glibcCheck = $null
      try { $glibcCheck = getconf GNU_LIBC_VERSION 2>$null } catch {}
      if (-not $glibcCheck) {
        try { $glibcCheck = (ldd --version 2>&1 | Select-String 'GLIBC|GNU libc').Matches.Count } catch {}
      }
      if (-not $glibcCheck) {
        $libcSuffix = '-musl'
      }
    }

    $pnpmName = "pnpm"
  }

  if ($PSVersionTable.Platform -eq 'Win32NT') {
    $platform = 'win32'
  }
}

if ($platform -eq 'win32') {
  if ([System.Environment]::Is64BitOperatingSystem -eq $true) {
    $architecture = 'x64'
  }

  if ([System.Environment]::Is64BitOperatingSystem -eq $false) {
    $architecture = 'i686'
  }

  $pnpmName = "pnpm.exe"
}

if ($null -eq $platform) {
  Write-Error "Platform could not be determined! Only Windows, Linux and MacOS are supported."
}

switch ($architecture) {
  'x64' { ; Break }
  'arm64' { ; Break }
  Default {
    Write-Error "Sorry! pnpm currently only provides pre-built binaries for x86_64/arm64 architectures."
  }
}

# The asset renaming shipped in pnpm v11.0.0-rc.3. Anything older than that
# release still has only the legacy asset names on its GitHub release page
# (`pnpm-macos-*`, `pnpm-win-*`, `pnpm-linuxstatic-*`), so the installer needs
# to know when to request which.
function Use-LegacyAssets {
  param([string]$Version)
  $major = [int]($Version -split '\.')[0]
  if ($major -lt 11) { return $true }
  # Only v11.0.0-rc.1 and v11.0.0-rc.2 were published before the rename.
  if ($Version -eq '11.0.0-rc.1' -or $Version -eq '11.0.0-rc.2') { return $true }
  return $false
}

# Map the new-scheme target back to the legacy asset basename used by
# pre-rename pnpm releases. Arch is unchanged.
function Get-LegacyAssetBasename {
  param(
    [string]$Platform,
    [string]$Arch,
    [string]$LibcSuffix
  )
  if ($Platform -eq 'darwin' -and -not $LibcSuffix) {
    return "pnpm-macos-$Arch"
  }
  if ($Platform -eq 'win32' -and -not $LibcSuffix) {
    return "pnpm-win-$Arch"
  }
  if ($Platform -eq 'linux' -and $LibcSuffix -eq '-musl') {
    return "pnpm-linuxstatic-$Arch"
  }
  return "pnpm-$Platform-$Arch$LibcSuffix"
}

function Get-AssetBasename {
  param(
    [string]$Version,
    [string]$Platform,
    [string]$Arch,
    [string]$LibcSuffix
  )
  if (Use-LegacyAssets -Version $Version) {
    return (Get-LegacyAssetBasename -Platform $Platform -Arch $Arch -LibcSuffix $LibcSuffix)
  }
  return "pnpm-$Platform-$Arch$LibcSuffix"
}

$NpmRegistry = 'https://registry.npmjs.org'

# npm's registry signing key, mirrored from
# https://registry.npmjs.org/-/npm/v1/keys. See the matching comment in
# install.sh for why the key is pinned rather than fetched.
$NpmSigningKeyId = 'SHA256:DhQ8wR5APBvFHLF/+Tc+AYvPOdTpcIDqOhxsBHRwC7U'
$NpmSigningKey = 'MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEY6Ya7W++7aUPzvMTrezH6Ycx3c+HOKYCcNGybJZSCJq/fd7Qa8uuAKtdIkUQtQiEKERhAmE5lMMJhP8OkDOa2g=='

# $true / $false, or $null when this runtime cannot check ECDSA signatures.
# Windows PowerShell 5.1 has no ImportSubjectPublicKeyInfo, so it falls back to
# the checksum alone.
function Test-NpmSignature {
  param(
    [string]$Message,
    [string]$Signature
  )
  if ($PSVersionTable.PSVersion.Major -lt 7) {
    return $null
  }
  try {
    $ecdsa = [System.Security.Cryptography.ECDsa]::Create()
    $bytesRead = 0
    $ecdsa.ImportSubjectPublicKeyInfo([Convert]::FromBase64String($NpmSigningKey), [ref]$bytesRead)
    return $ecdsa.VerifyData(
      [Text.Encoding]::UTF8.GetBytes($Message),
      [Convert]::FromBase64String($Signature),
      [System.Security.Cryptography.HashAlgorithmName]::SHA256,
      [System.Security.Cryptography.DSASignatureFormat]::Rfc3279DerSequence)
  } catch {
    # Past the version check the runtime can verify, so a throw here means the
    # signature itself did not parse. Treating that as "cannot check" would let
    # a malformed signature buy a downgrade to the checksum alone.
    return $false
  }
}

function Get-FileIntegrity {
  param([string]$Path)
  $sha512 = [System.Security.Cryptography.SHA512]::Create()
  $stream = [IO.File]::OpenRead($Path)
  try {
    return 'sha512-' + [Convert]::ToBase64String($sha512.ComputeHash($stream))
  } finally {
    $stream.Dispose()
  }
}

# Download <package>@<version> from the npm registry into $Destination and
# unpack it, refusing to go on unless the registry signature and the tarball
# checksum both check out.
function Get-VerifiedPackage {
  param(
    [string]$Package,
    [string]$Version,
    [string]$Destination
  )
  $meta = (Invoke-WebRequest "$NpmRegistry/$Package/$Version" -UseBasicParsing).Content | ConvertFrom-Json
  $integrity = $meta.dist.integrity
  $signature = $meta.dist.signatures | Select-Object -First 1
  if (-not $integrity) {
    throw "The npm registry published no checksum for $Package@$Version."
  }
  if (-not $signature) {
    throw "$Package@$Version carries no npm registry signature, so it cannot be verified."
  }
  if ($signature.keyid -ne $NpmSigningKeyId) {
    throw "$Package@$Version is signed with an unexpected npm key ($($signature.keyid)). If npm has rotated its signing key, this installer needs updating."
  }

  $valid = Test-NpmSignature -Message "$Package@$Version`:$integrity" -Signature $signature.sig
  if ($valid -eq $false) {
    throw "The npm registry signature for $Package@$Version is not valid. Refusing to install."
  } elseif ($null -eq $valid) {
    Write-Host "PowerShell 7 is needed to check the npm signature - verifying the checksum only.`n" -ForegroundColor Yellow
  }

  $archive = Join-Path $Destination 'package.tgz'
  Invoke-WebRequest $meta.dist.tarball -OutFile $archive -UseBasicParsing
  if ((Get-FileIntegrity -Path $archive) -ne $integrity) {
    throw "$Package@$Version does not match the checksum the npm registry published for it. Refusing to install."
  }

  $unpacked = Join-Path $Destination 'unpacked'
  if (Test-Path $unpacked) {
    Remove-Item $unpacked -Recurse -Force
  }
  New-Item -ItemType Directory -Path $unpacked | Out-Null
  tar -xzf $archive -C $unpacked
  # $ErrorActionPreference does not cover the exit code of a native command, so
  # a failed unpack would otherwise surface later as a missing-path error.
  if ($LASTEXITCODE -ne 0) {
    throw "Could not unpack $Package@$Version."
  }
  Remove-Item $archive -Force
  return (Join-Path $unpacked 'package')
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Tags come from `pnpm`: it is published for every release, whereas
# `@pnpm/exe` is on its way out and would go stale.
$pkgInfo = Invoke-WebRequest "$NpmRegistry/pnpm" -UseBasicParsing
$versionJson = $pkgInfo.Content | ConvertFrom-Json
$versions = Get-Member -InputObject $versionJson.versions -Type NoteProperty | Select-Object -ExpandProperty Name
$distTags = Get-Member -InputObject $versionJson.'dist-tags' -Type NoteProperty | Select-Object -ExpandProperty Name

$version = $null
$preferredVersion = "latest"

if ($null -ne $env:PNPM_VERSION -and $env:PNPM_VERSION -ne "") {
  $preferredVersion = $env:PNPM_VERSION
}

if ($null -eq $version -and $preferredVersion -in $distTags) {
  $version = $versionJson.'dist-tags' | Select-Object -ExpandProperty $preferredVersion
}

if ($null -eq $version -and $preferredVersion -in $versions) {
  $version = $preferredVersion
}

# A bare major (12, v12) asks for that major's current release, which pnpm
# publishes as `latest-<major>` once the major is stable and only as
# `next-<major>` until then. Same rule as install.sh and the `get-pnpm` package.
if ($null -eq $version -and $preferredVersion -match '^v?(\d+)$') {
  $major = $Matches[1]
  foreach ($tag in "latest-$major", "next-$major") {
    if ($null -eq $version -and $tag -in $distTags) {
      $version = $versionJson.'dist-tags' | Select-Object -ExpandProperty $tag
    }
  }
}

if ($null -eq $version) {
  Write-Host "Current tags:" -ForegroundColor Yellow -NoNewline
  $versionJson.'dist-tags' | Format-List

  Write-Host "Versions:" -ForegroundColor Yellow -NoNewline
  $versionJson.versions | Get-Member -Type NoteProperty | Format-Wide -Property Name -AutoSize

  Write-Error "Sorry! pnpm '$preferredVersion' version could not be found. Use a major, or one of the tags or published versions from the provided list"
}

$tempFileFolder = New-TemporaryDirectory
$majorVersion = [int]($version -split '\.')[0]

if ($majorVersion -ge 12) {
  # v12+ is published to the npm registry as well as to the GitHub release
  # page, with the same executable byte for byte. Only the registry copy comes
  # with a signature over its checksum, so that is the one worth downloading.
  Write-Host "Downloading pnpm $version...`n" -ForegroundColor Green

  $executable = if ($platform -eq 'win32') { 'pnpm.exe' } else { 'pnpm' }
  $platformPackage = "@pnpm/exe.$platform-$architecture$libcSuffix"

  $unpacked = Get-VerifiedPackage -Package $platformPackage -Version $version -Destination $tempFileFolder.FullName
  $tempFile = Join-Path $tempFileFolder.FullName $executable
  Move-Item (Join-Path $unpacked $executable) $tempFile

  # The executable expects the `dist/` tree next to it. `pnpm` is where the
  # registry publishes it, verified the same way. (`@pnpm/exe` currently
  # carries identical content, but only `pnpm` is published going forward.)
  $unpacked = Get-VerifiedPackage -Package 'pnpm' -Version $version -Destination $tempFileFolder.FullName
  Move-Item (Join-Path $unpacked 'dist') (Join-Path $tempFileFolder.FullName 'dist')
} elseif ($majorVersion -ge 11) {
  # v11: distributed as tarballs containing the binary and dist/ directory
  Write-Host "Downloading pnpm from GitHub...`n" -ForegroundColor Green
  $assetBase = Get-AssetBasename -Version $version -Platform $platform -Arch $architecture -LibcSuffix $libcSuffix
  if ($platform -eq 'win32') {
    $archiveUrl = "https://github.com/pnpm/pnpm/releases/download/v$version/$assetBase.zip"
    $tempArchive = Join-Path $tempFileFolder.FullName "pnpm.zip"
    Invoke-WebRequest $archiveUrl -OutFile $tempArchive -UseBasicParsing
    Expand-Archive -Path $tempArchive -DestinationPath $tempFileFolder.FullName -Force
    $tempFile = Join-Path $tempFileFolder.FullName "pnpm.exe"
  } else {
    $archiveUrl = "https://github.com/pnpm/pnpm/releases/download/v$version/$assetBase.tar.gz"
    $tempArchive = Join-Path $tempFileFolder.FullName "pnpm.tar.gz"
    Invoke-WebRequest $archiveUrl -OutFile $tempArchive -UseBasicParsing
    tar -xzf $tempArchive -C $tempFileFolder.FullName
    $tempFile = Join-Path $tempFileFolder.FullName "pnpm"
  }
} else {
  # older versions: distributed as a single executable binary
  Write-Host "Downloading pnpm from GitHub...`n" -ForegroundColor Green
  $assetBase = Get-AssetBasename -Version $version -Platform $platform -Arch $architecture -LibcSuffix $libcSuffix
  $archiveUrl = "https://github.com/pnpm/pnpm/releases/download/v$version/$assetBase"
  if ($platform -eq 'win32') {
    $archiveUrl = "$archiveUrl.exe"
  }
  $tempFile = Join-Path $tempFileFolder.FullName $pnpmName
  Invoke-WebRequest $archiveUrl -OutFile $tempFile -UseBasicParsing
}

Write-Host "Running setup...`n" -ForegroundColor Green

if ($platform -ne 'win32') {
  chmod +x $tempFile
}

Start-Process -FilePath $tempFile -ArgumentList "setup" -NoNewWindow -Wait -ErrorAction Continue

Remove-Item $tempFileFolder -Recurse -Force

# Where `pnpm setup` installs: PNPM_HOME, or pnpm's default for the platform,
# resolved the way pnpm resolves it.
function Get-PnpmHomeDir {
  if ($env:PNPM_HOME) { return $env:PNPM_HOME }
  if ($env:XDG_DATA_HOME) { return Join-Path $env:XDG_DATA_HOME 'pnpm' }
  if ($platform -eq 'win32') {
    if ($env:LOCALAPPDATA) { return Join-Path $env:LOCALAPPDATA 'pnpm' }
    return Join-Path $HOME '.pnpm'
  }
  if ($platform -eq 'darwin') { return Join-Path $HOME 'Library/pnpm' }
  return Join-Path $HOME '.local/share/pnpm'
}

# The directory with every symlink resolved, or the directory itself when it
# does not exist yet.
function Resolve-RealPath([string] $Path) {
  try {
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    # `ResolvedTarget` follows symlinks on PowerShell 7; Windows PowerShell has no such property.
    if ($item.PSObject.Properties['ResolvedTarget'] -and $item.ResolvedTarget) { return $item.ResolvedTarget }
    return $item.FullName
  } catch {
    return $Path
  }
}

# Whether $Dir is a directory `pnpm setup` links pnpm into: `$PNPM_HOME\bin`, or
# `$PNPM_HOME` itself, which the v10 layout linked into directly.
function Test-PnpmHomeBin([string] $Dir, [string] $PnpmHome) {
  $ownDirs = @((Join-Path $PnpmHome 'bin'), $PnpmHome)
  foreach ($own in $ownDirs) {
    if ($Dir.TrimEnd('\', '/') -eq $own.TrimEnd('\', '/')) { return $true }
    if ((Resolve-RealPath $Dir).TrimEnd('\', '/') -eq (Resolve-RealPath $own).TrimEnd('\', '/')) { return $true }
  }
  return $false
}

# How the `pnpm` at $Executable got there, as far as its location and, for a
# shim script, its contents tell: npm, homebrew, corepack, volta, scoop, or
# unknown.
function Get-InstallOrigin([string] $Executable) {
  foreach ($candidate in @((Resolve-RealPath $Executable), $Executable)) {
    $parts = ($candidate -split '[\\/]') | ForEach-Object { $_.ToLowerInvariant() }
    for ($i = 0; $i -lt $parts.Length; $i++) {
      if ($parts[$i] -eq 'cellar' -and $parts[$i + 1] -eq 'pnpm') { return 'homebrew' }
    }
    if ($parts -contains 'corepack') { return 'corepack' }
    if ($parts -contains '.volta') { return 'volta' }
    if ($parts -contains 'scoop') { return 'scoop' }
    for ($i = 0; $i -lt $parts.Length; $i++) {
      if ($parts[$i] -eq 'node_modules' -and $parts[$i + 1] -eq 'pnpm') { return 'npm' }
    }
  }
  # npm's and Corepack's shims name their target inside; a real executable is
  # far larger than any shim.
  try {
    if ((Get-Item -LiteralPath $Executable).Length -le 65536) {
      $script = Get-Content -LiteralPath $Executable -Raw
      if ($script -match 'corepack') { return 'corepack' }
      if ($script -match 'node_modules[\\/]pnpm[\\/]') { return 'npm' }
    }
  } catch {}
  return 'unknown'
}

# Say so when the pnpm just installed is not the one PATH resolves, or the
# success above is the last thing the person reads before `pnpm --version`
# prints the old version again. A `pnpm` from another installer (npm,
# Homebrew, Corepack, Volta, Scoop) that sits ahead of `$PNPM_HOME\bin` on PATH
# keeps running, so every version this script installs looks like it never took.
function Write-ShadowingPnpmWarning {
  $pnpmHome = Get-PnpmHomeDir
  $bin = Join-Path $pnpmHome 'bin'
  $found = @(Get-Command pnpm -All -CommandType Application -ErrorAction SilentlyContinue | ForEach-Object { $_.Source })
  if ($found.Length -eq 0) { return }
  $executable = $found[0]
  if (Test-PnpmHomeBin (Split-Path $executable -Parent) $pnpmHome) { return }
  $binOnPath = $false
  foreach ($other in ($found | Select-Object -Skip 1)) {
    if (Test-PnpmHomeBin (Split-Path $other -Parent) $pnpmHome) { $binOnPath = $true; break }
  }
  $origin = Get-InstallOrigin $executable
  $described = @{
    npm = 'installed with npm'; homebrew = 'installed with Homebrew'; corepack = 'a Corepack shim'
    volta = 'installed with Volta'; scoop = 'installed with Scoop'; unknown = 'not installed by pnpm'
  }[$origin]
  $removal = @{
    npm = 'npm uninstall -g pnpm'; homebrew = 'brew uninstall pnpm'; corepack = 'corepack disable pnpm'
    volta = 'volta uninstall pnpm'; scoop = 'scoop uninstall pnpm'
  }[$origin]
  $reorder = "move $bin ahead of $(Split-Path $executable -Parent) in PATH"
  $fix = if ($removal) { "run `"$removal`" or $reorder" } else { $reorder }
  if ($binOnPath) {
    Write-Host "Warning: `"pnpm`" on PATH is $executable ($described), which comes before $bin." -ForegroundColor Yellow
    Write-Host "Your shell keeps running that pnpm, not the one pnpm installed to $bin." -ForegroundColor Yellow
    Write-Host "To finish switching, $fix." -ForegroundColor Yellow
  } else {
    Write-Host "Warning: `"pnpm`" on PATH is $executable ($described), and $bin is not on PATH yet." -ForegroundColor Yellow
    Write-Host "Once a new shell adds it, it has to come first: $fix." -ForegroundColor Yellow
  }
}

Write-ShadowingPnpmWarning
