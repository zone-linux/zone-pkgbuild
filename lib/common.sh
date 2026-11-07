#!/usr/bin/env bash
# lib/common.sh — shared helpers for the Zone package build system.
#
# Responsibilities:
#   * logging
#   * paths and defaults
#   * generated makepkg configuration (no debug packages, shared caches)
#   * payload hashing / incremental rebuild stamps
#   * build_pkg(): run makepkg with per-package logs
#   * signing helpers (optional; unsigned repos are supported)
#   * build-manifest generation

# Resolve the repository this library lives in.
ZONE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZONE_PKGBUILD_DIR="$(cd "${ZONE_LIB_DIR}/.." && pwd)"
ZONE_ROOT="$(cd "${ZONE_PKGBUILD_DIR}/.." && pwd)"

# Defaults (every value can be overridden from the environment).
: "${ZONE_OUT_BASE:=${ZONE_PKGBUILD_DIR}/out}"
: "${ZONE_LOG_DIR:=${ZONE_OUT_BASE}/logs}"
: "${ZONE_STATE_DIR:=${ZONE_OUT_BASE}/.state}"
: "${ZONE_SRC_CACHE:=${ZONE_OUT_BASE}/src-cache}"
: "${ZONE_JOBS:=$(nproc)}"
: "${ZONE_MAKE_JOBS:=$(( ZONE_JOBS > 1 ? (ZONE_JOBS / 2 > 1 ? ZONE_JOBS / 2 : 1) : ZONE_JOBS ))}"
: "${ZONE_SYNCDEPS:=0}"
: "${ZONE_NOCHECK:=0}"
: "${ZONE_KEEP_GOING:=1}"
: "${ZONE_SIGN:=0}"
: "${ZONE_SIGN_KEY:=}"

# Group -> repository directory (relative to the workspace root).
# shellcheck disable=SC2034  # consumed by lib/repo.sh after sourcing
declare -gA ZONE_GROUPS=(
    [core]="zone-core-repo"
    [local]="zone-repo"
    [3party]="zone-3party-repo"
)

# ── Logging ──────────────────────────────────────────────────────────────────
if [[ -t 2 ]]; then
    _CYN=$'\e[36m' _YEL=$'\e[33m' _RED=$'\e[31m' _GRN=$'\e[32m'
    _DIM=$'\e[2m' _BLD=$'\e[1m' _RST=$'\e[0m'
else
    _CYN='' _YEL='' _RED='' _GRN='' _DIM='' _BLD='' _RST=''
fi

log_info()  { printf '%s[%s]%s %s\n' "$_CYN" "$(date +%H:%M:%S)" "$_RST" "$*" >&2; }
log_ok()    { printf '%s[%s] OK %s%s\n' "$_GRN" "$(date +%H:%M:%S)" "$*" "$_RST" >&2; }
log_warn()  { printf '%s[%s] WARN %s%s\n' "$_YEL" "$(date +%H:%M:%S)" "$*" "$_RST" >&2; }
log_error() { printf '%s[%s] ERROR %s%s\n' "$_RED" "$(date +%H:%M:%S)" "$*" "$_RST" >&2; }
log_step()  { printf '\n%s%s==> %s%s\n' "$_BLD" "$_CYN" "$*" "$_RST" >&2; }
log_dim()   { printf '%s    %s%s\n' "$_DIM" "$*" "$_RST" >&2; }

die() { log_error "$*"; exit 1; }

ensure_dirs() {
    mkdir -p "$ZONE_OUT_BASE" "$ZONE_LOG_DIR" "$ZONE_STATE_DIR/stamps" \
             "$ZONE_SRC_CACHE" "$ZONE_OUT_BASE/.stage"
}

# ── Paths ────────────────────────────────────────────────────────────────────
group_out_dir() { printf '%s/%s' "$ZONE_OUT_BASE" "$1"; }
group_log_dir() { printf '%s/%s' "$ZONE_LOG_DIR" "$1"; }
group_stage_dir() { printf '%s/.stage/%s' "$ZONE_OUT_BASE" "$1"; }

pkg_name() { basename "$1"; }

