# Arch Linux packaging notes

This directory contains a minimal `PKGBUILD` for packaging **archarden**.

## Quick local build

From a checkout of the repository:

1. Create a tarball in the parent directory (example):
   - `tar --exclude-vcs -czf archarden-$(cat VERSION).tar.gz archarden/`
2. Edit `PKGBUILD`:
   - set `source=("archarden-<version>.tar.gz")`
   - set correct `sha256sums`
3. Build:
   - `makepkg -si`

`archarden` defaults to installing itself under `/usr/lib/archarden` and `/usr/bin/archarden` when packaged.
