# No Gloom Loss on Death

On death you lose only 10% of your Gloom instead of all of it.

A mod for Mortal Shell II (Unreal Engine 5.6), made with game version `1.12.0`. This README is
for developers. What the mod does, how to install it and its compatibility are in [openmods.md](openmods.md), the mod
page on [openmods](https://openmods.nexus).

## How it works

When the player dies, the gameplay ability Blueprint
`/Game/Sparta/Core/Player/Ability/Death/GA_DeathSpoilsHandler` runs `DropGloom`: `RemoveGloom` takes the Gloom away and
returns the amount, `SaveLostGloomData` saves it as `LostGloomAmount` at the death location, and `SpawnLostGloom` later
puts a pickup there. In the game, `RemoveGloom` takes all of it (`CurrentGloom = GetGloom()`). The mod changes one step
in `RemoveGloom`: `CurrentGloom = Divide_IntInt(GetGloom(), 10)`, so 10% is lost (rounded down) and that 10% drops.
Everything else in the Blueprint is the game's own code of this version.

The change adds the import `/Script/Engine.KismetMathLibrary:Divide_IntInt` and the name `Divide_IntInt` (among the
first `NamesReferencedFromExportDataCount` entries, 229 -> 230); the bytecode of `RemoveGloom` grows from 380 to 395
bytes, so its later jump targets move by 15. The divisor is the `EX_IntConst` in the `Divide_IntInt` call: another
whole number above 0 gives another share without moving anything (`1` = all, like the game).

The Blueprint needs 17 game packages next to it to be read with the mapping file (its parent class `GA_SpartaAbility`,
function libraries, components, the save object, `ID_Gloom`): `structs` in `mod.json`; `build.ps1` reads them from the
installed game. The build check compares the Blueprint code too.

The mod replaces whole assets. A mod that changes the same assets conflicts with this one, and a game update that
changes them needs a new build of the mod.

## Build

Requirements:

- Windows PowerShell 5.1 (part of Windows).
- [UAssetGUI](https://github.com/atenfyr/UAssetGUI/releases) v1.1.0 and [retoc](https://github.com/trumank/retoc/releases)
  v0.1.5. `build.ps1` looks for `_tools\uassetgui\UAssetGUI.exe` and `_tools\retoc\retoc.exe` in the parent folders
  of the project; set `UE5_TOOLS` to a folder that holds both to use another place.
- The game's mapping file, `MortalShell2-1.12.0.usmap`, in `%LOCALAPPDATA%\UAssetGUI\Mappings\`.
- The game's own structs that the assets use (`structs` in `mod.json`; structs made in the editor are not in the
  mapping file): from `deps\` when it holds them, else from the installed game. They are game files and stay out of
  this repository.
- For the check of the build (optional): Python 3, the game installed on the same drive as the project, and, when
  the game's files are encrypted, its AES key in `_tools\gamedata\mortalshell2\game.json` (`{"aesKey": "0x..."}`).

```powershell
powershell -ExecutionPolicy Bypass -File .\build.ps1             # dist\mortalshell2_nogloomloss_P.pak/.utoc/.ucas
powershell -ExecutionPolicy Bypass -File .\build.ps1 -Deploy     # build, then copy the files to Paks\~mods
powershell -ExecutionPolicy Bypass -File .\deploy.ps1 -Wait      # copy the files when the game is closed
```

The build converts every asset source in `src` (UAssetGUI JSON) into a legacy `.uasset`/`.uexp` (UAssetGUI), packs
them into an IoStore container (retoc), and then checks the result: it converts the container back and compares
each asset with its source (`scripts\check_build.py`).

`deploy.ps1` copies the three files to `<game folder>\MortalShell2\Content\Paks\~mods`. The game folder is
`$env:UE5_GAMES_DIR\Mortal Shell II`; `-GameDir` or `-ModsDir` override it. The running game locks the files, so the
script stops (exit code 2) or, with `-Wait`, waits until the game is closed.

Versioning: every change raises the second number in `mod.json` (1.0 -> 1.1): `python scripts\bump_version.py`.

## Project layout

```
src/                               Mod source: the changed assets as UAssetGUI JSON, in the game's folder layout
dist/                              Build output: the .pak/.utoc/.ucas for Paks\~mods (git-ignored)
docs/                              Cover and screenshots for openmods.md
scripts/check_build.py             Compares the built assets with their sources
scripts/bump_version.py            Raises the version in mod.json
build.ps1                          Builds dist\ from src\ and checks the result
deploy.ps1                         Copies the build to the game's Paks\~mods folder
mod.json                           Name, version, game, engine and file names
```

The first commit with an asset holds the original asset, so `git diff` against it shows exactly what the mod
changes.

## License

MIT, see [LICENSE](LICENSE).
