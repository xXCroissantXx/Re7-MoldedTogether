# install-coop-re7.ps1: one-click setup for Molded Together, the Resident Evil 7 co-op mod.
#
# Since v0.51 it installs into RE7's own Steam folder only: afterwards you start RE7 with Steam's Play button
# and the mod loads with it. Nothing is copied.
#  1. Checks your PC (.NET 10 runtime, which it offers to install; Windows' Smart App Control).
#  2. Finds RE7 in your Steam libraries.
#  3. Downloads REFramework and its C# add-on from the official release and checks each file's SHA-256.
#  4. Installs the co-op files from this kit, keeping your co-op settings and friends.
#  5. Backs up your RE7 saves.
#
# Run it with Install.cmd (double-click). "Normal RE7 (mod off).cmd" runs it with -Disable: that switches the
# mod off (renames REFramework's dinput8.dll) so RE7 starts normally; Install.cmd switches it on again.

param(
    [switch]$Disable,
    [string]$GameDir = "",  # advanced: an RE7 folder to use instead of the one found in Steam
    [string]$BackupDir = "",
    [switch]$Elevated,      # set when the installer restarted itself as administrator
    [switch]$SteamFolder    # accepted for older wrappers (v0.50.1's "Install into Steam.cmd"); always on now
)

$ErrorActionPreference = "Stop"
$Kit = Split-Path -Parent $MyInvocation.MyCommand.Path
$Base = [Environment]::GetFolderPath("MyDocuments")
if ($Base -match "OneDrive") { $Base = $env:SystemDrive + "\" }
if ($BackupDir -eq "") { $BackupDir = Join-Path $Base "RE7-coop-save-backups" }

# Pinned, verified REFramework nightly (supports the current RT build of RE7).
$Release = "https://github.com/praydog/REFramework-nightly/releases/download/nightly-01433-d4611aef1d63effd3a736bdf9404ea702428017d"
$Downloads = @(
    @{ Name = "REFramework.zip"; Sha = "b3ff4f497be6f108ef494c2c02156b61b8d04f3171378ecc0dc28c218ee296b3" },
    @{ Name = "csharp-api.zip";  Sha = "87a909fedbec028ccd7017cc1dfb671d9f4206f07520bcb114fc6ecd74e8629b" }
)
$AppId = "418370"

function Step($n, $text) { Write-Host ""; Write-Host "[$n/5] $text" -ForegroundColor Cyan }
function Ok($text) { Write-Host "      OK  $text" -ForegroundColor Green }
function Warn($text) { Write-Host "      !!  $text" -ForegroundColor Yellow }
function Done() { if ($Elevated) { Write-Host ""; Read-Host "Press Enter to close" | Out-Null } }
function Fail($text) { Write-Host ""; Write-Host "FAILED: $text" -ForegroundColor Red; Done; exit 1 }

function Find-RE7 {
    $steam = $null
    try { $steam = (Get-ItemProperty "HKCU:\Software\Valve\Steam" -ErrorAction Stop).SteamPath } catch { }
    if (-not $steam) { $steam = "${env:ProgramFiles(x86)}\Steam" }
    $libs = @($steam)
    $vdf = Join-Path $steam "steamapps\libraryfolders.vdf"
    if (Test-Path $vdf) {
        foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) { $libs += $m.Groups[1].Value -replace '\\\\', '\' }
    }
    foreach ($lib in ($libs | Select-Object -Unique)) {
        $p = Join-Path $lib "steamapps\common\RESIDENT EVIL 7 biohazard"
        if (Test-Path (Join-Path $p "re7.exe")) { return @{ Game = $p; Steam = $steam; Lib = $lib } }
    }
    return @{ Game = $null; Steam = $steam; Lib = $null }
}

function Test-Writable($dir) {
    try {
        $probe = Join-Path $dir ("coop-write-test-" + [guid]::NewGuid().ToString("N").Substring(0, 6) + ".tmp")
        Set-Content -Path $probe -Value "x" -ErrorAction Stop
        Remove-Item $probe -Force
        return $true
    } catch { return $false }
}

Write-Host "Molded Together installer" -ForegroundColor White
$found = Find-RE7
if ($GameDir -ne "") {
    if (-not (Test-Path (Join-Path $GameDir "re7.exe"))) { Fail "$GameDir has no re7.exe" }
    $found.Game, $found.Lib = $GameDir, $null
}
if (-not $found.Game) { Fail "Couldn't find Resident Evil 7 in your Steam libraries. Install it from Steam first." }
$Game = $found.Game
Write-Host "RE7 folder: $Game"
if (Get-Process re7 -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($Game) }) {
    Fail "RE7 is running: close the game first, then run this again."
}

