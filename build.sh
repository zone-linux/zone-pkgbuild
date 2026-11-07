#!/usr/bin/env bash
# zone-pkgbuild/build.sh — build Zone packages.
#
# Examples:
#   ./build.sh                          # build + publish every group
#   ./build.sh --local --no-publish     # build local packages only
#   ./build.sh --changed                # only packages whose payload changed
#   ./build.sh --3party --jobs 2        # AUR packages, two at a time
#   ./build.sh zone-xfce calamares      # build named packages
#   ./build.sh --dry-run --all          # print the plan and exit
#
# Run ./build.sh --help for every option.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/parallel.sh
source "$SCRIPT_DIR/lib/parallel.sh"
# shellcheck source=lib/repo.sh
source "$SCRIPT_DIR/lib/repo.sh"

usage() {
    cat <<'EOF'
Usage: ./build.sh [OPTIONS] [TARGET...]

Groups (default: all):
  --all             Build core, local, and 3rdparty packages
  --core            Build core_pkgbuild/ packages
  --local           Build local_pkgbuild/ packages
  --3party          Build 3rdparty_pkgbuild/ AUR packages
  --group NAME      Build one named group (core|local|3party)

Selection:
  --changed         Only packages whose PKGBUILD or payload changed
  --target NAME     Build one package by directory name (repeatable)
  --list            List discovered packages and exit

Build options:
  --jobs N          Parallel package builds (default: nproc)
  --make-jobs N     Compiler jobs per package (default: jobs/2, min 1)
  --sign            Sign packages with GPG
  --sign-key KEY    GPG key id for package signing
  --syncdeps        Let makepkg install missing build dependencies (sudo)
  --nocheck         Skip makepkg check()
  --fail-fast       Stop launching new builds after a failure
  --clean           Remove src/ and pkg/ before building
  --dry-run         Print the build plan without building

Publishing:
  --publish         Publish built packages to the binary repos (default)
  --no-publish      Build only
  --prune           Prune old package versions from the repos
  --retention N     Versions to keep per package when pruning (default: 2)
  --commit          Commit repo changes after publishing (never pushes)
  --verify          Verify repository databases after publishing (default)

Output:
  --logs DIR        Log directory (default: out/logs)
  --manifest FILE   Build manifest path (default: <workspace>/build-manifest.json)
  -h, --help        Show this help

Environment:
  ZONE_SRC_BASE     Override the source base URL/path for Zone git packages
  ZONE_SYNCDEPS=1   Same as --syncdeps
EOF
}

# ── Defaults ─────────────────────────────────────────────────────────────────
BUILD_CORE=0 BUILD_LOCAL=0 BUILD_3PARTY=0
BUILD_CHANGED=0 DRY_RUN=0
DO_PUBLISH=1 DO_PRUNE=0 DO_COMMIT=0 DO_VERIFY=1
DO_CLEAN=0 LIST_ONLY=0
RETENTION="$ZONE_REPO_RETENTION"
MANIFEST="${ZONE_ROOT}/build-manifest.json"
TARGETS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --all)        BUILD_CORE=1; BUILD_LOCAL=1; BUILD_3PARTY=1 ;;
        --core)       BUILD_CORE=1 ;;
        --local)      BUILD_LOCAL=1 ;;
        --3party)     BUILD_3PARTY=1 ;;
        --group)      case "${2:-}" in
                          core)    BUILD_CORE=1 ;;
                          local)   BUILD_LOCAL=1 ;;
                          3party)  BUILD_3PARTY=1 ;;
                          *) die "--group expects core, local, or 3party" ;;
                      esac; shift ;;
        --changed)    BUILD_CHANGED=1 ;;
        --target)     TARGETS+=("${2:?--target needs a name}"); shift ;;
        --list)       LIST_ONLY=1 ;;
        --jobs)       ZONE_JOBS="${2:?--jobs needs a number}"; shift ;;
        --make-jobs)  ZONE_MAKE_JOBS="${2:?--make-jobs needs a number}"; shift ;;
        --sign)       ZONE_SIGN=1 ;;
        --sign-key)   ZONE_SIGN=1; ZONE_SIGN_KEY="${2:?--sign-key needs a key id}"; shift ;;
        --syncdeps)   ZONE_SYNCDEPS=1 ;;
        --nocheck)    ZONE_NOCHECK=1 ;;
        --fail-fast)  ZONE_KEEP_GOING=0 ;;
        --clean)      DO_CLEAN=1 ;;
        --dry-run)    DRY_RUN=1 ;;
        --publish)    DO_PUBLISH=1 ;;
        --no-publish) DO_PUBLISH=0 ;;
        --prune)      DO_PRUNE=1 ;;
        --retention)  RETENTION="${2:?--retention needs a number}"; shift ;;
        --commit)     DO_COMMIT=1 ;;
        --verify)     DO_VERIFY=1 ;;
        --no-verify)  DO_VERIFY=0 ;;
        --logs)       ZONE_LOG_DIR="${2:?--logs needs a path}"; shift ;;
        --manifest)   MANIFEST="${2:?--manifest needs a path}"; shift ;;
        -h|--help)    usage; exit 0 ;;
        -*)           log_error "Unknown option: $1"; usage; exit 1 ;;
        *)            TARGETS+=("$1") ;;
    esac
    shift
