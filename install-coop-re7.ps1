# install-coop-re7.ps1: one-click setup for Molded Together, the Resident Evil 7 co-op mod.
#
# Since v0.51 it installs into RE7's own Steam folder only: afterwards you start RE7 with Steam's Play button
# and the mod loads with it. Nothing is copied.
#  1. Checks your PC (.NET 10 runtime, which it offers to install; Windows' Smart App Control).
#  2. Finds RE7 in your Steam libraries.
#  3. Downloads REFramework and its C# add-on from the official release and checks each file's SHA-256.
#  4. Installs the co-op files from this kit, keeping your co-op settings and friends.
#  5. Full character models: sets up "Third Person Full Model Placeholders RT (2022)" by AfroJackX (Nexus RE7 mod
#     86) from the zip you downloaded (see below). Before v0.52 this was a separate "Use full models.cmd".
#  6. Backs up your RE7 saves.
#
# Run it with Install.cmd (double-click). "Normal RE7 (mod off).cmd" runs it with -Disable: that switches the
# mod off (renames REFramework's dinput8.dll) so RE7 starts normally; Install.cmd switches it on again.
#
# The models are the mod author's files, so this kit doesn't ship them and can't fetch them for you: Nexus Mods
# only lets a signed-in account download (a free account is enough), and its terms don't allow scripts to do
# it. So step 5 looks for the zip in Downloads (and on the Desktop and next to this kit), and if it isn't there
# it opens the mod's page, waits for you to click "Manual download", and carries on by itself once the zip
# is in Downloads. Skipping it is fine: the mod works without it, characters other than Ethan may lack a face.