# Steam's folder is usually writable for its user; when it isn't (installed under Program Files with tight
# permissions), ask Windows for administrator rights once instead of failing.
if (-not (Test-Writable $Game)) {
    if ($Elevated) { Fail "Can't write to $Game even as administrator." }
    Write-Host "The Steam folder needs administrator rights: Windows will ask you to allow it." -ForegroundColor Yellow
    $argList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"", "-Elevated")
    if ($Disable) { $argList += "-Disable" }
    try { Start-Process powershell -Verb RunAs -ArgumentList $argList | Out-Null }
    catch { Fail "Administrator rights weren't given. Right-click Install.cmd and choose 'Run as administrator'." }
    Write-Host "Carrying on in the new window."
    exit 0
}

$dll = Join-Path $Game "dinput8.dll"
$off = Join-Path $Game "dinput8.dll.off"
if ($Disable) {
    if (Test-Path $dll) {
        Move-Item -Force $dll $off
        Write-Host ""
        Write-Host "Molded Together is switched OFF: RE7 starts normally from Steam." -ForegroundColor Green
        Write-Host "To switch it back on, double-click Install.cmd again (your co-op settings are kept)."
    } else {
        Write-Host ""
        Write-Host "Molded Together isn't switched on (nothing to do)." -ForegroundColor Green
    }
    Done
    exit 0
}

