<#
.SYNOPSIS
    WoWForeverRace developer helper for Windows.

.DESCRIPTION
    Wraps the Docker based toolchain (see Dockerfile / docker-compose.yml) so no
    Lua, LuaRocks, make or svn install is needed on the host, and deploys the
    addon into a World of Warcraft AddOns folder for in-game testing.

    Commands:
      build      build (or refresh) the Docker dev image
      lint       run luacheck
      tests      run the busted test suite, extra args are passed to make
                 (e.g. INCLUDES=scanner TESTS='.*binary.*')
      check      lint + tests
      libs       download the external libraries into .\libs (needed once,
                 and before deploy)
      release    build a release zip into .\.release (no upload)
      shell      open an interactive shell in the container
      deploy     put the addon into a WoW AddOns folder (junction by default,
                 so in-game /reload picks up your edits immediately)

.PARAMETER AddOnsPath
    Full path to the Interface\AddOns folder to deploy into. When omitted the
    default Blizzard install location for the chosen -Flavor is used.

.PARAMETER Flavor
    Which WoW client to deploy to when -AddOnsPath is omitted:
    classic (MoP Classic, _classic_), era (Classic Era, _classic_era_).

.PARAMETER Copy
    Copy the addon files instead of creating a junction to this checkout.

.EXAMPLE
    .\scripts\dev.ps1 check

.EXAMPLE
    .\scripts\dev.ps1 tests INCLUDES=scanner

.EXAMPLE
    .\scripts\dev.ps1 deploy -AddOnsPath "D:\Games\World of Warcraft\_classic_\Interface\AddOns"
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("build", "lint", "tests", "check", "libs", "release", "shell", "deploy", "help")]
    [string]$Command = "help",

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$Rest = @(),

    [string]$AddOnsPath,

    [ValidateSet("classic", "era")]
    [string]$Flavor = "classic",

    [switch]$Copy
)

$ErrorActionPreference = "Stop"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$AddonName = "WoWForeverRace"

function Invoke-Dev {
    param([string[]]$Arguments)
    Push-Location $RepoRoot
    try {
        & docker compose run --rm dev @Arguments
        if ($LASTEXITCODE -ne 0) {
            throw "command failed with exit code $LASTEXITCODE"
        }
    }
    finally {
        Pop-Location
    }
}

function Get-DefaultAddOnsPath {
    $folder = if ($Flavor -eq "era") { "_classic_era_" } else { "_classic_" }
    $candidates = @(
        (Join-Path ${env:ProgramFiles(x86)} "World of Warcraft\$folder\Interface\AddOns"),
        (Join-Path $env:ProgramFiles "World of Warcraft\$folder\Interface\AddOns")
    )
    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) {
            return $candidate
        }
    }
    throw "Could not find a '$folder' WoW install, pass -AddOnsPath explicitly."
}

function Invoke-Deploy {
    if (-not (Test-Path (Join-Path $RepoRoot "libs"))) {
        throw "No .\libs folder yet, run '.\scripts\dev.ps1 libs' first (the addon will not load without its libraries)."
    }

    $target = if ($AddOnsPath) { $AddOnsPath } else { Get-DefaultAddOnsPath }
    if (-not (Test-Path $target)) {
        throw "AddOns folder does not exist: $target"
    }
    $destination = Join-Path $target $AddonName

    if (Test-Path $destination) {
        $item = Get-Item $destination -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            # an old junction/symlink: remove the link only, never its target
            [IO.Directory]::Delete($destination)
        }
        else {
            Remove-Item $destination -Recurse -Force
        }
    }

    if ($Copy) {
        New-Item -ItemType Directory -Path $destination | Out-Null
        foreach ($entry in @("$AddonName.toc", "libs.xml", "src", "libs")) {
            Copy-Item (Join-Path $RepoRoot $entry) -Destination $destination -Recurse
        }
        Write-Host "Copied addon to $destination"
    }
    else {
        # a junction needs no admin rights, unlike a symbolic link
        New-Item -ItemType Junction -Path $destination -Target $RepoRoot | Out-Null
        Write-Host "Linked $destination -> $RepoRoot"
        Write-Host "Edit files here and /reload in game to pick up changes."
    }
}

switch ($Command) {
    "build"   { Push-Location $RepoRoot; try { & docker compose build dev } finally { Pop-Location } }
    "lint"    { Invoke-Dev @("make", "lint") }
    "tests"   { Invoke-Dev (@("make", "tests") + $Rest) }
    "check"   { Invoke-Dev @("make", "check") }
    "libs"    { Invoke-Dev @("make", "fetch-libs") }
    "release" { Invoke-Dev @("make", "release") }
    "shell"   { Invoke-Dev @("bash") }
    "deploy"  { Invoke-Deploy }
    default   { Get-Help $PSCommandPath -Detailed }
}
