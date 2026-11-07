#!/usr/bin/env bash
# 3rdparty_pkgbuild/get-pkgs.sh — fetch/update AUR PKGBUILD checkouts.
#
# Unlike the old script this keeps .git metadata so pkgver() works and so
# repeated runs update the existing clones instead of re-downloading them.
#
# Usage:
#   ./get-pkgs.sh            # clone or update every package in aurpackages
#   ./get-pkgs.sh pkg ...    # fetch specific packages
#   ./get-pkgs.sh --clean    # remove the 3rdparty/ checkout directory first

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIST="${SCRIPT_DIR}/aurpackages"
DEST="${SCRIPT_DIR}/3rdparty"
AUR_BASE="${AUR_BASE:-https://aur.archlinux.org}"

clean=0
if [[ "${1:-}" == "--clean" ]]; then
    clean=1
    shift
fi

[[ -f "$LIST" ]] || { echo "missing package list: $LIST" >&2; exit 1; }
[[ $# -gt 0 ]] && packages=("$@") || mapfile -t packages < <(
    sed -e 's/#.*//' -e 's/[[:space:]]//g' "$LIST" | grep -v '^$' | sort -u
)

[[ $clean -eq 1 ]] && rm -rf "$DEST"
mkdir -p "$DEST"

fetch_one() {
    local pkg="$1" dir="${DEST}/$1"
    if [[ -d "$dir/.git" ]]; then
        printf '  update %s\n' "$pkg"
        git -C "$dir" fetch --quiet --depth 1 origin
        git -C "$dir" reset --quiet --hard FETCH_HEAD
        git -C "$dir" clean -qfdx
    else
        printf '  clone  %s\n' "$pkg"
        rm -rf "$dir"
        git clone --quiet --depth 1 "${AUR_BASE}/${pkg}.git" "$dir"
    fi
}
export -f fetch_one
export DEST AUR_BASE

printf 'Fetching %d AUR package(s) into %s\n' "${#packages[@]}" "$DEST"
printf '%s\n' "${packages[@]}" | xargs -r -P "${JOBS:-$(nproc)}" -I{} bash -c 'fetch_one "$@"' _ {}

printf 'Done. %d checkout(s) in %s\n' "${#packages[@]}" "$DEST"
