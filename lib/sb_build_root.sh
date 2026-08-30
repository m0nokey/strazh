#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 m0nokey
# Shared Debian Trixie build root for the GRUB and shim source builders.
#
# The base root is provisioned once with the union of both projects' build
# dependencies. Individual builds use only /build/* inside that root and
# clean those directories on every exit. No Secure Boot private key, ESP,
# host dpkg database, or /boot path is ever exposed to the chroot.
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

# ==============================================================================
# Configuration
# ==============================================================================
STATE_ROOT="${STATE_ROOT:-/var/lib/sb-guard}"
BUILD_ROOT="${BUILD_ROOT:-$STATE_ROOT/build-root}"
BASE_ROOT="${BASE_ROOT:-$BUILD_ROOT/trixie-amd64}"
APT_CACHE="${APT_CACHE:-$BUILD_ROOT/apt-cache}"
MARKER="${MARKER:-$BASE_ROOT/.sb-guard-build-root}"
LOCK_FILE="${LOCK_FILE:-/run/sb-guard-build-root.lock}"
MIRROR="${MIRROR:-https://deb.debian.org/debian}"
SECURITY_MIRROR="${SECURITY_MIRROR:-https://security.debian.org/debian-security}"
SUITE="${SUITE:-trixie}"
MIN_FREE_KB="${MIN_FREE_KB:-4194304}"
BASE_ROOT_CREATED=0

# Union of the tested GRUB and Proxmox efi-boot-shim build dependencies. The
# list is explicit; apt build-dep is used only as a one-time supplement for a
# new shim source tree and never during an APT hook.
readonly -a BASE_PACKAGES=(
    bash dash coreutils diffutils libc-bin dpkg apt ca-certificates
    build-essential autoconf automake autopoint bison flex gawk gettext
    help2man texinfo python3 dpkg-dev pkg-config binutils
    libdevmapper-dev libefiboot-dev libefivar-dev libelf-dev libfreetype-dev
    liblzma-dev liblzo2-dev lzop fonts-dejavu-core unifont xorriso xz-utils tar
    debhelper-compat dh-autoreconf git openssl sbsigntool gnu-efi efivar pesign uuid-dev
    dos2unix xxd
)

# ==============================================================================
# Helpers
# ==============================================================================
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '[sb-build-root] %s\n' "$*" >&2; }
need() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

# Strip the shell indentation from generated configuration files while
# keeping their source readable. The helper removes at most the requested
# number of leading spaces and never changes configuration content otherwise.
indent() {
    local arg="${1:-}" mode num
    if [[ "$arg" =~ ^([+-])([0-9]+)$ ]]; then
        mode="${BASH_REMATCH[1]}"
        num="${BASH_REMATCH[2]}"
    else
        mode="$arg"
        num="${2:-0}"
    fi
    case "$mode" in
        +) sed "s/^/$(printf '%*s' "$num" '')/" ;;
        -) sed -E "s/^ {0,$num}//" ;;
        0) awk '{ $1=$1; print }' ;;
        *) return 1 ;;
    esac
}

packages_hash() {
    printf '%s\n' "${BASE_PACKAGES[*]}" | sha256sum | awk '{print $1}'
}