pkg_stamp() {
    local dir="$1"
    local rel="${dir#${ZONE_PKGBUILD_DIR}/}"
    printf '%s/stamps/%s.sha256' "$ZONE_STATE_DIR" "${rel//\//_}"
}

# ── makepkg configuration ────────────────────────────────────────────────────
ZONE_MAKEPKG_CONF="${ZONE_OUT_BASE}/makepkg.conf"

write_makepkg_conf() {
    [[ -f /etc/makepkg.conf ]] || die "/etc/makepkg.conf not found"
    {
        cat /etc/makepkg.conf
        cat <<EOF

# ── Zone overrides ───────────────────────────────────────────────────────────
SRCDEST="${ZONE_SRC_CACHE}"
OPTIONS+=(!debug)
MAKEFLAGS="-j${ZONE_MAKE_JOBS}"
EOF
    } > "$ZONE_MAKEPKG_CONF"
}

# ── Hashing / incremental rebuilds ───────────────────────────────────────────
# Hash the PKGBUILD plus every payload file in the package directory. Build
# artefacts (src/, pkg/, *.pkg.tar.*, logs, stamps) are excluded so that a
# completed build does not invalidate its own stamp.
pkg_payload_hash() {
    local dir="$1"
    (
        cd "$dir" || return 1
        {
            printf 'PKGBUILD\0'
            sha256sum PKGBUILD | awk '{print $1}'
            find . -type f \
                ! -path './src/*' ! -path './pkg/*' ! -path './.git/*' \
                ! -name '*.pkg.tar.*' ! -name '*.pkg.tar.*.sig' \
                ! -name '*.log' ! -name '.build-stamp' \
                -print0 |
                sort -z |
                xargs -0 -r sha256sum
        } | sha256sum | awk '{print $1}'
    )
}

stamp_success() {
    local dir="$1" stamp
    stamp="$(pkg_stamp "$dir")"
    mkdir -p "$(dirname "$stamp")"
    pkg_payload_hash "$dir" > "$stamp"
}

needs_rebuild() {
    local dir="$1" stamp
    stamp="$(pkg_stamp "$dir")"
    [[ -f "$stamp" ]] || return 0
    [[ "$(cat "$stamp")" != "$(pkg_payload_hash "$dir")" ]]
}

# ── Signing (optional) ───────────────────────────────────────────────────────
sign_pkg() {
    [[ "${ZONE_SIGN:-0}" == "1" ]] || return 0
    local file="$1"
    local args=(--batch --yes --detach-sign --no-armor)
    [[ -n "${ZONE_SIGN_KEY:-}" ]] && args+=(--local-user "$ZONE_SIGN_KEY")

    if ! gpg "${args[@]}" "$file" 2>/dev/null; then
        log_warn "GPG signing skipped for $(basename "$file") (no usable key)"
        return 1
    fi
}

