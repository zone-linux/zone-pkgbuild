#!/usr/bin/env bash
# shellcheck disable=SC2034  # result/selection maps are read by callers
# lib/parallel.sh — dependency-aware parallel build runner.

: "${ZONE_JOBS:=1}"
: "${ZONE_KEEP_GOING:=1}"

declare -gA ZONE_DEPS      # [package]="dep1 dep2 ..."  (from deps.conf)
declare -gA ZONE_SELECTED  # [package]=1 for packages in the current run
declare -gA ZONE_RESULT    # [package]=ok|fail|blocked|skipped

_fmt_ms() {
    local ms="$1"
    if (( ms < 1000 )); then
        printf '%dms' "$ms"
    else
        printf '%d.%ds' "$(( ms / 1000 ))" "$(( (ms % 1000) / 100 ))"
    fi
}

# load_deps <deps.conf>
load_deps() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    local line pkg deps
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line//[[:space:]]/}" ]] && continue
        pkg="${line%%:*}"
        deps="${line#*:}"
        pkg="${pkg//[[:space:]]/}"
        [[ -n "$pkg" ]] && ZONE_DEPS["$pkg"]="$deps"
    done < "$file"
}

# validate_deps <pkgdir>...
# Records the selected set and warns about dependencies that are not part of
# this run (they are assumed to be provided by the host or a previous build).
validate_deps() {
    local dir pkg dep
    ZONE_SELECTED=()
    for dir in "$@"; do
        ZONE_SELECTED["$(basename "$dir")"]=1
    done
    for dir in "$@"; do
        pkg="$(basename "$dir")"
        for dep in ${ZONE_DEPS[$pkg]:-}; do
            if [[ -z "${ZONE_SELECTED[$dep]:-}" ]]; then
                log_warn "deps.conf: '$pkg' depends on '$dep', which is not in this build set"
                log_dim "assuming '$dep' is already available"
            fi
        done
    done
}

# run_builds <group> <state_dir> <pkgdir>...
# Launches build_pkg in parallel (up to ZONE_JOBS slots). Packages whose
# dependencies failed are marked blocked. Independent packages keep building
# even when another package fails.
run_builds() {
    local group="$1" state_dir="$2"; shift 2
    [[ $# -eq 0 ]] && return 0

    mkdir -p "$state_dir/ok" "$state_dir/fail" "$state_dir/blocked"

    local FIFO SEMFD
    FIFO="$(mktemp -u)"
    mkfifo "$FIFO"
    exec {SEMFD}<>"$FIFO"
    rm -f "$FIFO"

    local i
    for (( i=0; i<ZONE_JOBS; i++ )); do printf '%s' x >&"$SEMFD"; done

    local pids=()
    local pkg_dir pkg dep dep_ok blocking

    for pkg_dir; do
        pkg="$(basename "$pkg_dir")"

        dep_ok=1; blocking=""
        for dep in ${ZONE_DEPS[$pkg]:-}; do
            # Dependencies outside this run are assumed satisfied.
            [[ -n "${ZONE_SELECTED[$dep]:-}" ]] || continue
            while [[ ! -f "$state_dir/ok/$dep" && \
                     ! -f "$state_dir/fail/$dep" && \
                     ! -f "$state_dir/blocked/$dep" ]]; do
                sleep 0.05
            done
            if [[ -f "$state_dir/fail/$dep" || -f "$state_dir/blocked/$dep" ]]; then
                dep_ok=0; blocking="$dep"; break
            fi
        done

        if [[ $dep_ok -eq 0 ]]; then
            echo "$blocking" > "$state_dir/blocked/$pkg"
            ZONE_RESULT["$pkg"]="blocked"
            log_warn "Blocked: $pkg (dependency '$blocking' failed)"
            [[ "$ZONE_KEEP_GOING" == "1" ]] || return 1
            continue
        fi

        # Acquire a job slot. This blocks until one is free.
        read -r -n1 -u"$SEMFD"
        local t0
        t0="$(date +%s%N)"

        (
            if build_pkg "$pkg_dir" "$group"; then
                local t1
                t1="$(date +%s%N)"
                echo $(( (t1 - t0) / 1000000 )) > "$state_dir/ok/$pkg"
            else
                touch "$state_dir/fail/$pkg"
            fi
            printf '%s' x >&"$SEMFD"
        ) &
        pids+=($!)
    done

    local pid
    for pid in "${pids[@]}"; do
        wait "$pid" || true
    done
    exec {SEMFD}>&-
}

# print_summary <state_dir> <pkgdir>...
# Returns 1 when any package failed or was blocked.
print_summary() {
    local state_dir="$1"; shift
    local failed=0

    printf '\n%s%-10s  %-34s  %s%s\n' "$_BLD$_YEL" "STATUS" "PACKAGE" "TIME" "$_RST"
    printf '%s' "$_YEL"; printf '%.0s─' {1..60}; printf '%s\n' "$_RST"

    local pkg_dir pkg ms dep
    for pkg_dir; do
        pkg="$(basename "$pkg_dir")"
        if [[ -f "$state_dir/ok/$pkg" ]]; then
            ms="$(cat "$state_dir/ok/$pkg")"
            printf '%s%-10s%s  %-34s  %s\n' \
                "$_GRN" "[DONE]" "$_RST" "$pkg" "$(_fmt_ms "$ms")"
            ZONE_RESULT["$pkg"]="ok"
        elif [[ -f "$state_dir/fail/$pkg" ]]; then
            printf '%s%-10s%s  %-34s  %s\n' \
                "$_RED" "[FAILED]" "$_RST" "$pkg" "— see log"
            ZONE_RESULT["$pkg"]="fail"
            failed=1
        elif [[ -f "$state_dir/blocked/$pkg" ]]; then
            dep="$(cat "$state_dir/blocked/$pkg")"
            printf '%s%-10s%s  %-34s  %s\n' \
                "$_YEL" "[BLOCKED]" "$_RST" "$pkg" "— dependency '$dep' failed"
            ZONE_RESULT["$pkg"]="blocked"
            failed=1
        else
            printf '%-10s  %-34s  %s\n' "[SKIPPED]" "$pkg" "—"
            ZONE_RESULT["$pkg"]="skipped"
        fi
    done
    printf '\n'
    return $failed
}
