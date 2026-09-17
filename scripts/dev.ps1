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
    default Blizzard install location of the WoW Forever beta (_classic_beta_)
    is used.

.PARAMETER Copy
    Copy the addon files instead of creating a junction to this checkout.

.EXAMPLE
    .\scripts\dev.ps1 check

.EXAMPLE
    .\scripts\dev.ps1 tests INCLUDES=scanner

.EXAMPLE
    .\scripts\dev.ps1 deploy -AddOnsPath "D:\Games\World of Warcraft\_classic_beta_\Interface\AddOns"
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("build", "lint", "tests", "check", "libs", "release", "shell", "deploy", "help")]
    [string]$Command = "help",

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$Rest = @(),

    [string]$AddOnsPath,

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
    # the WoW Forever beta is served through the wow_classic_beta product
    $folder = "_classic_beta_"
    foreach ($root in @(${env:ProgramFiles(x86)}, $env:ProgramFiles)) {
        if ($root) {
            $candidate = Join-Path $root "World of Warcraft\$folder\Interface\AddOns"
            if (Test-Path $candidate) {
                return $candidate
            }
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
    # .NET calls below resolve relative paths against the process directory,
    # not PowerShell's current location, so make the path absolute first
    $target = (Resolve-Path $target).ProviderPath
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
    "build"   {
        Push-Location $RepoRoot
        try {
            & docker compose build dev
            if ($LASTEXITCODE -ne 0) { throw "docker compose build failed with exit code $LASTEXITCODE" }
        }
        finally { Pop-Location }
    }
    "lint"    { Invoke-Dev @("make", "lint") }
    "tests"   { Invoke-Dev (@("make", "tests") + $Rest) }
    "check"   { Invoke-Dev @("make", "check") }
    "libs"    { Invoke-Dev @("make", "fetch-libs") }
    "release" { Invoke-Dev @("make", "release") }
    "shell"   { Invoke-Dev @("bash") }
    "deploy"  { Invoke-Deploy }
    default   { Get-Help $PSCommandPath -Detailed }
}
