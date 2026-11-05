# Semver bumps for the watch app and the proxy.
# Default is patch. Override with PART=minor or PART=major.
#
#   make bump-app
#   make bump-proxy PART=minor
#   make bump-both PART=major

PART ?= patch

.PHONY: help bump-app bump-proxy bump-both

help:
	@printf '%s\n' \
		'make bump-app [PART=patch|minor|major]' \
		'make bump-proxy [PART=patch|minor|major]' \
		'make bump-both [PART=patch|minor|major]'

bump-app:
	@python3 tools/bump_version.py app $(PART)

bump-proxy:
	@python3 tools/bump_version.py proxy $(PART)

bump-both: bump-proxy bump-app