# ---------------------------------------------------------------- 1. checks
Step 1 "Checking your PC"
function Has-DotNet10 {
    $r = ""
    try { $r = (& dotnet --list-runtimes) -join "`n" } catch { }
    return $r -match "Microsoft\.NETCore\.App 10\."
}
if (Has-DotNet10) { Ok ".NET 10 runtime found" }
else {
    Warn ".NET 10 runtime not found. Molded Together's network plugin needs it."
    $wg = Get-Command winget -ErrorAction SilentlyContinue
    $done = $false
    if ($wg) {
        $a = Read-Host "      Install it now with Windows' package manager (winget)? [Y/n]"
        if ($a -notmatch '^[nN]') {
            & winget install --id Microsoft.DotNet.Runtime.10 -e --source winget
            $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
            if (Has-DotNet10) { Ok ".NET 10 runtime installed"; $done = $true }
        }
    }
    if (-not $done) {
        Warn "Install '.NET Runtime 10' (Windows x64) from https://dotnet.microsoft.com/download/dotnet/10.0"
        Warn "then start RE7. (Continuing; everything else will be set up.)"
    }
}
# Smart App Control (Windows 11) blocks unsigned DLLs it doesn't know, REFramework's C# loader among them
# (REFCoreDeps.dll): then the co-op network plugin never starts. Only read here, never changed.
$sac = $null
try { $sac = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy" -ErrorAction Stop).VerifiedAndReputablePolicyState } catch { }
if ($sac -eq 1) {
    Warn "Windows' Smart App Control is ON. It can block REFramework's C# files, and then Molded Together"
    Warn "can't connect (the game shows 'network plugin isn't running'). See the README's Troubleshooting."
} elseif ($sac -eq 2) {
    Warn "Windows' Smart App Control is in evaluation mode. If Windows switches it on later, it can block"
    Warn "REFramework's C# files and Molded Together stops connecting. See the README's Troubleshooting."
} else { Ok "Smart App Control is off" }

# ---------------------------------------------------------------- 2. the game
Step 2 "Using RE7's own Steam folder (nothing is copied)"
# RE7 has two Steam versions: the current ray-tracing (RT) build, and the older DX11 one on the
# "dx11_non-rt" beta branch. REFramework detects either; Molded Together is tested on RT.
if ($found.Lib) {
    $acf = Join-Path $found.Lib "steamapps\appmanifest_$AppId.acf"
    if ((Test-Path $acf) -and ((Get-Content $acf -Raw) -match '"BetaKey"\s+"([^"]+)"')) {
        Warn "Your RE7 is on the Steam beta branch '$($Matches[1])' (the older non-RT version)."
        Warn "Molded Together is tested on the current (RT) version. If your friend doesn't appear, switch RE7"
        Warn "back to 'None' under Properties > Betas in Steam and run Install.cmd again."
    }
}
if (Test-Path $off) { Remove-Item -Force $off }   # it was switched off: installing switches it on again
Ok "RE7 found"

# ---------------------------------------------------------------- 3. REFramework
Step 3 "Downloading REFramework (official release, hash-checked)"
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("coop-re7-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory -Force $tmp | Out-Null
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.IO.Compression.FileSystem
foreach ($d in $Downloads) {
    $file = Join-Path $tmp $d.Name
    try { Invoke-WebRequest -UseBasicParsing -Uri "$Release/$($d.Name)" -OutFile $file }
    catch { Fail "couldn't download $($d.Name) (check your internet connection, then run Install.cmd again)" }
    $hash = (Get-FileHash $file -Algorithm SHA256).Hash.ToLower()
    if ($hash -ne $d.Sha) { Fail "$($d.Name) failed its integrity check (got $hash). Nothing was installed from it." }
    Ok "$($d.Name) verified"
}
# Only dinput8.dll from REFramework.zip (the other files are for VR and can cause issues).
$zip = [IO.Compression.ZipFile]::OpenRead((Join-Path $tmp "REFramework.zip"))
try {
    $entry = $zip.Entries | Where-Object { $_.FullName -eq "dinput8.dll" }
    if (-not $entry) { Fail "dinput8.dll not found in REFramework.zip" }
    [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $dll, $true)
} finally { $zip.Dispose() }
Expand-Archive -Path (Join-Path $tmp "csharp-api.zip") -DestinationPath $Game -Force
Remove-Item $tmp -Recurse -Force
Ok "REFramework + C# add-on installed"

# ---------------------------------------------------------------- 4. mod files
Step 4 "Installing Molded Together"
$src = Join-Path $Kit "reframework"
if (-not (Test-Path $src)) { Fail "this download's reframework folder is missing (unzip the whole download, then run Install.cmd from it)" }
$config = Join-Path $Game "reframework\data\coopnet_config.json"
$keepConfig = Test-Path $config
Get-ChildItem $src -Recurse -File | ForEach-Object {
    $rel = $_.FullName.Substring($src.Length + 1)
    $to = Join-Path (Join-Path $Game "reframework") $rel
    if ($keepConfig -and $rel -eq "data\coopnet_config.json") { return }   # keep the friend ID already set
    New-Item -ItemType Directory -Force (Split-Path $to) | Out-Null
    Copy-Item $_.FullName $to -Force
}
# coop_aggro.lua was dropped in v0.47: an old install's copy goes.
$old = Join-Path $Game "reframework\autorun\coop_aggro.lua"
if (Test-Path $old) { Remove-Item -Force $old }
Ok ("co-op scripts and network plugin installed" + $(if ($keepConfig) { " (kept your settings and friends)" } else { "" }))

# ---------------------------------------------------------------- 5. saves
Step 5 "Backing up your RE7 saves"
$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$userdata = Join-Path $found.Steam "userdata"
$any = $false
if (Test-Path $userdata) {
    foreach ($u in Get-ChildItem $userdata -Directory) {
        $remote = Join-Path $u.FullName "$AppId\remote"
        if (Test-Path $remote) {
            $to = Join-Path $BackupDir "$stamp\$($u.Name)"
            New-Item -ItemType Directory -Force $to | Out-Null
            Copy-Item "$remote\*" $to -Recurse -Force
            $any = $true
        }
    }
}
if ($any) { Ok "saves backed up to $BackupDir\$stamp" } else { Warn "no RE7 saves found yet (fine if you haven't played)" }

# Older versions (before v0.51) made a separate copy of the game; it isn't needed any more.
foreach ($c in @((Join-Path $env:SystemDrive "RE7-coop"), (Join-Path ([Environment]::GetFolderPath("MyDocuments")) "RE7-coop"))) {
    if (Test-Path (Join-Path $c "re7.exe")) {
        Write-Host ""
        Warn "An older version's copy of the game is still in $c. You don't need it any more:"
        Warn "delete that folder (and its 'Start Molded Together' desktop shortcut) to get the space back;"
        Warn "your saves aren't in it."
    }
}

Write-Host ""
Write-Host "All done." -ForegroundColor Green
Write-Host "1. Start RE7 from Steam as usual (Play). Molded Together loads with it."
Write-Host "   The very first start takes a few minutes longer (REFramework sets itself up once)."
Write-Host "2. In the game, press F9 for the co-op menu: Friends > pick your friend > Invite; they press F9 and Accept."
Write-Host "3. Saving is OFF until you switch on 'Allow saving' (F9 > Options). Your saves were backed up first."
Write-Host "4. To play RE7 without the mod, double-click 'Normal RE7 (mod off).cmd'. Install.cmd switches it back on."
Done
