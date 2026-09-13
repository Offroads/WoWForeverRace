# Development image for WoWForeverRace.
#
# Bundles everything needed to lint, test and package the addon so the
# toolchain is identical on Windows, macOS and Linux (and in CI):
#   - Lua 5.1 (the Lua version WoW embeds) + LuaRocks
#   - busted (unit tests), luacheck (linter), luacov (coverage)
#   - git, subversion, curl, zip: required by the BigWigs packager (release.sh)
#
# Usage (see README.md):
#   docker compose run --rm dev make check
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

# The compiler is only needed to build the rocks with C parts (luafilesystem,
# luasystem, lua-term, cluacov) and is purged again in the same layer so the
# image stays small. luarocks and the Lua headers stay: Debian's luarocks
# package owns the rocks tree and takes it along when removed.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        bash ca-certificates curl git subversion zip unzip make \
        lua5.1 liblua5.1-0-dev luarocks \
 && apt-get install -y --no-install-recommends build-essential \
 && luarocks --lua-version 5.1 install luacheck 1.2.0-1 \
 && luarocks --lua-version 5.1 install busted 2.2.0-1 \
 && luarocks --lua-version 5.1 install luacov 0.15.0-1 \
 && luarocks --lua-version 5.1 install cluacov 0.1.4-1 \
 && apt-get purge -y --auto-remove build-essential \
 && rm -rf /var/lib/apt/lists/* /root/.cache

# The repo is bind mounted and owned by a different uid than root inside the
# container; git (used by release.sh to derive the version) refuses to touch
# such a checkout unless it is marked safe.
RUN git config --global --add safe.directory '*'

WORKDIR /addon
CMD ["make", "check"]