# ── Build ────────────────────────────────────────────────────────────────────
# build_pkg <pkgdir> <group>
# Builds one package into out/<group>/, writing out/logs/<group>/<pkg>.log.
# Returns non-zero on failure; never exits the caller.
build_pkg() {
    local dir="$1" group="$2"
    local pkg stage log rc
    pkg="$(pkg_name "$dir")"
    stage="$(group_stage_dir "$group")/${pkg}"
    log="$(group_log_dir "$group")/${pkg}.log"

    mkdir -p "$stage" "$(dirname "$log")"
    rm -rf "${stage:?}"/*
    : > "$log"

    local -a args=(
        --force --clean --noconfirm --skippgpcheck
        --config "$ZONE_MAKEPKG_CONF"
        --log
    )
    [[ "$ZONE_SYNCDEPS" == "1" ]] && args+=(--syncdeps)
    [[ "$ZONE_NOCHECK" == "1" ]] && args+=(--nocheck)

    log_info "Building $pkg (log: ${log#"$ZONE_PKGBUILD_DIR"/})"

    set -o pipefail
    (
        cd "$dir" || exit 1
        PKGDEST="$stage" makepkg "${args[@]}"
    ) 2>&1 | tee -a "$log"
    rc=${PIPESTATUS[0]}

    if [[ $rc -ne 0 ]]; then
        log_error "$pkg: makepkg failed (exit $rc)"
        tail -n 25 "$log" >&2 || true
        return 1
    fi

    local built=()
    while IFS= read -r f; do built+=("$f"); done < <(
        find "$stage" -maxdepth 1 -name '*.pkg.tar.zst' -type f 2>/dev/null | sort
    )

    if [[ ${#built[@]} -eq 0 ]]; then
        log_error "$pkg: makepkg succeeded but produced no package"
        return 1
    fi

    local out
    out="$(group_out_dir "$group")"
    mkdir -p "$out"
    local f
    for f in "${built[@]}"; do
        sign_pkg "$f" || true
        mv -f "$f" "$out/"
        [[ -f "$f.sig" ]] && mv -f "$f.sig" "$out/"
    done

    stamp_success "$dir"
    rm -rf "$stage"
    log_ok "$pkg"
    return 0
}

# ── Manifest ─────────────────────────────────────────────────────────────────
# manifest_write <output.json> <group>...
# Describes every package currently staged in out/<group>/ plus repository
# commit hashes, so a rebuild can be traced back to its source state.
manifest_write() {
    local out="$1"; shift
    local groups=("$@")
    local tsv
    tsv="$(mktemp)"

    local group outdir f
    for group in "${groups[@]}"; do
        outdir="$(group_out_dir "$group")"
        [[ -d "$outdir" ]] || continue
        while IFS= read -r f; do
            [[ -n "$f" ]] || continue
            local name ver builddate packager
            name="$(pacman -Qip "$f" 2>/dev/null | awk -F': ' '/^Name[[:space:]]*:/{print $2; exit}')"
            ver="$(pacman -Qip "$f" 2>/dev/null | awk -F': ' '/^Version[[:space:]]*:/{print $2; exit}')"
            builddate="$(pacman -Qip "$f" 2>/dev/null | awk -F': ' '/^Build Date[[:space:]]*:/{print $2; exit}')"
            packager="$(pacman -Qip "$f" 2>/dev/null | awk -F': ' '/^Packager[[:space:]]*:/{print $2; exit}')"
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$group" "$name" "$ver" "$builddate" "$packager" "$(basename "$f")" >> "$tsv"
        done < <(find "$outdir" -maxdepth 1 -name '*.pkg.tar.zst' -type f | sort)
    done

    ZONE_MANIFEST_TSV="$tsv" ZONE_MANIFEST_OUT="$out" ZONE_ROOT="$ZONE_ROOT" \
    ZONE_OUT_BASE="$ZONE_OUT_BASE" python3 - <<'PY'
import json, os, pathlib, subprocess, datetime

tsv = os.environ["ZONE_MANIFEST_TSV"]
out = os.environ["ZONE_MANIFEST_OUT"]
root = pathlib.Path(os.environ["ZONE_ROOT"])
outbase = pathlib.Path(os.environ["ZONE_OUT_BASE"])

packages = []
with open(tsv, encoding="utf-8") as fh:
    for line in fh:
        group, name, ver, builddate, packager, filename = line.rstrip("\n").split("\t")
        path = outbase / group / filename
        packages.append({
            "group": group,
            "name": name,
            "version": ver,
            "build_date": builddate,
            "packager": packager,
            "file": filename,
            "size": path.stat().st_size if path.exists() else None,
        })

repos = {}
for repo in ("zone-iso", "zone-pkgbuild", "zone-xfce", "zone-wallpapers",
             "zone-calamares-config", "zone-repo", "zone-core-repo",
             "zone-3party-repo"):
    d = root / repo
    if (d / ".git").exists():
        try:
            repos[repo] = subprocess.check_output(
                ["git", "-C", str(d), "rev-parse", "HEAD"], text=True).strip()
        except subprocess.CalledProcessError:
            repos[repo] = None

try:
    archiso = subprocess.check_output(
        ["pacman", "-Q", "archiso"], text=True).strip()
except subprocess.CalledProcessError:
    archiso = None

doc = {
    "generated": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "host": os.uname().nodename,
    "archiso": archiso,
    "repositories": repos,
    "packages": packages,
}

pathlib.Path(out).parent.mkdir(parents=True, exist_ok=True)
with open(out, "w", encoding="utf-8") as fh:
    json.dump(doc, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY

    rm -f "$tsv"
    log_ok "manifest written: $out"
}
