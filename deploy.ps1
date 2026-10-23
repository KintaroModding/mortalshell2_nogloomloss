<#
.SYNOPSIS
    Copies the built mod (dist\<pakName>.pak/.utoc/.ucas) into the game's Paks\~mods folder and replaces old files
    safely.

.DESCRIPTION
    The running game locks the package files it loaded, and a file must not change while the game runs. The script
    checks all three target files first; with -Wait it waits until the game is closed. Each file is copied under a
    temporary name, checked, and then swapped in with one rename, so the game never sees a half-written file.

    Exit codes: 0 = deployed or already up to date, 2 = the game is running (without -Wait), 1 = error.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\deploy.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\deploy.ps1 -Wait
#>
param(
    # The game's install folder. Default: $env:UE5_GAMES_DIR\<gameFolder of mod.json>.
    [string]$GameDir,
    # The mods folder. Default: <GameDir>\<paksPath of mod.json>\~mods.
    [string]$ModsDir,
    # Wait until the game releases the files instead of stopping.
    [switch]$Wait,
    [int]$WaitMinutes = 360
)

$ErrorActionPreference = "Stop"

$mod = Get-Content (Join-Path $PSScriptRoot "mod.json") -Raw | ConvertFrom-Json
if (-not $ModsDir) {
    if (-not $GameDir) {
        if (-not $env:UE5_GAMES_DIR) {
            throw "The game folder is unknown: set UE5_GAMES_DIR (the folder that holds '$($mod.gameFolder)'), or use -GameDir or -ModsDir."
        }
        $GameDir = Join-Path $env:UE5_GAMES_DIR $mod.gameFolder
    }
    $paks = Join-Path $GameDir $mod.paksPath
    if (-not (Test-Path $paks)) {
        throw "The game's Paks folder is not there: $paks"
    }
    $ModsDir = Join-Path $paks "~mods"
}
New-Item -ItemType Directory -Force $ModsDir | Out-Null

function Test-Locked([string]$Path) {
    if (-not (Test-Path $Path)) {
        return $false
    }
    try {
        $stream = [System.IO.File]::Open($Path, 'Open', 'ReadWrite', 'None')
        $stream.Close()
        return $false
    } catch {
        return $true
    }
}

function Get-Hash([string]$Path) {
    try {
        return (Get-FileHash $Path -ErrorAction Stop).Hash
    } catch {
        return $null
    }
}

$files = @()
foreach ($extension in @("pak", "utoc", "ucas")) {
    $name = "$($mod.pakName).$extension"
    $source = Join-Path $PSScriptRoot "dist\$name"
    if (-not (Test-Path $source)) {
        throw "$source not found. Build it first with build.ps1."
    }
    $files += [pscustomobject]@{ Source = $source; Target = (Join-Path $ModsDir $name); Hash = (Get-Hash $source) }
}

$changed = @($files | Where-Object { (Get-Hash $_.Target) -ne $_.Hash })
if ($changed.Count -eq 0) {
    Write-Host "Already up to date: $ModsDir\$($mod.pakName).*" -ForegroundColor Green
    exit 0
}

$locked = @($changed | Where-Object { Test-Locked $_.Target })
if ($locked.Count -gt 0) {
    if (-not $Wait) {
        Write-Host "The game is running and uses $($locked[0].Target)." -ForegroundColor Yellow
        Write-Host "Close the game and run this again, or use the -Wait option." -ForegroundColor Yellow
        exit 2
    }
    Write-Host "The game is running. Waiting until it is closed (checking every 5 seconds)..."
    $deadline = (Get-Date).AddMinutes($WaitMinutes)
    while (@($changed | Where-Object { Test-Locked $_.Target }).Count -gt 0) {
        if ((Get-Date) -gt $deadline) {
            throw "The game did not release the mod files within $WaitMinutes minutes."
        }
        Start-Sleep -Seconds 5
    }
}

foreach ($file in $changed) {
    $temp = "$($file.Target).tmp"
    Copy-Item $file.Source $temp -Force
    if ((Get-Hash $temp) -ne $file.Hash) {
        Remove-Item $temp -Force
        throw "The copy in $temp is damaged. $($file.Target) was not replaced."
    }
    try {
        if (Test-Path $file.Target) {
            # [NullString]::Value: Windows PowerShell passes $null as "" to string parameters.
            [System.IO.File]::Replace($temp, $file.Target, [NullString]::Value)
        } else {
            Move-Item $temp $file.Target
        }
    } catch {
        Remove-Item $temp -Force -ErrorAction SilentlyContinue
        throw "Could not replace $($file.Target) (did the game start again?): $($_.Exception.Message)"
    }
    if ((Get-Hash $file.Target) -ne $file.Hash) {
        throw "Check failed: $($file.Target) does not match $($file.Source)."
    }
}
Write-Host "Deployed $($changed.Count) file(s) to $ModsDir" -ForegroundColor Green
