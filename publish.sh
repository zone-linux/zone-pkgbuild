#!/usr/bin/env bash
# zone-pkgbuild/publish.sh — publish staged packages to the binary repos.
#
# Build output lives in out/<group>/. Publishing copies packages into the
# matching zone-*-repo, updates the pacman database, optionally prunes old
# versions, verifies the result, and (only with --commit) commits locally.
# Nothing is ever pushed.
#
# Examples:
#   ./publish.sh --all --prune
#   ./publish.sh --core --verify
#   ./publish.sh --local --commit
#   ./publish.sh --all --dry-run

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/repo.sh
source "$SCRIPT_DIR/lib/repo.sh"

usage() {
    cat <<'EOF'
Usage: ./publish.sh [OPTIONS]

Groups (default: all):
  --all             Publish core, local, and 3rdparty
  --core            Publish out/core    -> zone-core-repo
  --local           Publish out/local   -> zone-repo
  --3party          Publish out/3party  -> zone-3party-repo
  --group NAME      One of: core, local, 3party

Options:
  --prune           Remove old package versions from the repo
  --retention N     Versions to keep per package (default: 2)
  --verify          Verify the repository database (default)
  --no-verify       Skip verification
  --sign            Sign the repository database with GPG
  --sign-key KEY    GPG key id for database signing
  --commit          Commit changes in the repo checkout (never pushes)
  --manifest FILE   Write a manifest for the published packages
  --dry-run         Show what would be published
  -h, --help        Show this help
EOF
}

DO_CORE=0 DO_LOCAL=0 DO_3PARTY=0
DO_PRUNE=0 DO_VERIFY=1 DO_COMMIT=0 DRY_RUN=0
RETENTION="$ZONE_REPO_RETENTION"
MANIFEST=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --all)        DO_CORE=1; DO_LOCAL=1; DO_3PARTY=1 ;;
        --core)       DO_CORE=1 ;;
        --local)      DO_LOCAL=1 ;;
        --3party)     DO_3PARTY=1 ;;
        --group)      case "${2:-}" in
                          core)   DO_CORE=1 ;;
                          local)  DO_LOCAL=1 ;;
                          3party) DO_3PARTY=1 ;;
                          *) die "--group expects core, local, or 3party" ;;
                      esac; shift ;;
        --prune)      DO_PRUNE=1 ;;
        --retention)  RETENTION="${2:?--retention needs a number}"; shift ;;
        --verify)     DO_VERIFY=1 ;;
        --no-verify)  DO_VERIFY=0 ;;
        --sign)       ZONE_SIGN=1 ;;
        --sign-key)   ZONE_SIGN=1; ZONE_SIGN_KEY="${2:?--sign-key needs a key id}"; shift ;;
        --commit)     DO_COMMIT=1 ;;
        --manifest)   MANIFEST="${2:?--manifest needs a path}"; shift ;;
        --dry-run)    DRY_RUN=1 ;;
        -h|--help)    usage; exit 0 ;;
        *)            die "unknown option: $1 (see --help)" ;;
    esac
    shift
done

[[ $DO_CORE -eq 0 && $DO_LOCAL -eq 0 && $DO_3PARTY -eq 0 ]] && { DO_CORE=1; DO_LOCAL=1; DO_3PARTY=1; }

export ZONE_SIGN ZONE_SIGN_KEY ZONE_REPO_RETENTION="$RETENTION"

PUBLISH_GROUPS=()
[[ $DO_CORE -eq 1 ]] && PUBLISH_GROUPS+=(core)
[[ $DO_LOCAL -eq 1 ]] && PUBLISH_GROUPS+=(local)
[[ $DO_3PARTY -eq 1 ]] && PUBLISH_GROUPS+=(3party)

RC=0
PUBLISHED_GROUPS=()

for group in "${PUBLISH_GROUPS[@]}"; do
    IFS=$'\t' read -r repo_root repo_dir db < <(repo_paths "$group")
    [[ -n "$repo_root" ]] || { log_warn "unknown group: $group"; continue; }

    mapfile -t files < <(latest_packages "$(group_out_dir "$group")")

    log_step "$group -> ${repo_root#"$ZONE_ROOT"/}"
    if [[ ${#files[@]} -eq 0 ]]; then
        log_dim "no staged packages in out/$group"
    else
        for f in "${files[@]}"; do log_dim "$(basename "$f")"; done
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        [[ $DO_PRUNE -eq 1 ]] && log_dim "would prune (retention=$RETENTION)"
        [[ $DO_COMMIT -eq 1 ]] && log_dim "would commit ${repo_root#"$ZONE_ROOT"/}"
        continue
    fi

    if [[ ! -d "$repo_root" ]]; then
        log_warn "repository checkout missing: $repo_root"
        RC=1; continue
    fi

    if [[ ${#files[@]} -gt 0 ]]; then
        repo_add_packages "$repo_dir" "$db" "${files[@]}" || { RC=1; continue; }
        PUBLISHED_GROUPS+=("$group")
    fi

    repo_drop_debug "$repo_dir" || RC=1
    if [[ $DO_PRUNE -eq 1 ]]; then
        repo_prune "$repo_dir" "$RETENTION" || RC=1
        repo_reindex "$repo_dir" "$db" || RC=1
    fi
    [[ $DO_VERIFY -eq 1 ]] && { repo_verify "$repo_dir" "$db" || RC=1; }
    [[ $DO_COMMIT -eq 1 ]] && repo_commit "$repo_root" "Update $(basename "$repo_root") ($(date +%Y-%m-%d))"
done

if [[ -n "$MANIFEST" && ${#PUBLISHED_GROUPS[@]} -gt 0 && $DRY_RUN -eq 0 ]]; then
    manifest_write "$MANIFEST" "${PUBLISHED_GROUPS[@]}"
fi

log_step "Finished"
[[ $RC -eq 0 ]] && log_ok "publish complete" || log_error "publish completed with errors"
exit $RC
