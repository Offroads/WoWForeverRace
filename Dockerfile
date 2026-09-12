# Development image for WoWForeverRace.
#
# Bundles everything needed to lint, test and package the addon so the
# toolchain is identical on Windows, macOS and Linux (and in CI):
#   - Lua 5.1 (the Lua version WoW embeds) + LuaRocks
#   - busted (unit tests), luacheck (linter), luacov (coverage)
#   - git, subversion, curl, zip: required by the BigWigs packager (release.sh)
#
# Usage (see README.md):
#   docker compose run --rm dev make lint tests
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        bash ca-certificates curl git subversion zip unzip make \
        build-essential lua5.1 liblua5.1-0-dev luarocks \
 && rm -rf /var/lib/apt/lists/*

# Lua dev tools (pinned major versions, all Lua 5.1 compatible)
RUN luarocks --lua-version 5.1 install luacheck 1.2.0-1 \
 && luarocks --lua-version 5.1 install busted 2.2.0-1 \
 && luarocks --lua-version 5.1 install luacov 0.15.0-1 \
 && luarocks --lua-version 5.1 install cluacov 0.1.4-1

# The repo is bind mounted and owned by a different uid than root inside the
# container; git (used by release.sh to derive the version) refuses to touch
# such a checkout unless it is marked safe.
RUN git config --global --add safe.directory '*'

WORKDIR /addon
CMD ["make", "lint", "tests"]