validate_paths() {
    [[ "$STATE_ROOT" == /var/lib/sb-guard ]] ||
        die "STATE_ROOT must remain /var/lib/sb-guard"
    [[ "$BUILD_ROOT" == "$STATE_ROOT/"* ]] ||
        die "BUILD_ROOT must remain below STATE_ROOT"
    [[ "$BASE_ROOT" == "$BUILD_ROOT/"* ]] ||
        die "BASE_ROOT must remain below BUILD_ROOT"
    [[ "$APT_CACHE" == "$BUILD_ROOT/"* ]] ||
        die "APT_CACHE must remain below BUILD_ROOT"
    [[ "$MARKER" == "$BASE_ROOT/"* ]] ||
        die "MARKER must remain below BASE_ROOT"
    [[ "$MIRROR" == https://* && "$SECURITY_MIRROR" == https://* ]] ||
        die "Only HTTPS Debian mirrors are allowed"
}

free_kb() {
    df --output=avail -k "$1" | sed '1d' | tr -d '[:space:]'
}

unmount_tree() {
    local root="$1" mountpoint
    [[ -d "$root" ]] || return 0
    while IFS= read -r mountpoint; do
        [[ "$mountpoint" == "$root"/* ]] || continue
        umount -l -- "$mountpoint" >/dev/null 2>&1 || true
    done < <(findmnt -R -n -o TARGET "$root" 2>/dev/null | sort -r)
}

clean_workspace_unlocked() {
    [[ "$BASE_ROOT" == /var/lib/sb-guard/build-root/* ]] ||
        die "Refusing workspace cleanup outside the fixed build-root"
    # /build is exclusively a disposable compilation workspace.  In
    # particular, dpkg-buildpackage leaves .deb/.dsc artifacts beside the
    # source tree and GRUB's install step uses /build/root.  Remove every
    # child, not only the directories known to today's builders, while the
    # shared build-root lock is held.  The APT cache lives outside /build and
    # is therefore retained for subsequent builds.
    if [[ -d "$BASE_ROOT/build" ]]; then
        find "$BASE_ROOT/build" -mindepth 1 -maxdepth 1 \
            -exec rm -rf --one-file-system -- {} +
    fi
    install -d -m 0700 -o root -g root \
        "$BASE_ROOT/build/source" "$BASE_ROOT/build/deps-source" \
        "$BASE_ROOT/build/input" "$BASE_ROOT/build/out" \
        "$BASE_ROOT/build/tmp" "$BASE_ROOT/build/home"
}

close_inherited_fds_for_mmdebstrap() {
    # mmdebstrap reports package download status through an APT hook of the
    # form `cat >&N`. Debian's dash only accepts single-digit descriptors. The
    # build orchestrators intentionally hold several lock descriptors, which
    # can make mmdebstrap allocate N=10 or higher and fail before provisioning
    # starts. Close inherited descriptors only in this child; the parent keeps
    # every lock open for the duration of the transaction.
    local fd
    for ((fd = 3; fd <= 255; fd++)); do
        exec {fd}>&- 2>/dev/null || true
    done
}

write_sources() {
    local root="$1"
    cat <<EOF | indent -4 | install -D -m 0644 /dev/stdin \
        "$root/etc/apt/sources.list.d/sb-guard-build.sources"
    Types: deb deb-src
    URIs: $MIRROR
    Suites: $SUITE $SUITE-updates
    Components: main
    Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

    Types: deb deb-src
    URIs: $SECURITY_MIRROR
    Suites: $SUITE-security
    Components: main
    Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
}

configure_dns() {
    local root="$1"
    rm -f -- "$root/etc/resolv.conf"
    cat <<'EOF' | indent -4 | install -m 0644 /dev/stdin "$root/etc/resolv.conf"
    nameserver 1.1.1.1
    nameserver 9.9.9.9
    options timeout:2 attempts:3
EOF
}

base_is_ready() {
    [[ -s "$MARKER" && -x "$BASE_ROOT/bin/bash" && -s "$BASE_ROOT/etc/os-release" ]] ||
        return 1
    grep -Fxq "suite=$SUITE" "$MARKER" || return 1
    grep -Fxq "packages_sha256=$(packages_hash)" "$MARKER" || return 1
}

ensure_base() {
    local rc=0
    BASE_ROOT_CREATED=0
    if base_is_ready; then
        log "Using cached Trixie build root: $BASE_ROOT"
        clean_workspace_unlocked
        return 0
    fi

    install -d -m 0700 -o root -g root "$BUILD_ROOT" "$APT_CACHE"
    [[ "$(free_kb "$BUILD_ROOT")" =~ ^[0-9]+$ ]] ||
        die "Cannot determine free space for $BUILD_ROOT"
    (( $(free_kb "$BUILD_ROOT") >= MIN_FREE_KB )) ||
        die "Less than $MIN_FREE_KB KiB free on encrypted build filesystem"

    # A previous interrupted provisioning must never be reused as a base.
    if [[ -e "$BASE_ROOT" ]]; then
        unmount_tree "$BASE_ROOT"
        rm -rf --one-file-system -- "$BASE_ROOT"
    fi
    install -d -m 0700 -o root -g root "$BASE_ROOT"
    BASE_ROOT_CREATED=1
    cleanup() {
        rc=$?
        set +e
        unmount_tree "$BASE_ROOT"
        if (( rc != 0 && BASE_ROOT_CREATED == 1 )); then
            rm -rf --one-file-system -- "$BASE_ROOT" 2>/dev/null || true
        fi
        exit "$rc"
    }
    trap cleanup EXIT INT TERM

    log "Provisioning one cached Debian $SUITE build root"
    local include
    include="$(IFS=,; printf '%s' "${BASE_PACKAGES[*]}")"
    (
        close_inherited_fds_for_mmdebstrap
        mmdebstrap --variant=essential --architectures=amd64 --components=main \
            --include="$include" \
            --aptopt='Acquire::Retries "5"' \
            --aptopt='Acquire::ForceIPv4 "true"' \
            --aptopt='Acquire::https::Timeout "30"' \
            --aptopt='APT::Install-Recommends "false"' \
            --aptopt='APT::Install-Suggests "false"' \
            --setup-hook="mkdir -p \"\$1/var/cache/apt/archives\"; mount --bind \"$APT_CACHE\" \"\$1/var/cache/apt/archives\"" \
            --customize-hook='umount "$1/var/cache/apt/archives"' \
            "$SUITE" "$BASE_ROOT" \
            "deb $MIRROR $SUITE main" "deb $SECURITY_MIRROR $SUITE-security main"
    )
    write_sources "$BASE_ROOT"
    configure_dns "$BASE_ROOT"
    clean_workspace_unlocked
    {
        printf 'suite=%s\n' "$SUITE"
        printf 'packages_sha256=%s\n' "$(packages_hash)"
        printf 'mirror=%s\n' "$MIRROR"
        printf 'security_mirror=%s\n' "$SECURITY_MIRROR"
        printf 'created_at=%s\n' "$(date -Is)"
    } >"$MARKER"
    chmod 0600 "$MARKER"
    sync
    trap - EXIT INT TERM
    BASE_ROOT_CREATED=0
    log "Cached build root ready: $BASE_ROOT"
}

ensure_shim_deps() {
    local source="$1" commit source_version dep_status
    [[ -d "$source" && -f "$source/debian/control" ]] ||
        die "Shim source must contain debian/control: $source"
    commit="$(git -C "$source" rev-parse HEAD 2>/dev/null || true)"
    [[ "$commit" =~ ^[[:xdigit:]]{40}$ ]] ||
        die "Cannot identify exact shim source commit: $source"
    source_version="$(cd "$source" && dpkg-parsechangelog -S Version 2>/dev/null || true)"
    [[ -n "$source_version" ]] || die "Shim source has no Debian changelog version"

    ensure_base
    if [[ "${SB_BUILD_ROOT_LOCK_HELD:-0}" != 1 ]]; then
        exec 9>"$LOCK_FILE"
        flock -w 1800 9 || die "Timed out waiting for shared build-root lock"
    fi
    dep_status="$(grep -E '^shim_deps_(commit|version|status)=' "$MARKER" 2>/dev/null || true)"
    if grep -Fxq "shim_deps_commit=$commit" <<<"$dep_status" \
        && grep -Fxq 'shim_deps_status=ok' <<<"$dep_status"; then
        log "Shim build dependencies already cached for $source_version ($commit)"
        return 0
    fi

    clean_workspace_unlocked
    tar -C "$source" --exclude=.git --exclude=.gitmodules -cf - . |
        tar -C "$BASE_ROOT/build/deps-source" -xf -
    log "Resolving additional shim Build-Depends once for $source_version"
    if chroot "$BASE_ROOT" /bin/bash -Eeuo pipefail -c \
        'cd /build/deps-source && apt-get -o Acquire::Retries=5 -o Acquire::ForceIPv4=true -o Acquire::https::Timeout=30 build-dep -y --no-install-recommends ./'; then
        {
            grep -v '^shim_deps_' "$MARKER" 2>/dev/null || true
            printf 'shim_deps_commit=%s\n' "$commit"
            printf 'shim_deps_version=%s\n' "$source_version"
            printf 'shim_deps_status=ok\n'
        } >"$MARKER.new"
        chmod 0600 "$MARKER.new"
        mv -f "$MARKER.new" "$MARKER"
        log "Shim Build-Depends cached"
    else
        log "WARN: shim Build-Depends resolution failed; explicit union remains available"
        {
            grep -v '^shim_deps_' "$MARKER" 2>/dev/null || true
            printf 'shim_deps_commit=%s\n' "$commit"
            printf 'shim_deps_version=%s\n' "$source_version"
            printf 'shim_deps_status=failed\n'
        } >"$MARKER.new"
        chmod 0600 "$MARKER.new"
        mv -f "$MARKER.new" "$MARKER"
    fi
    clean_workspace_unlocked
}

status() {
    printf 'base_root=%s\n' "$BASE_ROOT"
    if base_is_ready; then
        printf 'status=ready\n'
        sed -n '1,20p' "$MARKER"
    else
        printf 'status=absent-or-stale\n'
    fi
}

purge() {
    [[ "$BUILD_ROOT" == /var/lib/sb-guard/build-root ]] ||
        die "Refusing purge outside the fixed build-root"
    exec 9>"$LOCK_FILE"
    flock -w 1800 9 || die "Timed out waiting for shared build-root lock"
    unmount_tree "$BASE_ROOT"
    rm -rf --one-file-system -- "$BASE_ROOT" "$APT_CACHE"
    log "Removed cached build root and its apt cache"
}

# ==============================================================================
# Main
# ==============================================================================
[[ "$(id -u)" -eq 0 ]] || die "Run as root"
validate_paths
for cmd in awk chroot date df dpkg-parsechangelog find findmnt flock git grep install mount mv rm sed sha256sum sort sync tar umount mmdebstrap; do
    need "$cmd"
done

action=""
shim_source=""
while (( $# > 0 )); do
    case "$1" in
        --ensure) action=ensure; shift ;;
        --shim-deps) [[ $# -ge 2 ]] || die "--shim-deps requires SOURCE_DIR"; shim_source="$2"; shift 2 ;;
        --clean) action=clean; shift ;;
        --status) action=status; shift ;;
        --purge) action=purge; shift ;;
        -h|--help)
            printf '%s\n' \
                'Usage: sb-build-root --ensure [--shim-deps SOURCE_DIR] | --clean | --status | --purge'
            exit 0
            ;;
        *) die "Unknown argument: $1" ;;
    esac
done

case "$action" in
    ensure)
        if [[ "${SB_BUILD_ROOT_LOCK_HELD:-0}" != 1 ]]; then
            exec 9>"$LOCK_FILE"
            flock -w 1800 9 || die "Timed out waiting for shared build-root lock"
            export SB_BUILD_ROOT_LOCK_HELD=1
        fi
        ensure_base
        [[ -z "$shim_source" ]] || ensure_shim_deps "$shim_source"
        ;;
    clean)
        if [[ "${SB_BUILD_ROOT_LOCK_HELD:-0}" != 1 ]]; then
            exec 9>"$LOCK_FILE"
            flock -w 1800 9 || die "Timed out waiting for shared build-root lock"
        fi
        base_is_ready || die "Shared build root is not ready"
        clean_workspace_unlocked
        ;;
    status) status ;;
    purge) purge ;;
    *) printf '%s\n' 'Use --help for usage.' >&2; exit 2 ;;
esac
