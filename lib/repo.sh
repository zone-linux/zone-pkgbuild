#!/usr/bin/env bash
# lib/repo.sh — safe package repository publishing.
#
# All operations are serialised with flock and repo-add --wait-for-lock, so
# concurrent build/publish runs cannot corrupt a database. Old package files
# are pruned with a configurable retention count.

: "${ZONE_REPO_RETENTION:=2}"

# repo_paths <group> -> "<repo_root> <x86_64_dir> <db_file>"
repo_paths() {
    local group="$1"
    local root="${ZONE_ROOT}/${ZONE_GROUPS[$group]:-}"
    [[ -n "${ZONE_GROUPS[$group]:-}" ]] || return 1
    printf '%s\t%s\t%s\n' \
        "$root" \
        "${root}/x86_64" \
        "${root}/x86_64/${ZONE_GROUPS[$group]}.db.tar.gz"
}

repo_lock() {
    local dir="$1"
    mkdir -p "$dir"
    exec {ZONE_REPO_LOCK_FD}>"${dir}/.zone-repo.lock"
    if ! flock -w 300 "$ZONE_REPO_LOCK_FD"; then
        log_error "timed out waiting for repository lock: $dir"
        exec {ZONE_REPO_LOCK_FD}>&-
        return 1
    fi
}

repo_unlock() {
    [[ -n "${ZONE_REPO_LOCK_FD:-}" ]] || return 0
    flock -u "$ZONE_REPO_LOCK_FD" 2>/dev/null || true
    exec {ZONE_REPO_LOCK_FD}>&-
    unset ZONE_REPO_LOCK_FD
}

# latest_packages <dir>
# Prints the newest archive for each package name in <dir>.
latest_packages() {
    local dir="$1"
    [[ -d "$dir" ]] || return 0

    local -A best=()
    local -A bestver=()
    local f name ver
    while IFS= read -r f; do
        name="$(pacman -Qip "$f" 2>/dev/null | awk -F': ' '/^Name[[:space:]]*:/{print $2; exit}')"
        ver="$(pacman -Qip "$f" 2>/dev/null | awk -F': ' '/^Version[[:space:]]*:/{print $2; exit}')"
        [[ -n "$name" && -n "$ver" ]] || continue
        if [[ -z "${best[$name]:-}" ]] || [[ "$(vercmp "$ver" "${bestver[$name]}")" -gt 0 ]]; then
            best["$name"]="$f"
            bestver["$name"]="$ver"
        fi
    done < <(find "$dir" -maxdepth 1 -name '*.pkg.tar.zst' -type f 2>/dev/null | sort)

    local key
    for key in "${!best[@]}"; do
        printf '%s\n' "${best[$key]}"
    done | sort
}