done

export ZONE_JOBS ZONE_MAKE_JOBS ZONE_SIGN ZONE_SIGN_KEY ZONE_SYNCDEPS
export ZONE_NOCHECK ZONE_KEEP_GOING ZONE_LOG_DIR ZONE_REPO_RETENTION="$RETENTION"

# Default to every group when neither a group nor a target was supplied.
if [[ ${#TARGETS[@]} -eq 0 && $BUILD_CORE -eq 0 && $BUILD_LOCAL -eq 0 && $BUILD_3PARTY -eq 0 ]]; then
    BUILD_CORE=1; BUILD_LOCAL=1; BUILD_3PARTY=1
fi

ensure_dirs
write_makepkg_conf
load_deps "$SCRIPT_DIR/deps.conf"

# ── Discovery ────────────────────────────────────────────────────────────────
# Print one package directory per line for a group.
discover_group() {
    local group="$1"
    case "$group" in
        core)    find "$SCRIPT_DIR/core_pkgbuild"   -name PKGBUILD -maxdepth 3 -printf '%h\n' 2>/dev/null | sort ;;
        local)   find "$SCRIPT_DIR/local_pkgbuild"  -name PKGBUILD -maxdepth 4 -printf '%h\n' 2>/dev/null | sort ;;
        3party)  find "$SCRIPT_DIR/3rdparty_pkgbuild/3rdparty" -name PKGBUILD -maxdepth 2 -printf '%h\n' 2>/dev/null | sort ;;
    esac
}

# Populate a group's package array, applying --changed.
collect_group() {
    local group="$1" array_name="$2"
    local -n arr="$array_name"
    arr=()
    local dir
    while IFS= read -r dir; do
        [[ -n "$dir" ]] || continue
        if [[ $BUILD_CHANGED -eq 1 ]] && ! needs_rebuild "$dir"; then
            log_dim "unchanged: $(basename "$dir")"
            continue
        fi
        arr+=("$dir")
    done < <(discover_group "$group")
}

# ── Select packages ──────────────────────────────────────────────────────────
CORE_PKGS=() LOCAL_PKGS=() PARTY_PKGS=()