param(
    [switch]$Disable,
    [string]$GameDir = "",  # advanced: an RE7 folder to use instead of the one found in Steam
    [string]$BackupDir = "",
    [switch]$Elevated,      # set when the installer restarted itself as administrator
    [switch]$SteamFolder,   # accepted for older wrappers (v0.50.1's "Install into Steam.cmd"); always on now
    [switch]$ModelsOnly,    # only step 5 (set the full models up now, e.g. after downloading them later)
    [switch]$NoPrompt,      # never ask or wait (step 5 then only uses a download it finds at once)
    [string]$ModelsFrom = "" # advanced: the models download (zip or unzipped folder) to use instead of searching
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

function Step($n, $text) { Write-Host ""; Write-Host "[$n/6] $text" -ForegroundColor Cyan }
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

# ---------------------------------------------------------------- full character models (step 5)
# RE7's own player models are incomplete (no real face). "Third Person Full Model Placeholders" by AfroJackX
# (Nexus RE7 mod 86) replaces them with complete ones under the same paths. Left where it puts them they would
# also replace your own first-person body (you'd see the inside of your character's head), so the model files
# (*.mesh.*, *.mdf2.*) are moved to natives\stm\coop, which only the co-op lobby reads; textures stay where they
# are. REFramework only reads loose files with its Loose File Loader on, so that is switched on too. CoopNet.cs
# keeps the move right at every start. Running this again only moves what's left.
$ModelsPage = "https://www.nexusmods.com/residentevil7/mods/86?tab=files"
$ModelsFile = "Third Person Full Model Placeholders RT (2022)"   # the Nexus file this is set up and tested with
$ModelsProbe = "character\player\pl2000\pl2001\pl2001.mesh.220128762"   # a file only that mod has (the lobby checks it too)
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Get-DownloadsFolder {
    try {
        $p = (New-Object -ComObject Shell.Application).Namespace("shell:Downloads").Self.Path
        if ($p) { return $p }
    } catch { }
    return (Join-Path $env:USERPROFILE "Downloads")
}

# A zip that has finished downloading (a browser's half-written file doesn't open) and has a natives folder.
function Test-ModelsZip($path) {
    try {
        $z = [IO.Compression.ZipFile]::OpenRead($path)
        try { return [bool]($z.Entries | Where-Object { $_.FullName -match '(^|[\\/])natives[\\/]' } | Select-Object -First 1) }
        finally { $z.Dispose() }
    } catch { return $false }
}

# The download (zip, or an unzipped folder that still has its natives folder), newest first.
function Find-ModelsDownload {
    if ($ModelsFrom -ne "") { if (Test-Path $ModelsFrom) { return (Get-Item $ModelsFrom) } else { return $null } }
    $places = @((Get-DownloadsFolder), [Environment]::GetFolderPath("Desktop"), $Kit, (Split-Path -Parent $Kit))
    foreach ($p in $places) {
        if (-not (Test-Path $p)) { continue }
        foreach ($c in (Get-ChildItem $p -Filter "$ModelsFile*" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)) {
            if ($c.PSIsContainer) {
                if (Get-ChildItem $c.FullName -Directory -Recurse -Filter "natives" -ErrorAction SilentlyContinue | Select-Object -First 1) { return $c }
            } elseif ($c.Extension -eq ".zip" -and (Test-ModelsZip $c.FullName)) { return $c }
        }
    }
    return $null
}

function Install-FullModels {
    $stm = Join-Path $Game "natives\stm"
    $coopProbe = Join-Path $stm ("coop\" + $ModelsProbe)
    $plainProbe = Join-Path $stm $ModelsProbe
    Write-Host "      Models by AfroJackX: 'Third Person Full Model Placeholders' (Nexus RE7 mod 86). Thank you!"
    if (-not ((Test-Path $coopProbe) -or (Test-Path $plainProbe))) {
        $dl = Find-ModelsDownload
        if (-not $dl -and -not $NoPrompt -and [Environment]::UserInteractive) {
            Write-Host "      Not in your Downloads folder yet. They come from Nexus Mods, where downloading needs you to be"
            Write-Host "      signed in (a free account is enough); a script can't do that for you."
            $a = Read-Host "      Open the page now? Click 'Manual download' on '$ModelsFile' [Y/n]"
            if ($a -notmatch '^[nN]') {
                try { Start-Process $ModelsPage } catch { Warn "couldn't open a browser: go to $ModelsPage" }
                Write-Host "      Waiting for the download to finish (up to 10 minutes). Press Enter to skip..."
                $until = (Get-Date).AddMinutes(10)
                while (-not $dl -and (Get-Date) -lt $until) {
                    Start-Sleep -Seconds 2
                    $dl = Find-ModelsDownload
                    try { if (-not $dl -and [Console]::KeyAvailable) { [void][Console]::ReadKey($true); break } } catch { }
                }
            }
        }
        if (-not $dl) {
            $other = Get-ChildItem (Get-DownloadsFolder) -Filter "Third Person Full Model Placeholders*" -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notlike "$ModelsFile*" } | Select-Object -First 1
            if ($other) { Warn "found '$($other.Name)', but Molded Together is set up for the file named '$ModelsFile'." }
            Warn "Full character models not installed (the mod works without them; characters other than Ethan may lack a face)."
            Warn "To add them later: download '$ModelsFile' from $ModelsPage"
            Warn "into your Downloads folder (no need to unzip it), then double-click Install.cmd again."
            return
        }
        Write-Host "      Found the download: $($dl.Name)"
        $from = $dl.FullName
        $tmpx = $null
        if (-not $dl.PSIsContainer) {
            $tmpx = Join-Path ([IO.Path]::GetTempPath()) ("coop-re7-models-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
            Expand-Archive -Path $dl.FullName -DestinationPath $tmpx -Force
            $from = $tmpx
        }
        $natives = Get-ChildItem $from -Directory -Recurse -Filter "natives" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($natives) {
            Copy-Item -Path $natives.FullName -Destination $Game -Recurse -Force
            Ok "the mod's files copied into the game folder"
        } else { Warn "that download has no 'natives' folder; nothing was installed from it" }
        if ($tmpx) { Remove-Item -Recurse -Force $tmpx -ErrorAction SilentlyContinue }
    }

    $moved = 0
    foreach ($top in @("character", "ch8", "ch9")) {
        $dir = Join-Path $stm $top
        if (-not (Test-Path $dir)) { continue }
        Get-ChildItem $dir -Recurse -File | Where-Object { $_.Name -match '\.(mesh|mdf2)\.\d+$' } | ForEach-Object {
            $rel = $_.FullName.Substring($stm.Length + 1)
            $dest = Join-Path (Join-Path $stm "coop") $rel
            New-Item -ItemType Directory -Force (Split-Path $dest) | Out-Null
            Move-Item -Force $_.FullName $dest
            $moved++
        }
    }
    if ($moved -gt 0) { Ok "moved $moved model files to natives\stm\coop (your own first-person view stays normal)" }
    elseif (Test-Path $coopProbe) { Ok "model files already set up" }
    else { Warn "no model files found: nothing to set up"; return }

    $cfg = Join-Path $Game "re2_fw_config.txt"
    if (Test-Path $cfg) {
        $text = Get-Content $cfg -Raw
        if ($text -match 'LooseFileLoader_Enabled=false') {
            Set-Content -Path $cfg -Value ($text -replace 'LooseFileLoader_Enabled=false', 'LooseFileLoader_Enabled=true') -NoNewline -Encoding Ascii
            Ok "switched on REFramework's Loose File Loader"
        } elseif ($text -notmatch 'LooseFileLoader_Enabled=true') {
            Add-Content -Path $cfg -Value "LooseFileLoader_Enabled=true" -Encoding Ascii
            Ok "switched on REFramework's Loose File Loader"
        } else { Ok "Loose File Loader already on" }
    } else {
        Set-Content -Path $cfg -Value "LooseFileLoader_Enabled=true" -Encoding Ascii
        Ok "switched on REFramework's Loose File Loader"
    }
    Ok "full character models installed (the Lobby says 'Full character models: installed')"
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
    if ($ModelsOnly) { $argList += "-ModelsOnly" }
    if ($ModelsFrom -ne "") { $argList += @("-ModelsFrom", "`"$ModelsFrom`"") }
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

if ($ModelsOnly) {
    Step 5 "Full character models (the Nexus mod by AfroJackX)"
    Install-FullModels
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
$copied = 0
$inPlace = 0
Get-ChildItem $src -Recurse -File | ForEach-Object {
    $rel = $_.FullName.Substring($src.Length + 1)
    $to = Join-Path (Join-Path $Game "reframework") $rel
    if ($keepConfig -and $rel -eq "data\coopnet_config.json") { return }   # keep the friend ID already set
    # This download unzipped into RE7's own folder (the Steam folder) is its own destination: Copy-Item refuses to
    # copy a file onto itself ("Cannot overwrite the item ... with itself") and the install stopped there. Such a
    # file is already where it belongs.
    if ([string]::Equals([IO.Path]::GetFullPath($_.FullName), [IO.Path]::GetFullPath($to), [StringComparison]::OrdinalIgnoreCase)) { $script:inPlace++; return }
    New-Item -ItemType Directory -Force (Split-Path $to) | Out-Null
    Copy-Item $_.FullName $to -Force
    $script:copied++
}
if ($inPlace -gt 0 -and $copied -eq 0) {
    Warn "this download was unzipped inside RE7's own folder, so its co-op files are already in place."
}
# coop_aggro.lua was dropped in v0.47: an old install's copy goes.
$old = Join-Path $Game "reframework\autorun\coop_aggro.lua"
if (Test-Path $old) { Remove-Item -Force $old }
Ok ("co-op scripts and network plugin installed" + $(if ($keepConfig) { " (kept your settings and friends)" } else { "" }))

# ---------------------------------------------------------------- 5. full character models
Step 5 "Full character models (the Nexus mod by AfroJackX)"
Install-FullModels

# ---------------------------------------------------------------- 6. saves
Step 6 "Backing up your RE7 saves"
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
