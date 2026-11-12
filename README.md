# zone-pkgbuild

PKGBUILDs for every Zone Linux custom package, plus the build and publish system.

## Directory Layout

| Directory | Contents |
|---|---|
| `local_pkgbuild/` | Zone-specific packages (fonts, XFCE config, wallpapers, sounds, editors, Plymouth themes) |
| `core_pkgbuild/` | Core system packages (release hooks, GRUB theme, Calamares config) |
| `3rdparty_pkgbuild/` | AUR packages checked out at build time via `get-pkgs.sh` |
| `lib/` | Shared build library (`common.sh`, `repo.sh`, `parallel.sh`) |

## Building Packages

All building is done from the `zone-pkgbuild/` root on a Linux build host.

```bash
./build.sh                    # build + publish all groups
./build.sh --all --jobs 4
./build.sh --core             # core packages only
./build.sh --local            # local packages only
./build.sh --3party           # AUR packages only
./build.sh --changed          # only packages whose PKGBUILD or payload changed
./build.sh zone-xfce zone-vim # specific packages
./build.sh --no-publish       # build only
./build.sh --dry-run          # print the plan
```

Successful builds are written to `out/<group>/`, with per-package logs under
`out/logs/<group>/` and a machine-readable `build-manifest.json` at the workspace
root. Publishing is separate and never pushes:

```bash
./publish.sh --all --prune --verify
./publish.sh --core --commit          # commit locally (never pushed)
```

## Adding a New Package

1. Create `<group>_pkgbuild/<pkgname>/PKGBUILD` (no per-package `build.sh` needed).
2. Include `options=(... !debug)`.
3. Run `./build.sh <pkgname>` on a Linux host.
4. Add the package name to `zone-iso/archiso/packages.x86_64` if the ISO needs it.

## 3rd-Party AUR Packages

`3rdparty_pkgbuild/aurpackages` lists the AUR packages. `get-pkgs.sh` clones or
updates them into `3rdparty_pkgbuild/3rdparty/`:

```bash
./3rdparty_pkgbuild/get-pkgs.sh              # update everything
./3rdparty_pkgbuild/get-pkgs.sh paru-bin     # update one package
./3rdparty_pkgbuild/get-pkgs.sh --clean      # discard checkouts and re-clone
```

To add a package, append its name to `aurpackages`.

## Build Library (`lib/`)

| File | Purpose |
|---|---|
| `lib/common.sh` | logging, `build_pkg`, hashing, manifest, `PKGDEST`/`SRCDEST` |
| `lib/repo.sh` | `repo-add`/`repo-remove`, locking, pruning, reindexing, verification |
| `lib/parallel.sh` | dependency-aware parallel runner |

### Incremental Builds (`--changed`)

Each successful build writes a stamp covering the PKGBUILD and the package payload.
`--changed` skips packages whose stamp still matches.

### Inter-Package Dependencies (`deps.conf`)

`deps.conf` declares build-order constraints within a group. Add an entry when a
package needs another from the same group to be built first:

```
zone-meta : zone-base zone-theme
```

## Repository Publishing

`publish.sh` copies only the newest staged package per name, drops `*-debug`
packages, removes orphans that are no longer produced, keeps a configurable number
of versions (`--retention`, default 2), rebuilds the database from the newest files,
and verifies that every on-disk package has a database entry.

## Zone Git Sources

Zone git-sourced PKGBUILDs use `${ZONE_SRC_BASE:-https://github.com/zone-linux}/<pkgname>`
(no `.git` suffix). For offline/local builds:

```bash
ZONE_SRC_BASE=file:///home/matthew/Documents/Zone ./build.sh --local --no-publish
```