# repo_add_packages <repo_dir> <db_file> <pkg>...
# Copies packages into the repository and adds them in one repo-add call.
repo_add_packages() {
    local repo_dir="$1" db="$2"; shift 2
    [[ $# -gt 0 ]] || return 0
    [[ -d "$repo_dir" ]] || { log_error "repository directory missing: $repo_dir"; return 1; }

    local copied=() pkg target
    repo_lock "$repo_dir" || return 1
    for pkg; do
        [[ -f "$pkg" ]] || { log_warn "missing package: $pkg"; continue; }
        target="${repo_dir}/$(basename "$pkg")"
        [[ "$pkg" == "$target" ]] || cp -f "$pkg" "$target"
        copied+=("$target")
    done

    if [[ ${#copied[@]} -eq 0 ]]; then
        repo_unlock
        return 0
    fi

    local -a args=(--wait-for-lock --quiet --nocolor)
    if [[ "${ZONE_SIGN:-0}" == "1" ]]; then
        args+=(--sign)
        [[ -n "${ZONE_SIGN_KEY:-}" ]] && args+=(--key "$ZONE_SIGN_KEY")
    fi

    log_info "repo-add: ${#copied[@]} package(s) -> $(basename "$db")"
    local rc=0
    repo-add "${args[@]}" "$db" "${copied[@]}" || rc=$?
    repo_unlock

    if [[ $rc -ne 0 ]]; then
        log_error "repo-add failed (exit $rc) for $db"
        return $rc
    fi
    return 0
}

# repo_reindex <repo_dir> <db_file>
# Rebuilds the database from the newest on-disk package for each name. This
# heals stale entries left behind by older publishes and drops packages whose
# files are gone.
repo_reindex() {
    local repo_dir="$1" db="$2"
    [[ -d "$repo_dir" ]] || return 0

    local -a files=()
    mapfile -t files < <(latest_packages "$repo_dir")
    [[ ${#files[@]} -gt 0 ]] || return 0

    local files_db="${db%.tar.gz}.files.tar.gz"

    repo_lock "$repo_dir" || return 1
    rm -f "$db" "$db.sig" "$db.old" \
          "$files_db" "$files_db.sig" "$files_db.old" \
          "${db%.tar.gz}.files" "${db%.tar.gz}.db"

    local -a args=(--wait-for-lock --quiet --nocolor)
    if [[ "${ZONE_SIGN:-0}" == "1" ]]; then
        args+=(--sign)
        [[ -n "${ZONE_SIGN_KEY:-}" ]] && args+=(--key "$ZONE_SIGN_KEY")
    fi

    local rc=0
    repo-add "${args[@]}" "$db" "${files[@]}" || rc=$?
    repo_unlock

    if [[ $rc -ne 0 ]]; then
        log_error "failed to reindex $(basename "$db") (exit $rc)"
        return $rc
    fi
    log_ok "reindexed $(basename "$(dirname "$repo_dir")"): ${#files[@]} newest package(s)"
    return 0
}

# _sort_version_tsv: read "<version>\t<file>" lines, print ascending.
_sort_version_tsv() {
    local -a rows=()
    local line
    while IFS= read -r line; do rows+=("$line"); done
    local i j a b tmp
    for (( i=0; i<${#rows[@]}; i++ )); do
        for (( j=i+1; j<${#rows[@]}; j++ )); do
            a="${rows[i]%%$'\t'*}"
            b="${rows[j]%%$'\t'*}"
            if [[ "$(vercmp "$a" "$b")" -gt 0 ]]; then
                tmp="${rows[i]}"; rows[i]="${rows[j]}"; rows[j]="$tmp"
            fi
        done
    done
    printf '%s\n' "${rows[@]}"
}

# repo_drop_debug <repo_dir>
# Removes any *-debug packages that predate the !debug build option.
repo_drop_debug() {
    local repo_dir="$1"
    local db
    db="${repo_dir}/$(basename "$(dirname "$repo_dir")").db.tar.gz"
    [[ -f "$db" ]] || return 0

    local -A names=()
    local -a files=()
    local f name
    while IFS= read -r f; do
        name="$(pacman -Qip "$f" 2>/dev/null | awk -F': ' '/^Name[[:space:]]*:/{print $2; exit}')"
        [[ "$name" == *-debug ]] || continue
        names["$name"]=1
        files+=("$f")
    done < <(find "$repo_dir" -maxdepth 1 -name '*-debug-*.pkg.tar.zst' -type f | sort)

    [[ ${#names[@]} -gt 0 ]] || return 0

    repo_lock "$repo_dir" || return 1
    # Debug entries may already be absent from the database; removing the files
    # is still correct, so treat repo-remove errors as non-fatal.
    repo-remove --wait-for-lock --quiet --nocolor "$db" "${!names[@]}" 2>/dev/null || true
    repo_unlock

    for f in "${files[@]}"; do
        rm -f "$f" "$f.sig"
    done
    log_ok "removed ${#names[@]} debug package(s) from $(basename "$(dirname "$repo_dir")")"
}

# repo_known_names
# Prints every package name that is still produced by this workspace.
repo_known_names() {
    local file
    while IFS= read -r file; do
        awk -F= '/^pkgname=/ {gsub(/["'\'']/, "", $2); print $2; exit}' "$file"
    done < <(find "$ZONE_PKGBUILD_DIR/core_pkgbuild" "$ZONE_PKGBUILD_DIR/local_pkgbuild" \
                  -name PKGBUILD -type f 2>/dev/null | sort)

    local list="$ZONE_PKGBUILD_DIR/3rdparty_pkgbuild/aurpackages"
    if [[ -f "$list" ]]; then
        sed -e 's/#.*//' -e 's/[[:space:]]//g' "$list" | grep -v '^$'
    fi
}

# repo_drop_orphans <repo_dir>
# Removes archives whose package name is no longer produced anywhere.
repo_drop_orphans() {
    local repo_dir="$1"
    local db
    db="${repo_dir}/$(basename "$(dirname "$repo_dir")").db.tar.gz"
    [[ -f "$db" ]] || return 0

    local -A known=()
    local name
    while IFS= read -r name; do
        [[ -n "$name" ]] && known["$name"]=1
    done < <(repo_known_names)

    local -A orphans=()
    local -a files=()
    local f
    while IFS= read -r f; do
        name="$(pacman -Qip "$f" 2>/dev/null | awk -F': ' '/^Name[[:space:]]*:/{print $2; exit}')"
        [[ -n "$name" ]] || continue
        [[ -n "${known[$name]:-}" ]] && continue
        orphans["$name"]=1
        files+=("$f")
    done < <(find "$repo_dir" -maxdepth 1 -name '*.pkg.tar.zst' -type f | sort)

    [[ ${#orphans[@]} -gt 0 ]] || return 0

    repo_lock "$repo_dir" || return 1
    repo-remove --wait-for-lock --quiet --nocolor "$db" "${!orphans[@]}" 2>/dev/null || true
    repo_unlock

    for f in "${files[@]}"; do
        rm -f "$f" "$f.sig"
        log_dim "dropped orphan $(basename "$f")"
    done
    log_ok "dropped ${#orphans[@]} orphan package(s) from $(basename "$(dirname "$repo_dir")")"
}

# repo_prune <repo_dir> [retention]
# Keeps the newest <retention> versions of each package and deletes the rest.
repo_prune() {
    local repo_dir="$1" retention="${2:-$ZONE_REPO_RETENTION}"
    [[ -d "$repo_dir" ]] || return 0

    repo_drop_debug "$repo_dir" || true
    repo_drop_orphans "$repo_dir" || true

    local -A groups=()
    local f name ver
    while IFS= read -r f; do
        name="$(pacman -Qip "$f" 2>/dev/null | awk -F': ' '/^Name[[:space:]]*:/{print $2; exit}')"
        ver="$(pacman -Qip "$f" 2>/dev/null | awk -F': ' '/^Version[[:space:]]*:/{print $2; exit}')"
        [[ -n "$name" && -n "$ver" ]] || continue
        groups["$name"]+="${ver}"$'\t'"${f}"$'\n'
    done < <(find "$repo_dir" -maxdepth 1 -name '*.pkg.tar.zst' -type f | sort)

    local removed=0 pkg
    for pkg in "${!groups[@]}"; do
        local -a rows=()
        mapfile -t rows < <(printf '%s' "${groups[$pkg]}" | sed '/^$/d' | _sort_version_tsv)

        # Collapse duplicate versions (e.g. a package that changed architecture);
        # keep the newest file on disk.
        local -A keep_by_ver=()
        local -a versions=()
        local row file existing
        for row in "${rows[@]}"; do
            ver="${row%%$'\t'*}"
            file="${row#*$'\t'}"
            [[ -f "$file" ]] || continue
            if [[ -z "${keep_by_ver[$ver]:-}" ]]; then
                keep_by_ver["$ver"]="$file"
                versions+=("$ver")
            else
                existing="${keep_by_ver[$ver]}"
                if [[ "$(stat -c %Y "$file" 2>/dev/null || echo 0)" -gt \
                      "$(stat -c %Y "$existing" 2>/dev/null || echo 0)" ]]; then
                    rm -f "$existing" "$existing.sig"
                    log_dim "pruned duplicate $(basename "$existing")"
                    removed=$(( removed + 1 ))
                    keep_by_ver["$ver"]="$file"
                else
                    rm -f "$file" "$file.sig"
                    log_dim "pruned duplicate $(basename "$file")"
                    removed=$(( removed + 1 ))
                fi
            fi
        done

        local count=${#versions[@]}
        (( count <= retention )) && continue
        local keep=$(( count - retention ))
        local i
        for (( i=0; i<keep; i++ )); do
            file="${keep_by_ver[${versions[i]}]}"
            [[ -f "$file" ]] || continue
            rm -f "$file" "$file.sig"
            log_dim "pruned old $(basename "$file")"
            removed=$(( removed + 1 ))
        done
    done

    if (( removed > 0 )); then
        log_ok "pruned $removed old package file(s) from $(basename "$(dirname "$repo_dir")")"
    else
        log_dim "nothing to prune in $(basename "$(dirname "$repo_dir")")"
    fi
}

# repo_verify <repo_dir> <db_file>
# Structural check: database present, symlinks correct, every package readable.
repo_verify() {
    local repo_dir="$1" db="$2"
    local rc=0

    [[ -f "$db" ]] || { log_error "database missing: $db"; return 1; }

    local base
    base="$(basename "$db" .tar.gz)"
    local link="${repo_dir}/${base}"
    if [[ -L "$link" ]]; then
        local dest
        dest="$(readlink "$link")"
        [[ "$dest" == "$(basename "$db")" ]] || { log_error "bad symlink: $link -> $dest"; rc=1; }
    elif [[ ! -e "$link" ]]; then
        log_error "missing database symlink: $link"
        rc=1
    fi

    local f name
    while IFS= read -r f; do
        if ! name="$(pacman -Qip "$f" 2>/dev/null | awk -F': ' '/^Name[[:space:]]*:/{print $2; exit}')"; then
            log_error "unreadable package: $f"; rc=1; continue
        fi
        [[ -n "$name" ]] || { log_error "no Name in package: $f"; rc=1; }
    done < <(find "$repo_dir" -maxdepth 1 -name '*.pkg.tar.zst' -type f | sort)

    # Every newest package on disk must have a matching database entry.
    local -A db_entries=()
    local entry
    while IFS= read -r entry; do
        db_entries["${entry%/desc}"]=1
    done < <(bsdtar -tf "$db" 2>/dev/null | grep '/desc$' || true)

    local ver key
    while IFS= read -r f; do
        name="$(pacman -Qip "$f" 2>/dev/null | awk -F': ' '/^Name[[:space:]]*:/{print $2; exit}')"
        ver="$(pacman -Qip "$f" 2>/dev/null | awk -F': ' '/^Version[[:space:]]*:/{print $2; exit}')"
        [[ -n "$name" && -n "$ver" ]] || continue
        key="${name}-${ver}"
        if [[ -z "${db_entries[$key]:-}" ]]; then
            log_error "database missing entry for $key"
            rc=1
        fi
    done < <(latest_packages "$repo_dir")

    if [[ $rc -eq 0 ]]; then
        log_ok "verified $(basename "$(dirname "$repo_dir")"): $(find "$repo_dir" -maxdepth 1 -name '*.pkg.tar.zst' | wc -l) package(s)"
    fi
    return $rc
}

# repo_commit <repo_root> <message>
# Stages and commits repository changes. Never pushes.
repo_commit() {
    local root="$1" message="$2"
    [[ -d "$root/.git" ]] || return 0
    [[ -n "$(git -C "$root" status --porcelain)" ]] || { log_dim "no changes in $(basename "$root")"; return 0; }
    git -C "$root" add -A
    git -C "$root" commit -m "$message" --quiet
    log_ok "committed $(basename "$root") (not pushed)"
}
