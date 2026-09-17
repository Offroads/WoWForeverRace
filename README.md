# WoW Addon: WoWForeverRace

A World of Warcraft addon for WoW Forever that keeps track of the top 50 players on your
faction-realm in the race to max level, overall and per class, and records who
was first to reach every level. Data is gathered with `/who` scans and shared
between addon users over the addon channel.

Built for WoW Forever: the race goes to level 60 and Paladins and Shamans are
tracked on both factions. Classic Era, TBC and MoP Classic clients still work
(the max level and playable classes are detected from the game build).

## Releases
For latest releases that you can just unzip into your `Interface\AddOns` folder,
see the [Releases](https://github.com/Offroads/WoWForeverRace/releases) page on GitHub.

Slash commands: `/wfr` toggles the leaderboard window, `/wfr debug` opens the
debug window, `/wfropts` opens the options.

## Dev setup

Everything needed to lint, test and package the addon lives in a Docker image
(`Dockerfile`), so the only host requirements are Docker and git. This is the
recommended setup on Windows, where Lua, LuaRocks, make and svn are painful to
install.

```bash
# build the dev image (once, and again after changing the Dockerfile)
docker compose build dev

# lint + tests
docker compose run --rm dev

# any Makefile target, e.g.
docker compose run --rm dev make tests INCLUDES=scanner
docker compose run --rm dev make release
docker compose run --rm dev bash
```

On Windows there is a PowerShell wrapper with the same commands plus a `deploy`
step that links the checkout into your WoW `AddOns` folder:

```powershell
.\scripts\dev.ps1 build
.\scripts\dev.ps1 libs        # once: download the Ace3 libraries into .\libs
.\scripts\dev.ps1 check       # lint + tests
.\scripts\dev.ps1 tests INCLUDES=scanner
.\scripts\dev.ps1 deploy      # junction into "World of Warcraft\_classic_beta_\Interface\AddOns" (WoW Forever beta)
.\scripts\dev.ps1 deploy -Flavor classic   # MoP Classic, -Flavor era for Classic Era
.\scripts\dev.ps1 deploy -AddOnsPath "D:\Games\World of Warcraft\_classic_\Interface\AddOns"
```

After `deploy`, edit files in the repo and `/reload` in game. The unpackaged
checkout loads `src/dev.lua`, which adds developer slash commands (`/wfr help`
lists them: forced dings, state dump, database reset, ...) and turns debug
prints on.

On macOS/Linux, `make docker-build`, `make docker-check`, `make docker-tests`,
`make docker-libs`, `make docker-release` and `make docker-shell` wrap the same
container. A native toolchain works too: install Lua 5.1, LuaRocks, git and svn,
then `make setup-dev` and use the plain targets (`make lint tests`).

### Editor

The repo ships a `.luarc.json` for the
[Lua Language Server](https://github.com/LuaLS/lua-language-server) (Lua 5.1,
addon paths, test globals) and recommends the VS Code extensions `sumneko.lua`,
`ketho.wow-api` (WoW API completion and docs) and `editorconfig.editorconfig`.

## Libs
WoW Addon dependency ecosystem is a mess ... we'll just use the release script to fetch the deps,
you can fetch them with:
```bash
# only downloads if no `./libs` exists
make libs

# always downloads fresh copy
make fetch-libs
```
(`libs/` is git-ignored; the tests and the in-game addon both need it.)

## Testing
```bash
# to run test suite and linter:
make lint tests

# if you have `reflex` installed (https://github.com/cespare/reflex) you can use this to retry tests on file change:
make reflex-tests

# you can specify a subset of the test files to run with INCLUDES var (a Lua pattern on the file name), like;
make tests INCLUDES=scanner

# or a name of a test with with TESTS var, like;
make tests TESTS='.*too many max lvl.*'

# skip coverage instrumentation:
make tests BUSTED_RUN=quick
```

Tests run with [busted](https://lunarmodules.github.io/busted/) (configuration
in `.busted`) against the real Ace3 libraries and a small set of WoW API stubs
in `tests/stubs/`. Debug prints are silenced during tests; set
`WFR_TEST_DEBUG=1` to see them.

Test coverage is a bit a lie ... it only shows coverage for the files included in the testsuite run,
but we don't include `main.lua`, `options.lua` and the `gui/*.lua` files...
The report is written to `luacov.report.out`.

The other stuff is well covered and we <3 mocks.

## Releasing
Pushing a `v*` tag runs the `Release` GitHub Actions workflow, which packages
the addon with the [BigWigs packager](https://github.com/BigWigsMods/packager)
and attaches the zip to a GitHub release. The tag name becomes the addon
version. Uploads to CurseForge / Wago / WoWInterface happen only when the
matching API token secret is configured. `make release` builds the same zip
locally into `.release/`.

## Structure
We're trying to avoid using globals as much as possible, so all components are bound to our addon global `WoWForeverRace`
and we generally pass components to other components that depend on them at initialization.
The only `WoWForeverRace.` or `WoWForeverRace:` access should be for `Config` and the `*Print` methods.

For some decoupling we can use the `EventBus` to propagate events as well...

We don't write unittests for `main.lua`, `options.lua` and the `gui/*.lua` files; `scanner.lua` is covered with API stubs,
because they're highly dependent on WoW APIs and external libraries
that broad integration coverage would be expensive to maintain.
For this reason we try to avoid too much logic in these places!

See [AGENTS.md](AGENTS.md) for the architecture overview and conventions.