if [[ ${#TARGETS[@]} -gt 0 ]]; then
    declare -A wanted=()
    local_dir="$SCRIPT_DIR"
    for target in "${TARGETS[@]}"; do
        found="$(find "$local_dir" -name PKGBUILD -maxdepth 4 -printf '%h\n' 2>/dev/null \
                 | grep -E "/${target}$" | head -1)"
        [[ -n "$found" ]] || die "package not found: $target"
        wanted["$found"]=1
        case "$found" in
            */core_pkgbuild/*) BUILD_CORE=1 ;;
            */local_pkgbuild/*) BUILD_LOCAL=1 ;;
            */3rdparty/*) BUILD_3PARTY=1 ;;
        esac
    done
    for dir in "${!wanted[@]}"; do
        case "$dir" in
            */core_pkgbuild/*) CORE_PKGS+=("$dir") ;;
            */local_pkgbuild/*) LOCAL_PKGS+=("$dir") ;;
            */3rdparty/*) PARTY_PKGS+=("$dir") ;;
        esac
    done
else
    # AUR checkouts are fetched lazily for --3party.
    if [[ $BUILD_3PARTY -eq 1 ]]; then
        aur_dir="$SCRIPT_DIR/3rdparty_pkgbuild/3rdparty"
        if [[ ! -d "$aur_dir" ]] || ! find "$aur_dir" -maxdepth 2 -name PKGBUILD -print -quit | grep -q .; then
            if [[ $DRY_RUN -eq 1 || $LIST_ONLY -eq 1 ]]; then
                log_dim "would fetch AUR checkouts (dry run)"
            else
                log_info "AUR checkouts missing; fetching..."
                ( cd "$SCRIPT_DIR/3rdparty_pkgbuild" && ./get-pkgs.sh )
            fi
        fi
    fi
    [[ $BUILD_CORE -eq 1 ]]  && collect_group core  CORE_PKGS
    [[ $BUILD_LOCAL -eq 1 ]] && collect_group local LOCAL_PKGS
    [[ $BUILD_3PARTY -eq 1 ]] && collect_group 3party PARTY_PKGS
fi

print_plan() {
    log_step "Build plan"
    log_dim "jobs=$ZONE_JOBS make-jobs=$ZONE_MAKE_JOBS sign=$ZONE_SIGN publish=$DO_PUBLISH prune=$DO_PRUNE"
    local group label dirs
    for group in core local 3party; do
        case "$group" in
            core)   label="core";   dirs=("${CORE_PKGS[@]}") ;;
            local)  label="local";  dirs=("${LOCAL_PKGS[@]}") ;;
            3party) label="3party"; dirs=("${PARTY_PKGS[@]}") ;;
        esac
        [[ ${#dirs[@]} -gt 0 ]] || continue
        log_info "$label (${#dirs[@]}):"
        for dir in "${dirs[@]}"; do
            printf '  %s\n' "$(basename "$dir")" >&2
        done
    done
}

if [[ $LIST_ONLY -eq 1 ]]; then
    print_plan
    exit 0
fi

if [[ $DRY_RUN -eq 1 ]]; then
    print_plan
    exit 0
fi

# ── Build ────────────────────────────────────────────────────────────────────
rm -rf "$ZONE_STATE_DIR/run"
mkdir -p "$ZONE_STATE_DIR/run"
BUILD_RC=0
BUILT_GROUPS=()

if [[ $DO_CLEAN -eq 1 ]]; then
    log_step "Cleaning build trees"
    find "$ZONE_PKGBUILD_DIR" -maxdepth 5 -type d \( -name src -o -name pkg \) \
        -path '*/pkgbuild/*' -prune -exec rm -rf {} + 2>/dev/null || true
fi

run_group() {
    local group="$1"; shift
    [[ $# -gt 0 ]] || return 0
    local state="$ZONE_STATE_DIR/run/$group"
    log_step "$group: $# package(s), $ZONE_JOBS job(s)"
    validate_deps "$@"
    if ! run_builds "$group" "$state" "$@"; then
        BUILD_RC=1
    fi
    print_summary "$state" "$@" || BUILD_RC=1
    BUILT_GROUPS+=("$group")
}

run_group core   "${CORE_PKGS[@]}"
run_group local  "${LOCAL_PKGS[@]}"
run_group 3party "${PARTY_PKGS[@]}"

# ── Manifest ─────────────────────────────────────────────────────────────────
if [[ ${#BUILT_GROUPS[@]} -gt 0 ]]; then
    manifest_write "$MANIFEST" "${BUILT_GROUPS[@]}"
fi

# ── Publish ──────────────────────────────────────────────────────────────────
if [[ $DO_PUBLISH -eq 1 && ${#BUILT_GROUPS[@]} -gt 0 ]]; then
    log_step "Publishing"
    for group in "${BUILT_GROUPS[@]}"; do
        IFS=$'\t' read -r repo_root repo_dir db < <(repo_paths "$group")
        if [[ ! -d "$repo_root" ]]; then
            log_warn "repo not found for group '$group': $repo_root"
            continue
        fi
        mapfile -t files < <(latest_packages "$(group_out_dir "$group")")
        if [[ ${#files[@]} -eq 0 ]]; then
            log_dim "no packages staged for $group"
            continue
        fi
        if ! repo_add_packages "$repo_dir" "$db" "${files[@]}"; then
            BUILD_RC=1; continue
        fi
        [[ $DO_PRUNE -eq 1 ]] && repo_prune "$repo_dir" "$RETENTION"
        [[ $DO_VERIFY -eq 1 ]] && { repo_verify "$repo_dir" "$db" || BUILD_RC=1; }
        [[ $DO_COMMIT -eq 1 ]] && repo_commit "$repo_root" "Update $(basename "$repo_root") ($(date +%Y-%m-%d))"
    done
fi

log_step "Finished"
if [[ $BUILD_RC -ne 0 ]]; then
    log_error "one or more packages failed; see out/logs/"
else
    log_ok "all selected packages built successfully"
fi
exit $BUILD_RC
