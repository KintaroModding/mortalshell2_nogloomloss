<#
.SYNOPSIS
    Builds the mod (the src folder) into dist\<pakName>.pak/.utoc/.ucas, the files for the game's Paks\~mods folder.

.DESCRIPTION
    Reads mod.json. Uses UAssetGUI and retoc from the shared _tools folder of the modding base folder
    ($env:UE5_TOOLS overrides it):
      1. converts every src\**\*.json (UAssetGUI JSON of a changed game asset) into dist\stage\**\*.uasset/.uexp with
         UAssetGUI fromjson. UAssetGUI reads the mapping file <mappings>.usmap from %LOCALAPPDATA%\UAssetGUI\Mappings;
         the script copies it there from _tools\gamedata\<game>\ when it finds it there. A struct that the game made in
         the editor (UserDefinedStruct) is not in the mapping file: UAssetGUI loads its asset from disk, below the
         first folder named Content above the file it converts, and writes nothing when it does not find it. So the
         script puts the structs that mod.json lists ("structs") into dist\read, and converts each file from a copy in
         dist\read\<Project>\Content\. A struct comes from deps\ (legacy files at their game path) when deps\ holds
         it, else from the installed game (retoc reads the game's Paks folder, not its ~mods subfolder). The structs
         are game files: deps\ stays out of a public repository;
      2. packs dist\stage into dist\<pakName>.utoc/.ucas/.pak with retoc to-zen;
      3. checks the result: converts the container back to legacy files (retoc to-legacy) and then to JSON, and
         compares every asset with its source (scripts\check_build.py, needs Python). retoc needs the game's own
         containers for this, to find the names of the game objects that the mod's assets reference: the script
         links them into dist\verify\in with hard links (same drive only; nothing is copied) and removes the links
         after the check; removing a link leaves the game file as it is. Encrypted containers need the game's AES key
         from _tools\gamedata\<game>\game.json ("aesKey"); an unencrypted game needs none. Without the game folder,
         Python or a hard link, the check is skipped with a warning.
    With -Deploy, deploy.ps1 then copies the three files into the game's Paks\~mods folder. After a good build,
    dist\ holds only the three mod files.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\build.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\build.ps1 -Deploy
#>
param(
    # Copy the files to the game's Paks\~mods folder after the build (see deploy.ps1).
    [switch]$Deploy,
    # The game's install folder. Default: $env:UE5_GAMES_DIR\<gameFolder of mod.json>.
    [string]$GameDir
)

$ErrorActionPreference = "Stop"

$root = $PSScriptRoot
$mod = Get-Content (Join-Path $root "mod.json") -Raw | ConvertFrom-Json
$src = Join-Path $root "src"
$dist = Join-Path $root "dist"
$stage = Join-Path $dist "stage"
$read = Join-Path $dist "read"
$verify = Join-Path $dist "verify"
$verifyIn = Join-Path $verify "in"

# The shared tools: $env:UE5_TOOLS, else the first _tools folder above the project.
function Find-Tools {
    if ($env:UE5_TOOLS) {
        return $env:UE5_TOOLS
    }
    $dir = Split-Path $root -Parent
    while ($dir) {
        $candidate = Join-Path $dir "_tools"
        if (Test-Path $candidate) {
            return $candidate
        }
        $dir = Split-Path $dir -Parent
    }
    throw "No _tools folder above $root. Put UAssetGUI and retoc into _tools\uassetgui and _tools\retoc above the project, or set UE5_TOOLS."
}

# UAssetGUI is a Windows program: Start-Process waits for it, the call operator would not.
function Invoke-UAssetGUI([string[]]$Arguments) {
    $quoted = $Arguments | ForEach-Object { '"' + $_ + '"' }
    $process = Start-Process -FilePath $uassetgui -ArgumentList $quoted -Wait -PassThru -NoNewWindow
    return $process.ExitCode
}

# Runs UAssetGUI on a copy of $File (and the files with the same name and another extension, for example the .uexp
# of a .uasset) in dist\read\<Project>\Content\, so that it finds the structs in dist\read.
function Invoke-UAssetGUIInRead([string]$Command, [string]$File, [string]$Relative, [string]$Target, [string[]]$Rest) {
    $contentDir = Join-Path $read "$($Relative.Split('\')[0])\Content"
    New-Item -ItemType Directory -Force $contentDir | Out-Null
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($File)
    $copies = @()
    foreach ($part in Get-ChildItem -LiteralPath (Split-Path $File -Parent) -File | Where-Object { $_.BaseName -eq $stem }) {
        $copy = Join-Path $contentDir $part.Name
        Copy-Item -LiteralPath $part.FullName $copy -Force
        $copies += $copy
    }
    New-Item -ItemType Directory -Force (Split-Path $Target -Parent) | Out-Null
    try {
        $code = Invoke-UAssetGUI (@($Command, (Join-Path $contentDir (Split-Path $File -Leaf)), $Target) + $Rest)
    } finally {
        $copies | ForEach-Object { Remove-Item -LiteralPath $_ }
    }
    if ($code -ne 0 -or -not (Test-Path -LiteralPath $Target)) {
        throw "UAssetGUI $Command failed for $Relative (exit code $code; a struct missing in mod.json ""structs""?)"
    }
}

$tools = Find-Tools
$uassetgui = Join-Path $tools "uassetgui\UAssetGUI.exe"
$retoc = Join-Path $tools "retoc\retoc.exe"
foreach ($tool in @($uassetgui, $retoc)) {
    if (-not (Test-Path $tool)) {
        throw "$tool not found. UAssetGUI: https://github.com/atenfyr/UAssetGUI/releases, retoc: https://github.com/trumank/retoc/releases"
    }
}

# The mapping file, where UAssetGUI looks for it.
$mappingsDir = Join-Path $env:LOCALAPPDATA "UAssetGUI\Mappings"
$mappingFile = Join-Path $mappingsDir "$($mod.mappings).usmap"
$gameDataMapping = Join-Path $tools "gamedata\$($mod.game)\$($mod.mappings).usmap"
if (Test-Path $gameDataMapping) {
    if (-not (Test-Path $mappingFile) -or (Get-FileHash $gameDataMapping).Hash -ne (Get-FileHash $mappingFile).Hash) {
        New-Item -ItemType Directory -Force $mappingsDir | Out-Null
        Copy-Item $gameDataMapping $mappingFile -Force
        Write-Host "Copied $($mod.mappings).usmap to $mappingsDir"
    }
}
if (-not (Test-Path $mappingFile)) {
    throw "Mapping file missing: $mappingFile. Get the game's .usmap (see README.md) and put it there."
}

# retoc takes the AES key before the command; an unencrypted game needs none.
$gameJson = Join-Path $tools "gamedata\$($mod.game)\game.json"
$aesKey = if (Test-Path $gameJson) { (Get-Content $gameJson -Raw | ConvertFrom-Json).aesKey } else { "" }
$keyArgs = if ($aesKey) { @("-a", $aesKey) } else { @() }

if (-not $GameDir -and $env:UE5_GAMES_DIR) {
    $GameDir = Join-Path $env:UE5_GAMES_DIR $mod.gameFolder
}
$paks = if ($GameDir) { Join-Path $GameDir $mod.paksPath } else { "" }
$hasGame = $paks -and (Test-Path (Join-Path $paks "global.utoc"))

New-Item -ItemType Directory -Force $dist | Out-Null
foreach ($folder in @($stage, $read, $verify)) {
    if (Test-Path -LiteralPath $folder) {
        Remove-Item -LiteralPath $folder -Recurse -Force
    }
}
foreach ($extension in @("pak", "utoc", "ucas")) {
    $old = Join-Path $dist "$($mod.pakName).$extension"
    if (Test-Path $old) {
        Remove-Item $old
    }
}
New-Item -ItemType Directory -Force $read | Out-Null

$sources = @(Get-ChildItem $src -Recurse -File -Filter "*.json")
if ($sources.Count -eq 0) {
    throw "No asset sources (*.json) in $src."
}
$structs = @($mod.structs | Where-Object { $_ })

# 1. JSON -> legacy .uasset/.uexp. The structs come from deps\ when it holds them, else from the game.
$deps = Join-Path $root "deps"
if (Test-Path $deps) {
    Copy-Item (Join-Path $deps "*") $read -Recurse
}
foreach ($struct in $structs) {
    if (Test-Path (Join-Path $read ($struct.Replace("/", "\") + ".uasset"))) {
        continue
    }
    if (-not $hasGame) {
        throw "This mod needs the struct ${struct}: put it into deps\ or install the game (set UE5_GAMES_DIR or use -GameDir)."
    }
    & $retoc @keyArgs to-legacy --version $mod.engine --no-shaders -f $struct $paks $read
    if ($LASTEXITCODE -ne 0) {
        throw "retoc to-legacy failed for the struct $struct with exit code $LASTEXITCODE"
    }
    if (-not (Test-Path (Join-Path $read ($struct.Replace("/", "\") + ".uasset")))) {
        throw "The game has no $struct.uasset."
    }
}
foreach ($json in $sources) {
    $relative = $json.FullName.Substring($src.Length + 1)
    $target = Join-Path $stage ([System.IO.Path]::ChangeExtension($relative, ".uasset"))
    Invoke-UAssetGUIInRead "fromjson" $json.FullName $relative $target @($mod.mappings)
    Write-Host "Asset: $relative"
}

# 2. Legacy -> IoStore container.
$utoc = Join-Path $dist "$($mod.pakName).utoc"
& $retoc to-zen --version $mod.engine $stage $utoc
if ($LASTEXITCODE -ne 0) {
    throw "retoc to-zen failed with exit code $LASTEXITCODE"
}
foreach ($extension in @("pak", "utoc", "ucas")) {
    if (-not (Test-Path (Join-Path $dist "$($mod.pakName).$extension"))) {
        throw "retoc did not write $($mod.pakName).$extension"
    }
}

# 3. The check: container -> legacy -> JSON, compared with the source.
$python = Get-Command python -ErrorAction SilentlyContinue
$skip = ""
if (-not $hasGame) {
    $skip = "the game folder is unknown (set UE5_GAMES_DIR or use -GameDir)"
} elseif (-not $python) {
    $skip = "Python not found"
} else {
    New-Item -ItemType Directory -Force $verifyIn | Out-Null
    Copy-Item (Join-Path $dist "$($mod.pakName).*") $verifyIn
    try {
        foreach ($file in Get-ChildItem $paks -File | Where-Object { $_.Extension -in ".pak", ".utoc", ".ucas" }) {
            New-Item -ItemType HardLink -Path (Join-Path $verifyIn $file.Name) -Target $file.FullName | Out-Null
        }
    } catch {
        $skip = "no hard link to the game files (another drive?): $($_.Exception.Message)"
    }
}
try {
    if ($skip) {
        Write-Host "Check skipped: $skip." -ForegroundColor Yellow
    } else {
        $verifyLegacy = Join-Path $verify "legacy"
        $verifyJson = Join-Path $verify "json"
        foreach ($json in $sources) {
            $relative = $json.FullName.Substring($src.Length + 1)
            # The game's container holds the original asset too; the check below fails if retoc took that one.
            $filter = [System.IO.Path]::ChangeExtension($relative, $null).TrimEnd(".").Replace("\", "/")
            & $retoc @keyArgs to-legacy --version $mod.engine --no-shaders -f $filter $verifyIn $verifyLegacy
            if ($LASTEXITCODE -ne 0) {
                throw "retoc to-legacy (check) failed for $relative with exit code $LASTEXITCODE"
            }
            $legacy = Join-Path $verifyLegacy ([System.IO.Path]::ChangeExtension($relative, ".uasset"))
            if (-not (Test-Path -LiteralPath $legacy)) {
                throw "retoc to-legacy (check) did not write $legacy"
            }
            Invoke-UAssetGUIInRead "tojson" $legacy $relative (Join-Path $verifyJson $relative) @("VER_$($mod.engine)", $mod.mappings)
        }
        & $python.Source -I (Join-Path $root "scripts\check_build.py") $src $verifyJson
        if ($LASTEXITCODE -ne 0) {
            throw "The built mod does not match its source (see above). Nothing was deployed."
        }
    }
} finally {
    # Removing a hard link leaves the game file as it is.
    if (Test-Path -LiteralPath $verifyIn) {
        Remove-Item -LiteralPath $verifyIn -Recurse -Force
    }
}

foreach ($folder in @($stage, $read, $verify)) {
    Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "Built:"
Get-ChildItem (Join-Path $dist "$($mod.pakName).*") | ForEach-Object { Write-Host "  $($_.Name) ($($_.Length) bytes)" }

if ($Deploy) {
    $deployArgs = @{}
    if ($GameDir) {
        $deployArgs.GameDir = $GameDir
    }
    & (Join-Path $root "deploy.ps1") @deployArgs
    exit $LASTEXITCODE
}
