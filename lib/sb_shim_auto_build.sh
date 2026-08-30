#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 m0nokey
# Resolve and build the exact Proxmox shim source matching shim-unsigned.
# This helper never invokes host APT and never writes the ESP. Compilation is
# delegated to sb-shim-source-chroot, which uses the shared cached Trixie root.
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

# ==============================================================================
# Configuration
# ==============================================================================
STATE_ROOT="${STATE_ROOT:-/var/lib/sb-guard}"
KEY_DIR="${KEY_DIR:-$STATE_ROOT/keys}"
DB_CRT="${DB_CRT:-$KEY_DIR/db.crt}"
DB_KEY="${DB_KEY:-$KEY_DIR/db.key}"
CUSTOM_DIR="${CUSTOM_DIR:-$STATE_ROOT/custom-shim}"
CUSTOM_ARTIFACT="$CUSTOM_DIR/shimx64.efi"
CUSTOM_STATE="$CUSTOM_DIR/shim.state"
UNSIGNED_SHIM="${UNSIGNED_SHIM:-/usr/lib/shim/shimx64.efi}"
CUSTOM_BUILDER="${CUSTOM_BUILDER:-/usr/local/sbin/sb-shim-build-custom}"
SOURCE_REPO="${SOURCE_REPO:-https://git.proxmox.com/git/efi-boot-shim.git}"
SOURCE_CACHE_ROOT="${SOURCE_CACHE_ROOT:-$STATE_ROOT/source-cache}"
BUILD_ROOT_HELPER="${BUILD_ROOT_HELPER:-/usr/local/sbin/sb-build-root}"
WORK_PARENT="${WORK_PARENT:-/var/tmp}"
LOCK_FILE="${LOCK_FILE:-/run/sb-shim-build.lock}"
GLOBAL_LOCK_FILE="${GLOBAL_LOCK_FILE:-/run/sb-guard.lock}"
FORCE_BUILD=0

