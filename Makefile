#
# WoWForeverRace developer Makefile
#
# The targets below assume lua5.1, luarocks, busted, luacheck, git and svn are
# on the PATH. The easiest way to get that toolchain on any OS is the Docker
# image (Dockerfile): every target can be run inside it with `docker compose
# run --rm dev make <target>`, or through the docker-* targets below, or on
# Windows through scripts\dev.ps1.
#
.PHONY: help setup-dev hr lint tests check reflex-tests libs fetch-libs download-bw-release release \
        docker-build docker-lint docker-tests docker-check docker-libs docker-release docker-shell clean

# filter on test FILE names (Lua pattern matched against the file name, e.g. scanner)
INCLUDES ?=
# filter on test NAMES (Lua pattern, e.g. '.*binary.*')
TESTS ?= .*
# extra arguments passed straight to busted
TESTOPTS ?=
# busted run configuration from .busted: default (with coverage) or quick
BUSTED_RUN ?= default

# if UPLOADRELEASE is set to anything (y, n, maybe, w/e) then we do -d during the `release` step
# which will attempt to upload the release
ifneq ($(UPLOADRELEASE),)
RELEASEARGS ?=
else
RELEASEARGS ?= -d
endif

DOCKER_RUN ?= docker compose run --rm dev

help:
	@echo "WoWForeverRace targets:"
	@echo "  lint            run luacheck on src/ and tests/"
	@echo "  tests           run the busted test suite (INCLUDES=<file pattern> TESTS=<name pattern>)"
	@echo "  check           lint + tests"
	@echo "  libs            download external libraries into ./libs (only if missing)"
	@echo "  fetch-libs      force a fresh download of ./libs"
	@echo "  release         build a release zip into ./.release (UPLOADRELEASE=y to upload)"
	@echo "  reflex-tests    re-run lint + tests on every file change (needs reflex)"
	@echo "  setup-dev       install luacheck, busted and luacov with luarocks"
	@echo "  docker-*        same as above but inside the Docker dev image (docker-build first)"
	@echo "  clean           remove build and coverage output"

#
# -- setup-dev --
# install our development dependencies using luarocks (native, non-Docker setup)
#
setup-dev:
	luarocks install luacheck
	luarocks install busted
	luarocks install luacov
	luarocks install cluacov || true

#
# -- hr --
# simply helper to print some spacer
#
hr:
	@echo "======================================================================================"
	@echo "======================================================================================"

#
# -- lint --
# run luacheck on source code and tests (configuration in .luacheckrc)
#
lint:
	luacheck ./src ./tests

#
# -- tests --
# run our testsuite using busted (configuration in .busted)
#
# using TESTS you can provide a filter on test NAMES to run
# using INCLUDES you can provide a filter on test FILES to run
#
tests: libs
	busted --run=$(BUSTED_RUN) $(if $(INCLUDES),--pattern='$(INCLUDES)') --filter='$(TESTS)' $(TESTOPTS)

check: lint tests

#
# -- reflex-tests --
# using reflex watch our source code and rerun the testsuite whenever something is changed
# TESTS and INCLUDES will be passed down if you set them; coverage is skipped for speed
#
reflex-tests:
	reflex -r '.*\.lua' -s -- sh -c 'make hr lint tests BUSTED_RUN=quick'

#
# -- download-bw-release --
# fetch the release.sh script from bigwigs
#
download-bw-release:
	test -f bw-release.sh \
	|| curl -sSL -o bw-release.sh https://raw.githubusercontent.com/BigWigsMods/packager/master/release.sh \
	&& chmod +x bw-release.sh

#
# -- libs --
# checks if ./libs exists, otherwise downloads
#
libs:
	test -d ./libs || $(MAKE) fetch-libs

#
# -- fetch-libs --
# to fetch libs we use bw-release.sh with some flags that disable everything except downloading externals
# and then copy from the .release folder
#
fetch-libs: download-bw-release
	rm -rf ./libs
	./bw-release.sh -d -u -l -z
	cp -rf ./.release/WoWForeverRace/libs ./libs

#
# -- release --
# build release using bw-release.sh
# depending on $(RELEASEARGS) it will or will not upload (see above)
# one zip for every client: the TOC lists them all in a single "## Interface:" line,
# so there is nothing for the packager's -S (split TOC) flag to do.
# NOTE: the packager does not know the WoW Forever interface (16xxx) yet and labels
# it "retail" in release.json; add CurseForge/Wago ids only once that is fixed upstream.
#
release: download-bw-release
	rm -rf ./.release
	./bw-release.sh -u -l $(RELEASEARGS)

#
# -- docker-* --
# run the same targets inside the Docker dev image
#
docker-build:
	docker compose build dev

docker-lint:
	$(DOCKER_RUN) make lint

# MAKEOVERRIDES carries every VAR=value given on the command line
# (INCLUDES, TESTS, TESTOPTS, BUSTED_RUN, WFR_TEST_DEBUG, ...)
docker-tests:
	$(DOCKER_RUN) make tests $(MAKEOVERRIDES)

docker-check:
	$(DOCKER_RUN) make check

docker-libs:
	$(DOCKER_RUN) make fetch-libs

docker-release:
	$(DOCKER_RUN) make release $(MAKEOVERRIDES)

docker-shell:
	$(DOCKER_RUN) bash

clean:
	rm -rf ./.release luacov.stats.out luacov.report.out
