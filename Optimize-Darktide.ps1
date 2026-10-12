<#
.SYNOPSIS
    Re-applies stutter fixes and performance settings to Warhammer 40,000: Darktide.

.DESCRIPTION
    Darktide game updates (and "Verify integrity of game files") reset the engine
    config files in the install folder. Run this after every patch to put the fixes back.

    What it does:
      1. Engine streaming fixes (bundle\application_settings\settings_common.ini and
         win32_settings.ini): gives the texture and mesh streamers a budget sized to
         your graphics card and keeps streamed data resident longer. This targets the
         short 100-400 ms hitches ("Apply safe delete resources" / "wait_for_fence"
         in the game's console log) that show up as sudden FPS drops.
      2. Fixes win32_settings.ini so it matches your in-game choices. After a verify it
         ships with ray tracing ON, windowed mode and 1920x1080.
      3. Optional graphics profile (user_settings.config): turns off the settings that
         cost the most frames for the least visual gain. Upscaling, textures and
         Reflex are left as you set them.
      4. Optional: points your network adapters at Cloudflare DNS (fixes the
         "Backend Error - Error signing in" caused by some home routers' DNS).

    Every run backs up the files it touches first. Use -Restore to undo the last run.

.PARAMETER Preset
    Performance (default): engine fixes + the high-FPS graphics profile.
    EngineOnly:            engine fixes only, your graphics settings are untouched.

.PARAMETER SetDns
    Also set the DNS on your active physical network adapters to 1.1.1.1 / 1.0.0.1.

.PARAMETER DryRun
    Show what would change without writing anything.

.PARAMETER Restore
    Restore the files from the most recent backup made by this script.

.PARAMETER VramGB
    Override the detected graphics memory (in GB) used to size the streaming budget.

.PARAMETER GamePath
    Darktide install folder, if it can't be found automatically.

.EXAMPLE
    .\Optimize-Darktide.ps1
.EXAMPLE
    .\Optimize-Darktide.ps1 -DryRun
.EXAMPLE
    .\Optimize-Darktide.ps1 -Preset EngineOnly -SetDns
.EXAMPLE
    .\Optimize-Darktide.ps1 -Restore
#>
[CmdletBinding()]
param(
    [ValidateSet('Performance', 'EngineOnly')]
    [string]$Preset = 'Performance',
    [switch]$SetDns,
    [switch]$DryRun,
    [switch]$Restore,
    [double]$VramGB = 0,
    [string]$GamePath,
    [string]$UserSettingsPath,
    [switch]$NoPause,
    # Internal / testing: skip admin elevation and running-game checks.
    [switch]$NoElevate
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$ScriptVersion = '1.0.0'
$DarktideAppId = '1361210'
$Tab = "`t"

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
function Write-Step($msg)  { Write-Host "`n== $msg" -ForegroundColor Cyan }
function Write-Ok($msg)    { Write-Host "   [ok]   $msg" -ForegroundColor Green }
function Write-Change($msg){ Write-Host "   [set]  $msg" -ForegroundColor Yellow }
function Write-Skip($msg)  { Write-Host "   [skip] $msg" -ForegroundColor DarkGray }
function Write-Warn($msg)  { Write-Host "   [warn] $msg" -ForegroundColor Magenta }

function Exit-Script([int]$code) {
    if (-not $NoPause -and $Host.Name -eq 'ConsoleHost' -and [Environment]::UserInteractive) {
        Write-Host "`nPress Enter to close..." -NoNewline
        [void](Read-Host)
    }
    exit $code
}

# ---------------------------------------------------------------------------
# Text file model: keeps original line endings, writes UTF-8 without BOM
# ---------------------------------------------------------------------------
function Read-ConfigFile([string]$path) {
    $raw = [IO.File]::ReadAllText($path)
    $nl = if ($raw.Contains("`r`n")) { "`r`n" } else { "`n" }
    $trailing = $raw.EndsWith("`n")
    $body = if ($trailing) { $raw.Substring(0, $raw.Length - $nl.Length) } else { $raw }
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($l in ($body -split "\r?\n")) { $lines.Add($l) }
    return [pscustomobject]@{ Path = $path; Lines = $lines; NewLine = $nl; Trailing = $trailing; Changes = 0 }
}

function Save-ConfigFile($file) {
    $text = [string]::Join($file.NewLine, $file.Lines)
    if ($file.Trailing) { $text += $file.NewLine }
    [IO.File]::WriteAllText($file.Path, $text, (New-Object Text.UTF8Encoding $false))
}

# Returns @(startIndex, endIndex) of the lines strictly inside the block at $blockPath
# ('' = top level). Nested blocks are given as an array, e.g. @('win32','renderer').
function Get-BlockRange($file, [string[]]$blockPath) {
    $start = 0; $end = $file.Lines.Count - 1
    $depth = 0
    foreach ($name in $blockPath) {
        if (-not $name) { continue }
        $indent = $Tab * $depth
        $header = '^' + $indent + [regex]::Escape($name) + ' = \{\s*$'
        $closer = $indent + '}'
        $found = $false
        for ($i = $start; $i -le $end; $i++) {
            if ($file.Lines[$i] -match $header) {
                for ($j = $i + 1; $j -le $end; $j++) {
                    if ($file.Lines[$j].TrimEnd() -eq $closer) { $start = $i + 1; $end = $j - 1; $found = $true; break }
                }
                break
            }
        }
        if (-not $found) { return $null }
        $depth++
    }
    return @($start, $end, $depth)
}

function Format-Label([string[]]$blockPath, [string]$key) {
    $parts = @($blockPath | Where-Object { $_ }) + $key
    return ($parts -join '.')
}

# Set a scalar "key = value" line. $value is written verbatim (quote strings yourself).
function Set-ConfigValue($file, [string[]]$blockPath, [string]$key, [string]$value, [switch]$Quiet) {
    $label = Format-Label $blockPath $key
    $range = Get-BlockRange $file $blockPath
    if (-not $range) { Write-Warn "$label - section not found, left alone"; return }
    $indent = $Tab * $range[2]
    $pattern = '^' + $indent + [regex]::Escape($key) + ' = (.*)$'
    for ($i = $range[0]; $i -le $range[1]; $i++) {
        if ($file.Lines[$i] -match $pattern) {
            $old = $Matches[1].TrimEnd()
            if ($old -eq $value) { if (-not $Quiet) { Write-Ok "$label = $value" }; return }
            $file.Lines[$i] = $indent + $key + ' = ' + $value
            $file.Changes++
            if (-not $Quiet) { Write-Change "$label : $old -> $value" }
            return
        }
    }
    Write-Warn "$label - setting not found in this game version, left alone"
}

# Set an array value. Handles both the multi-line form used by user_settings.config
#   key = [
#       2560
#       1440
#   ]
# and the inline form used by the .ini files:  key = [ 2560 1440]
function Set-ConfigArray($file, [string[]]$blockPath, [string]$key, [int[]]$values, [switch]$Quiet) {
    $label = Format-Label $blockPath $key
    $want = ($values -join ', ')
    $range = Get-BlockRange $file $blockPath
    if (-not $range) { Write-Warn "$label - section not found, left alone"; return }
    $indent = $Tab * $range[2]
    $pattern = '^' + $indent + [regex]::Escape($key) + ' = \[(.*)$'
    for ($i = $range[0]; $i -le $range[1]; $i++) {
        if ($file.Lines[$i] -notmatch $pattern) { continue }
        $rest = $Matches[1]
        if ($rest -match '\]') {
            # inline
            $old = @([regex]::Matches($rest, '-?\d+(\.\d+)?') | ForEach-Object { $_.Value })
            if (($old -join ', ') -eq $want) { if (-not $Quiet) { Write-Ok "$label = [$want]" }; return }
            $file.Lines[$i] = $indent + $key + ' = [ ' + ($values -join ' ') + ']'
        } else {
            # multi-line
            $j = $i + 1; $old = @()
            while ($j -le $range[1] -and $file.Lines[$j].TrimEnd() -ne ($indent + ']')) { $old += $file.Lines[$j].Trim(); $j++ }
            if ($j -gt $range[1]) { Write-Warn "$label - could not parse, left alone"; return }
            if (($old -join ', ') -eq $want) { if (-not $Quiet) { Write-Ok "$label = [$want]" }; return }
            $file.Lines.RemoveRange($i + 1, $j - $i - 1)
            $k = $i + 1
            foreach ($v in $values) { $file.Lines.Insert($k, $indent + $Tab + $v); $k++ }
        }
        $file.Changes++
        if (-not $Quiet) { Write-Change "$label : [$($old -join ', ')] -> [$want]" }
        return
    }
    Write-Warn "$label - setting not found in this game version, left alone"
}

function Get-ConfigValue($file, [string[]]$blockPath, [string]$key) {
    $range = Get-BlockRange $file $blockPath
    if (-not $range) { return $null }
    $pattern = '^' + ($Tab * $range[2]) + [regex]::Escape($key) + ' = (.*)$'
    for ($i = $range[0]; $i -le $range[1]; $i++) {
        if ($file.Lines[$i] -match $pattern) { return $Matches[1].Trim().Trim('"') }
    }
    return $null
}

function Get-ConfigArray($file, [string[]]$blockPath, [string]$key) {
    $range = Get-BlockRange $file $blockPath
    if (-not $range) { return $null }
    $indent = $Tab * $range[2]
    $pattern = '^' + $indent + [regex]::Escape($key) + ' = \[(.*)$'
    for ($i = $range[0]; $i -le $range[1]; $i++) {
        if ($file.Lines[$i] -notmatch $pattern) { continue }
        $rest = $Matches[1]
        if ($rest -match '\]') { return @([regex]::Matches($rest, '-?\d+') | ForEach-Object { [int]$_.Value }) }
        $vals = @(); $j = $i + 1
        while ($j -le $range[1] -and $file.Lines[$j].TrimEnd() -ne ($indent + ']')) { $vals += [int]$file.Lines[$j].Trim(); $j++ }
        return $vals
    }
    return $null
}

# ---------------------------------------------------------------------------
# Locating the game
# ---------------------------------------------------------------------------
function Get-SteamRoots {
    $roots = @()
    foreach ($reg in @(
        @{ Path = 'HKCU:\Software\Valve\Steam'; Name = 'SteamPath' },
        @{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam'; Name = 'InstallPath' },
        @{ Path = 'HKLM:\SOFTWARE\Valve\Steam'; Name = 'InstallPath' })) {
        try {
            $v = (Get-ItemProperty -Path $reg.Path -Name $reg.Name -ErrorAction Stop).($reg.Name)
            if ($v) { $roots += ($v -replace '/', '\') }
        } catch { }
    }
    $roots += "${env:ProgramFiles(x86)}\Steam"
    return $roots | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique
}

function Find-DarktideInstall {
    $libraries = @()
    foreach ($root in Get-SteamRoots) {
        $libraries += $root
        $vdf = Join-Path $root 'steamapps\libraryfolders.vdf'
        if (Test-Path $vdf) {
            foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) {
                $libraries += ($m.Groups[1].Value -replace '\\\\', '\')
            }
        }
    }
    foreach ($lib in ($libraries | Select-Object -Unique)) {
        $installDir = 'Warhammer 40,000 DARKTIDE'
        $manifest = Join-Path $lib "steamapps\appmanifest_$DarktideAppId.acf"
        if (Test-Path $manifest) {
            $m = [regex]::Match((Get-Content $manifest -Raw), '"installdir"\s+"([^"]+)"')
            if ($m.Success) { $installDir = $m.Groups[1].Value }
        }
        $candidate = Join-Path $lib "steamapps\common\$installDir"
        if (Test-Path (Join-Path $candidate 'bundle\application_settings')) { return $candidate }
    }
    return $null
}

# Dedicated VRAM in GB for the biggest GPU. Win32_VideoController caps at 4 GB,
# so read the 64-bit value the driver stores in the registry.
function Get-VramGB {
    $best = 0
    $class = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
    try {
        foreach ($key in @(Get-ChildItem $class -ErrorAction SilentlyContinue)) {
            try {
                $p = Get-ItemProperty $key.PSPath -ErrorAction Stop
                $bytes = $null
                if ($p.PSObject.Properties['HardwareInformation.qwMemorySize']) { $bytes = [double]$p.'HardwareInformation.qwMemorySize' }
                elseif ($p.PSObject.Properties['HardwareInformation.MemorySize']) {
                    $v = $p.'HardwareInformation.MemorySize'
                    if ($v -is [byte[]]) { $bytes = [double][BitConverter]::ToUInt32($v, 0) } else { $bytes = [double]$v }
                }
                if ($bytes) { $gb = $bytes / 1GB; if ($gb -gt $best) { $best = $gb } }
            } catch { }
        }
    } catch { }
    if ($best -eq 0) {
        try { $best = ((Get-CimInstance Win32_VideoController | Measure-Object AdapterRAM -Maximum).Maximum) / 1GB } catch { }
    }
    return [math]::Round($best, 1)
}

function Test-IsAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        return (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

# ---------------------------------------------------------------------------
# Start
# ---------------------------------------------------------------------------
Write-Host "Darktide Optimizer v$ScriptVersion" -ForegroundColor White
Write-Host "Unofficial community tool - not affiliated with Fatshark." -ForegroundColor DarkGray
if ($DryRun) { Write-Host "DRY RUN - nothing will be written." -ForegroundColor Yellow }

$onWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT

if (-not $GamePath) { $GamePath = Find-DarktideInstall }
if (-not $GamePath -or -not (Test-Path (Join-Path $GamePath 'bundle\application_settings'))) {
    Write-Host "`nCould not find Darktide. Run again with -GamePath ""<your Darktide folder>""" -ForegroundColor Red
    Exit-Script 1
}
if (-not $UserSettingsPath) { $UserSettingsPath = Join-Path $env:APPDATA 'Fatshark\Darktide\user_settings.config' }

$appSettings = Join-Path $GamePath 'bundle\application_settings'
$commonIni   = Join-Path $appSettings 'settings_common.ini'
$win32Ini    = Join-Path $appSettings 'win32_settings.ini'
$backupRoot  = Join-Path (Split-Path $UserSettingsPath -Parent) 'optimizer-backups'

Write-Host "Game folder:   $GamePath"
Write-Host "User settings: $UserSettingsPath"

# The game rewrites user_settings.config when it exits, so it must be closed.
if (-not $NoElevate -and $onWindows -and (Get-Process -Name 'Darktide' -ErrorAction SilentlyContinue)) {
    Write-Host "`nDarktide is running. Close the game first - it overwrites its settings on exit." -ForegroundColor Red
    Exit-Script 1
}

# Writing inside Program Files needs admin rights. Relaunch elevated with the same arguments.
if (-not $DryRun -and -not $NoElevate -and $onWindows -and -not (Test-IsAdmin)) {
    Write-Host "`nAdministrator rights are needed to edit files in the game folder. Requesting elevation..." -ForegroundColor Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    foreach ($kv in $PSBoundParameters.GetEnumerator()) {
        if ($kv.Value -is [switch]) { if ($kv.Value.IsPresent) { $argList += "-$($kv.Key)" } }
        else { $argList += "-$($kv.Key)"; $argList += "`"$($kv.Value)`"" }
    }
    # The elevated window resolves %APPDATA% for the same user, but pass it explicitly to be safe.
    if (-not $PSBoundParameters.ContainsKey('UserSettingsPath')) { $argList += '-UserSettingsPath'; $argList += "`"$UserSettingsPath`"" }
    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs | Out-Null
    } catch {
        Write-Host "Elevation was cancelled. Nothing was changed." -ForegroundColor Red
        Exit-Script 1
    }
    exit 0
}

# ---------------------------------------------------------------------------
# Restore
# ---------------------------------------------------------------------------
if ($Restore) {
    Write-Step 'Restoring from backup'
    $latest = Get-ChildItem $backupRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
    if (-not $latest) { Write-Host "No backups found in $backupRoot" -ForegroundColor Red; Exit-Script 1 }
    $manifest = Get-Content (Join-Path $latest.FullName 'manifest.json') -Raw | ConvertFrom-Json
    foreach ($entry in $manifest.files) {
        $src = Join-Path $latest.FullName $entry.backup
        if ($DryRun) { Write-Change "would restore $($entry.original)" }
        else { Copy-Item $src $entry.original -Force; Write-Change "restored $($entry.original)" }
    }
    Write-Host "`nRestored the backup from $($latest.Name)." -ForegroundColor Green
    Exit-Script 0
}

# ---------------------------------------------------------------------------
# Load files
# ---------------------------------------------------------------------------
$files = @()
$common = Read-ConfigFile $commonIni; $files += $common
$win32  = Read-ConfigFile $win32Ini;  $files += $win32
$user = $null
if (Test-Path $UserSettingsPath) { $user = Read-ConfigFile $UserSettingsPath; $files += $user }
else { Write-Warn "user_settings.config not found - launch the game once first. Graphics profile and display sync skipped." }

$gameVersion = Get-ConfigValue $common @('script_data') 'game_version'
if ($gameVersion) { Write-Host "Game version:  $gameVersion" }

# ---------------------------------------------------------------------------
# 1. Engine streaming budget, sized to VRAM
# ---------------------------------------------------------------------------
if ($VramGB -le 0) { $VramGB = Get-VramGB }
Write-Step "Texture and mesh streaming (graphics memory: $VramGB GB)"

if ($VramGB -ge 12) {
    $stream = @{ Pool = 2048; MaxPool = 4096; MeshLimit = 1400 }
} elseif ($VramGB -ge 8) {
    $stream = @{ Pool = 1024; MaxPool = 2048; MeshLimit = 1000 }
} else {
    $stream = $null
}

if ($stream) {
    Set-ConfigValue $common @('feedback_streamer_settings') 'max_texture_pool_size' $stream.MaxPool
    Set-ConfigValue $common @('feedback_streamer_settings') 'tile_age_out_time_ms' 30000
    Set-ConfigValue $common @('feedback_streamer_settings') 'max_age_out_tiles_per_frame' 16
    Set-ConfigValue $common @('mesh_streamer_settings') 'limit' $stream.MeshLimit
    Set-ConfigValue $common @('mesh_streamer_settings') 'eviction_timeout' 30
    Set-ConfigValue $common @('texture_streamer_settings') 'streaming_texture_pool_size' $stream.Pool
    Set-ConfigValue $common @('texture_streamer_settings') 'streaming_buffer_size' 128
    Set-ConfigValue $common @() 'streaming_texture_pool_size' $stream.Pool
    Set-ConfigValue $common @() 'streaming_buffer_size' 64
    Set-ConfigValue $win32 @('win32') 'streaming_texture_pool_size' $stream.Pool
    Set-ConfigValue $win32 @('win32') 'streaming_buffer_size' 128
} else {
    Write-Skip "Less than 8 GB of graphics memory detected - streaming budget left at Fatshark's defaults."
    Write-Skip "If detection is wrong, run again with -VramGB <size>."
}

# ---------------------------------------------------------------------------
# 2. Make win32_settings.ini agree with the in-game display settings
# ---------------------------------------------------------------------------
Write-Step 'Display settings in win32_settings.ini'
if ($user) {
    $mode = Get-ConfigValue $user @() 'screen_mode'
    $res  = Get-ConfigArray $user @() 'screen_resolution'
    $rtRefl = Get-ConfigValue $user @('master_render_settings') 'rt_reflections_quality'
    $rtGi   = Get-ConfigValue $user @('master_render_settings') 'rtxgi_quality'
    $rtOn = ($rtRefl -and $rtRefl -ne 'off') -or ($rtGi -and $rtGi -ne 'off')
    if ($Preset -eq 'Performance') { $rtOn = $false }
    if ($mode) { Set-ConfigValue $win32 @('win32', 'renderer') 'fullscreen' ($(if ($mode -eq 'fullscreen') { 'true' } else { 'false' })) }
    if ($res -and $res.Count -eq 2) { Set-ConfigArray $win32 @('win32', 'renderer') 'screen_resolution' $res }
    Set-ConfigValue $win32 @('win32', 'renderer') 'ray_tracing' ($(if ($rtOn) { 'true' } else { 'false' }))
} else {
    Write-Skip 'No user settings yet - skipped.'
}

# ---------------------------------------------------------------------------
# 3. Graphics profile
# ---------------------------------------------------------------------------
if ($user -and $Preset -eq 'Performance') {
    Write-Step 'Performance graphics profile (upscaling, textures and Reflex are not touched)'
    $M = @('master_render_settings'); $R = @('render_settings')
    $mrs = $M; $rs = $R

    Set-ConfigValue $user $mrs 'graphics_quality' '"custom"'

    # Ambient occlusion: low
    Set-ConfigValue $user $mrs 'ambient_occlusion_quality' '"low"'
    Set-ConfigValue $user $rs 'ao_enabled' 'true' -Quiet
    Set-ConfigValue $user $rs 'gtao_enabled' 'true' -Quiet
    Set-ConfigValue $user $rs 'gtao_quality' '0' -Quiet
    Set-ConfigValue $user $rs 'cacao_enabled' 'false' -Quiet

    # Lighting / shadows: medium
    Set-ConfigValue $user $mrs 'light_quality' '"medium"'
    Set-ConfigValue $user $rs 'local_lights_shadow_map_filter_quality' '"low"' -Quiet
    Set-ConfigValue $user $rs 'sun_shadow_map_filter_quality' '"medium"' -Quiet
    Set-ConfigValue $user $rs 'sun_shadows' 'true' -Quiet
    Set-ConfigArray $user $rs 'local_lights_shadow_atlas_size' @(1024, 1024) -Quiet

    # Volumetric fog: low (biggest single FPS win in Darktide)
    Set-ConfigValue $user $mrs 'volumetric_fog_quality' '"low"'
    Set-ConfigValue $user $rs 'light_shafts_enabled' 'false' -Quiet
    Set-ConfigValue $user $rs 'volumetric_reprojection_amount' '0.875' -Quiet
    Set-ConfigArray $user $rs 'volumetric_data_size' @(80, 64, 96) -Quiet
    Set-ConfigValue $user $rs 'volumetric_extrapolation_high_quality' 'false' -Quiet
    Set-ConfigValue $user $rs 'volumetric_lighting_local_lights' 'false' -Quiet

    # Screen-space reflections, depth of field, lens flare, motion blur: off
    Set-ConfigValue $user $mrs 'ssr_quality' '"off"'
    Set-ConfigValue $user $rs 'ssr_enabled' 'false' -Quiet
    Set-ConfigValue $user $rs 'ssr_high_quality' 'false' -Quiet
    Set-ConfigValue $user $mrs 'dof_quality' '"off"'
    Set-ConfigValue $user $rs 'dof_enabled' 'false' -Quiet
    Set-ConfigValue $user $mrs 'lens_flare_quality' '"off"'
    Set-ConfigValue $user $rs 'lens_flares_enabled' 'false' -Quiet
    Set-ConfigValue $user $rs 'motion_blur_enabled' 'false'

    # Ray tracing: off
    Set-ConfigValue $user $mrs 'rt_reflections_quality' '"off"'
    Set-ConfigValue $user $mrs 'rtxgi_quality' '"off"'
    Set-ConfigValue $user $rs 'rt_reflections_enabled' 'false' -Quiet
    Set-ConfigValue $user $rs 'rtxgi_enabled' 'false' -Quiet

    # FSR frame generation has a known GPU-crash issue on Radeon RX 9000 cards
    # (Fatshark known issues, patch 1.11.x) and is unstable in exclusive fullscreen.
    $gpu = Get-ConfigValue $user @() 'gpu_id'
    if ($gpu -match 'Radeon RX 9\d\d\d') {
        Set-ConfigValue $user $mrs 'ffx_frame_gen' '0'
        Set-ConfigValue $user $rs 'ffx_frame_gen_enabled' 'false' -Quiet
        Set-ConfigValue $user $rs 'ffx_swapchain' 'false' -Quiet
    } else {
        Write-Skip 'Frame generation left as you set it'
    }
} elseif ($user) {
    Write-Step 'Graphics profile'
    Write-Skip 'EngineOnly - your in-game graphics settings were not touched.'
}

# ---------------------------------------------------------------------------
# Write (with backup)
# ---------------------------------------------------------------------------
$changed = @($files | Where-Object { $_.Changes -gt 0 })
$total = ($files | Measure-Object Changes -Sum).Sum

if ($changed.Count -gt 0 -and -not $DryRun) {
    $stamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
    $dir = Join-Path $backupRoot $stamp
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $entries = @()
    foreach ($f in $changed) {
        $name = Split-Path $f.Path -Leaf
        Copy-Item $f.Path (Join-Path $dir $name) -Force
        $entries += [pscustomobject]@{ original = $f.Path; backup = $name }
    }
    [pscustomobject]@{ created = $stamp; scriptVersion = $ScriptVersion; gameVersion = $gameVersion; files = $entries } |
        ConvertTo-Json -Depth 4 | Set-Content (Join-Path $dir 'manifest.json') -Encoding UTF8
    foreach ($f in $changed) { Save-ConfigFile $f }
    Write-Host "`nBackup saved to $dir" -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# 4. Optional DNS
# ---------------------------------------------------------------------------
if ($SetDns) {
    Write-Step 'DNS (Cloudflare 1.1.1.1 / 1.0.0.1)'
    if (-not $onWindows) { Write-Skip 'Not on Windows.' }
    else {
        $adapters = @(Get-NetAdapter -Physical | Where-Object Status -eq 'Up')
        if (-not $adapters) { Write-Warn 'No connected physical network adapter found.' }
        foreach ($a in $adapters) {
            $current = (Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4).ServerAddresses -join ', '
            if ($current -eq '1.1.1.1, 1.0.0.1') { Write-Ok "$($a.Name) already uses Cloudflare DNS"; continue }
            if ($DryRun) { Write-Change "$($a.Name): $current -> 1.1.1.1, 1.0.0.1 (dry run)"; continue }
            Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ServerAddresses '1.1.1.1', '1.0.0.1'
            Write-Change "$($a.Name): $current -> 1.1.1.1, 1.0.0.1"
            Write-Host "          undo: Set-DnsClientServerAddress -InterfaceIndex $($a.ifIndex) -ResetServerAddresses" -ForegroundColor DarkGray
        }
        if (-not $DryRun) { Clear-DnsClientCache }
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ''
if ($total -eq 0) {
    Write-Host 'Everything was already set. Nothing to do.' -ForegroundColor Green
} elseif ($DryRun) {
    Write-Host "$total setting(s) would change. Run without -DryRun to apply." -ForegroundColor Yellow
} else {
    Write-Host "Done - $total setting(s) changed. Start Darktide as normal." -ForegroundColor Green
    Write-Host 'Run this again after every Darktide update or file verification.' -ForegroundColor DarkGray
}
Exit-Script 0