# ==============================================================================
# Helpers
# ==============================================================================
log() { printf '[sb-shim-auto-build] %s\n' "$*" >&2; }
die() { log "FAIL: $*"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

cleanup_resolver_tmp() {
    local rc=$?
    set +e
    # Resolver scratch is never a verified source cache.  Remove only the
    # fixed, name-prefixed objects below the protected state root, including
    # objects left behind when curl/git aborts before a RETURN trap runs.
    if [[ "$SOURCE_CACHE_ROOT" == /var/lib/sb-guard/source-cache ]]; then
        find "$SOURCE_CACHE_ROOT" -maxdepth 1 -type f -name '.shim-history.*' -delete 2>/dev/null || true
        find "$SOURCE_CACHE_ROOT" -maxdepth 1 -type d -name '.shim-source.*' \
            -exec rm -rf --one-file-system -- {} + 2>/dev/null || true
    fi
    exit "$rc"
}
trap cleanup_resolver_tmp EXIT

validate_paths() {
    [[ "$STATE_ROOT" == /var/lib/sb-guard ]] || die "STATE_ROOT must remain /var/lib/sb-guard"
    [[ "$SOURCE_CACHE_ROOT" == "$STATE_ROOT/source-cache" ]] ||
        die "SOURCE_CACHE_ROOT must remain /var/lib/sb-guard/source-cache"
}
state_get() {
    local k="$1"
    [[ -s "$CUSTOM_STATE" ]] || return 0
    sed -n "s/^${k}=//p" "$CUSTOM_STATE" | sed '/^$/d;1q'
}
package_version() { dpkg-query -W -f='${Version}\n' shim-unsigned 2>/dev/null | sed '/^$/d;1q'; }
package_sha() { sha256sum "$UNSIGNED_SHIM" | awk '{print $1}'; }
cert_fp() { openssl x509 -in "$DB_CRT" -noout -fingerprint -sha256 | sed 's/^sha256 Fingerprint=//'; }

artifact_vendor_ok() (
    local tmp db_der section dumped der_size strings_output
    tmp="$(mktemp -d -p "$STATE_ROOT" .shim-auto-check.XXXXXX 2>/dev/null)" || return 1
    trap 'rm -rf -- "$tmp"' EXIT
    db_der="$tmp/db.crt.der"; section="$tmp/vendor.section"; dumped="$tmp/image.dump.efi"
    openssl x509 -in "$DB_CRT" -outform DER -out "$db_der" >/dev/null 2>&1 || return 1
    objcopy --dump-section .vendor_cert="$section" "$CUSTOM_ARTIFACT" "$dumped" >/dev/null 2>&1 || return 1
    der_size="$(stat -c '%s' "$db_der" 2>/dev/null || true)"
    [[ "$der_size" =~ ^[1-9][0-9]*$ ]] || return 1
    dd if="$section" of="$tmp/vendor.der" bs=1 skip=16 count="$der_size" status=none 2>/dev/null || return 1
    cmp -s "$db_der" "$tmp/vendor.der" || return 1
    strings_output="$(strings "$CUSTOM_ARTIFACT" 2>/dev/null || true)"
    grep -Fq "sb-guard db" <<<"$strings_output" || return 1
    ! grep -Fq "Proxmox Server Solutions GmbH" <<<"$strings_output" || return 1
    ! grep -Fq "office@proxmox.com" <<<"$strings_output" || return 1
)

custom_ready() {
    local ver sha fp actual
    [[ -s "$CUSTOM_ARTIFACT" && -s "$CUSTOM_STATE" && -s "$DB_CRT" && -s "$DB_KEY" ]] || return 1
    ver="$(package_version)"; sha="$(package_sha)"; fp="$(cert_fp)"
    [[ "$(state_get mode)" == custom-built ]] || return 1
    [[ "$(state_get source_package_version)" == "$ver" ]] || return 1
    [[ "$(state_get source_package_sha256)" == "$sha" ]] || return 1
    [[ "$(state_get source_tree_version)" == "$ver" ]] || return 1
    [[ "$(state_get source_git_commit)" =~ ^[[:xdigit:]]{40}$ ]] || return 1
    [[ "$(state_get vendor_fingerprint)" == "$fp" ]] || return 1
    actual="$(sha256sum "$CUSTOM_ARTIFACT" | awk '{print $1}')"
    [[ "$(state_get signed_sha256)" == "$actual" ]] || return 1
    sbverify --cert "$DB_CRT" "$CUSTOM_ARTIFACT" >/dev/null 2>&1 || return 1
    [[ "$(sbverify --list "$CUSTOM_ARTIFACT" 2>/dev/null | grep -cE '^signature[[:space:]]+[0-9]+$' || true)" -eq 1 ]] || return 1
    artifact_vendor_ok || return 1
}

source_version() { dpkg-parsechangelog -S Version 2>/dev/null | sed '/^$/d;1q' || true; }
source_commit() { git -C "$1" rev-parse HEAD 2>/dev/null || true; }
source_remote() { git -C "$1" config --get remote.origin.url 2>/dev/null || true; }

validate_source() {
    local source="$1" expected="$2" commit remote version
    [[ -d "$source" && -f "$source/debian/rules" && -f "$source/debian/control" ]] ||
        die "Shim source is incomplete: $source"
    commit="$(source_commit "$source")"
    [[ "$commit" =~ ^[[:xdigit:]]{40}$ ]] || die "Shim source has no exact commit: $source"
    remote="$(source_remote "$source")"
    [[ "$remote" == "$SOURCE_REPO" || "$remote" == "$SOURCE_REPO.git" ]] ||
        die "Shim source remote is not the official Proxmox repository: $remote"
    version="$(cd "$source" && source_version)"
    [[ "$version" == "$expected" ]] ||
        die "Shim source/package version mismatch (source=$version installed=$expected)"
    git -C "$source" fsck --strict --no-progress >&2
}

resolve_source() {
    local expected="$1" upstream ref branch history line commit advertised
    local cache_dir work tree remote version cache_tmp
    upstream="${expected%%-*}"
    upstream="${upstream##*:}"
    ref="proxmox/trixie-${upstream}"
    branch="refs/heads/$ref"
    install -d -m 0700 -o root -g root "$SOURCE_CACHE_ROOT/shim"
    history="$(mktemp -p "$SOURCE_CACHE_ROOT" .shim-history.XXXXXX)"
    trap 'rm -f -- "${history:-}"' RETURN
    log "Resolving Proxmox shim commit for installed version $expected"
    curl -4 -fsSL --retry 5 --connect-timeout 15 --max-time 90 \
        -A 'sb-guard-source-resolver/1' \
        "https://git.proxmox.com/?p=efi-boot-shim.git;a=history;f=debian/changelog;hb=${ref}" \
        -o "$history"
    # Ignore the GitWeb page title: its h= value is the branch name.  The
    # history-row subject link carries the exact 40-hex commit we need.
    line="$(grep -F 'class="list subject"' "$history" | grep -m1 -F "bump version to $expected" || true)"
    commit="$(sed -n 's/.*a=commit;h=\([[:xdigit:]]\{40\}\).*/\1/p' <<<"$line" | sed '/^$/d;1q')"
    [[ "$commit" =~ ^[[:xdigit:]]{40}$ ]] ||
        die "No official Proxmox shim commit maps to installed version: $expected"
    advertised="$(git ls-remote "$SOURCE_REPO" "$branch" 2>/dev/null | awk 'NF >= 2 { print $1; exit }')"
    [[ "$advertised" =~ ^[[:xdigit:]]{40}$ ]] ||
        die "Cannot resolve official Proxmox shim ref: $ref"

    cache_dir="$SOURCE_CACHE_ROOT/shim/${expected}-${commit}"
    if [[ -d "$cache_dir" ]]; then
        validate_source "$cache_dir" "$expected"
        [[ "$(source_commit "$cache_dir")" == "$commit" ]] || die "Cached shim commit mismatch"
        rm -f -- "$history"
        trap - RETURN
        printf '%s\n' "$cache_dir"
        return 0
    fi

    work="$(mktemp -d -p "$SOURCE_CACHE_ROOT" .shim-source.XXXXXX)"
    trap 'rm -rf --one-file-system "${work:-}"; rm -f -- "${history:-}"' RETURN
    tree="$work/tree"
    log "Fetching only exact Proxmox shim commit $commit"
    git init -q "$tree"
    git -C "$tree" remote add origin "$SOURCE_REPO"
    git -C "$tree" -c http.version=HTTP/1.1 fetch --depth=1 origin "$commit" >&2
    git -C "$tree" checkout --detach --quiet FETCH_HEAD
    validate_source "$tree" "$expected"
    [[ "$(source_commit "$tree")" == "$commit" ]] || die "Fetched shim commit mismatch"
    [[ "$advertised" =~ ^[[:xdigit:]]{40}$ ]] || die "Invalid advertised shim ref head"
    cache_tmp="$SOURCE_CACHE_ROOT/shim/.${expected}-${commit}.new"
    rm -rf --one-file-system "$cache_tmp"
    mv -- "$tree" "$cache_tmp"
    mv -- "$cache_tmp" "$cache_dir"
    rm -rf --one-file-system "$work"
    rm -f -- "$history"
    trap - RETURN
    printf '%s\n' "$cache_dir"
}

prune_source_cache() {
    local -a dirs=() i
    [[ "$SOURCE_CACHE_ROOT" == /var/lib/sb-guard/source-cache ]] || return 0
    mapfile -t dirs < <(
        find "$SOURCE_CACHE_ROOT/shim" -mindepth 1 -maxdepth 1 -type d \
            -name '*-*' -printf '%T@ %p\n' 2>/dev/null | sort -nr | sed 's/^[^ ]* //'
    )
    for ((i=2; i<${#dirs[@]}; i++)); do
        rm -rf --one-file-system -- "${dirs[i]}"
    done
}

wait_for_apt_idle() {
    local i package_pid
    for ((i = 1; i <= 180; i++)); do
        if [[ -e /run/sb-guard-package-active ]]; then
            package_pid="$(sed -n '1p' /run/sb-guard-package-active 2>/dev/null || true)"
            if [[ "$package_pid" =~ ^[0-9]+$ && -d "/proc/$package_pid" ]]; then
                sleep 2
                continue
            fi
        fi
        exec 18>/var/lib/dpkg/lock-frontend
        if flock -n 18; then
            exec 18>&-
            exec 19>/var/lib/dpkg/lock
            if flock -n 19; then
                exec 19>&-
                rm -f -- /run/sb-guard-package-active
                return 0
            fi
            exec 19>&-
        fi
        exec 18>&-
        sleep 2
    done
    return 1
}

fetch_and_build() {
    local expected="$1" source_dir
    wait_for_apt_idle || return 1
    # Automatic reconciliation is intentionally exact-source only.  Never
    # accept an operator-provided checkout here: the resolver maps the
    # installed package version to the corresponding GitWeb commit and caches
    # that immutable object.  Manual source experiments remain available via
    # run.sh --release's explicit-audit mode.
    source_dir="$(resolve_source "$expected")"
    EXPECTED_SHIM_SOURCE_VERSION="$expected" SB_SHIM_BUILD_LOCK_HELD=1 \
        "$CUSTOM_BUILDER" "$source_dir"
    prune_source_cache
}

usage() { printf '%s\n' 'Usage: sb-shim-auto-build [--force]'; }

# ==============================================================================
# Main
# ==============================================================================
while (( $# > 0 )); do
    case "$1" in
        --force) FORCE_BUILD=1 ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
    shift
done

for c in cmp curl dd dpkg-parsechangelog dpkg-query flock git grep mktemp objcopy \
    openssl rm sbverify sha256sum seq sleep stat strings sed install; do need "$c"; done
[[ "$(id -u)" -eq 0 ]] || die "Run as root"
validate_paths
[[ -x "$CUSTOM_BUILDER" ]] || die "Missing custom builder: $CUSTOM_BUILDER"
[[ -x "$BUILD_ROOT_HELPER" ]] || die "Missing shared build-root helper: $BUILD_ROOT_HELPER"
[[ -s "$UNSIGNED_SHIM" ]] || die "Missing $UNSIGNED_SHIM"
if [[ "${SB_GUARD_LOCK_HELD:-0}" != 1 ]]; then
    exec 200>"$GLOBAL_LOCK_FILE"
    flock -w 300 200 || die "Timed out waiting for global sb-guard lock"
    export SB_GUARD_LOCK_HELD=1
fi
exec 7>"$LOCK_FILE"
flock -w 1800 7 || die "Timed out waiting for auto-build lock"
wait_for_apt_idle || die "APT/dpkg transaction is still active"
if [[ "$FORCE_BUILD" -eq 0 ]] && custom_ready; then
    log "Custom shim already matches installed shim-unsigned; no build needed"
    exit 0
fi
expected_version="$(package_version)"
[[ -n "$expected_version" ]] || die "shim-unsigned is not installed"
log "Custom shim refresh required for shim-unsigned=$expected_version"
fetch_and_build "$expected_version" || die "Unable to fetch/build exact custom shim; ESP deployment withheld"
custom_ready || die "Builder returned an artifact that failed final readiness checks"
log "Verified custom shim is ready for serialized sb-guard reconcile"
