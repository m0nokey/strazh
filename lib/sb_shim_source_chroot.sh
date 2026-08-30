#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 m0nokey
# Shared cached Debian Trixie build root for the Proxmox shim source.
#
# The source build is deliberately separate from signing: this helper receives
# only the source tree and the public db certificate.  The Secure Boot private
# key never enters the chroot and is used by the run.sh release path only after
# the unsigned PE image has been copied back to the host.  Only the /build
# workspace is disposable; the base root and APT cache are reused.
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

# ==============================================================================
# Configuration
# ==============================================================================
STATE_ROOT="${STATE_ROOT:-/var/lib/sb-guard}"
BUILD_ROOT="${BUILD_ROOT:-$STATE_ROOT/build-root/trixie-amd64}"
BUILD_ROOT_HELPER="${BUILD_ROOT_HELPER:-/usr/local/sbin/sb-build-root}"
BUILD_ROOT_LOCK_FILE="${BUILD_ROOT_LOCK_FILE:-/run/sb-guard-build-root.lock}"
GLOBAL_LOCK_FILE="${GLOBAL_LOCK_FILE:-/run/sb-guard.lock}"
MIRROR="${MIRROR:-https://deb.debian.org/debian}"
SECURITY_MIRROR="${SECURITY_MIRROR:-https://security.debian.org/debian-security}"
SUITE="${SUITE:-trixie}"
MIN_FREE_KB="${MIN_FREE_KB:-1048576}"

# ==============================================================================
# Helpers
# ==============================================================================
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '[sb-shim-source-chroot] %s\n' "$*" >&2; }
need() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }
sha256_file() { sha256sum "$1" | awk '{print $1}'; }
free_kb() { df --output=avail -k "$1" | sed '1d' | tr -d '[:space:]'; }

validate_paths() {
    [[ "$STATE_ROOT" == /var/lib/sb-guard ]] ||
        die "STATE_ROOT must remain /var/lib/sb-guard"
    [[ "$BUILD_ROOT" == "$STATE_ROOT/"* ]] ||
        die "BUILD_ROOT must remain below STATE_ROOT"
    [[ "$MIRROR" == https://* && "$SECURITY_MIRROR" == https://* ]] ||
        die "Only HTTPS Debian mirrors are allowed"
}

copy_source() {
    local source="$1" root="$2"
    rm -rf -- "$root/build/source" "$root/build/input" "$root/build/out"
    install -d -m 0700 "$root/build/source" "$root/build/input" "$root/build/out"
    # The source is required to be a git checkout by the caller.  Git metadata
    # is not needed inside the build and is excluded from the input tree.
    tar -C "$source" --exclude=.git --exclude=.gitmodules -cf - . |
        tar -C "$root/build/source" -xf -
    install -m 0644 "$DB_CRT" "$root/build/input/db.crt"
    chown -R root:root "$root/build/source" "$root/build/input" "$root/build/out"
}

provision_dependencies() {
    local source="$1"
    [[ -x "$BUILD_ROOT_HELPER" ]] || die "Missing shared build-root helper: $BUILD_ROOT_HELPER"
    SB_BUILD_ROOT_LOCK_HELD=1 "$BUILD_ROOT_HELPER" --ensure --shim-deps "$source"
}

build_no_network() {
    local root="$1"
    unshare --mount --net --fork -- chroot "$root" /bin/bash -Eeuo pipefail -c '
        # Use a locale guaranteed by the Debian base system rather than a host
        # LANG such as en_US.UTF-8, which otherwise makes Perl warn during
        # autoreconf.  Only the known Python SyntaxWarning class is filtered;
        # command failures and all other diagnostics remain visible.
        export HOME=/build/home TMPDIR=/build/tmp
        export LANG=C.UTF-8 LANGUAGE=C.UTF-8 LC_ALL=C.UTF-8
        export PYTHONWARNINGS=ignore::SyntaxWarning
        mkdir -p /build/home /build/tmp /build/out
        cd /build/source
        [[ -f debian/rules ]] || { echo "missing debian/rules" >&2; exit 1; }
        debian/rules clean
        debian/rules cert=/build/input/db.crt binary
        [[ -s shimx64.efi ]] || { echo "shim source build produced no shimx64.efi" >&2; exit 1; }
        install -m 0600 shimx64.efi /build/out/shimx64.efi
        rm -rf -- /build/tmp
    '
}

usage() {
    cat <<'EOF'
Usage:
  sb-shim-source-chroot SOURCE_DIR DB_CRT OUTPUT_EFI

Builds the Proxmox shim source in the shared cached Debian Trixie base with no
network during compilation.  Only the public certificate enters the disposable
/build workspace; the Secure Boot private key is never copied there.
EOF
}

# ==============================================================================
# Main
# ==============================================================================
[[ "$(id -u)" -eq 0 ]] || die "Run as root"
[[ $# -eq 3 ]] || { usage >&2; exit 2; }
SOURCE_DIR="$1"
DB_CRT="$2"
OUTPUT="$3"
[[ "$SOURCE_DIR" = /* && -d "$SOURCE_DIR" ]] || die "Invalid source directory: $SOURCE_DIR"
[[ -f "$SOURCE_DIR/debian/rules" && -f "$SOURCE_DIR/debian/control" ]] ||
    die "Source tree must contain debian/rules and debian/control"
[[ -s "$DB_CRT" ]] || die "Missing public db certificate: $DB_CRT"
[[ "$OUTPUT" = /* ]] || die "Output path must be absolute: $OUTPUT"
validate_paths
for cmd in awk chown chroot cp df dirname dpkg-parsechangelog find flock install mkdir rm sed sha256sum stat tar unshare; do need "$cmd"; done
[[ -x "$BUILD_ROOT_HELPER" ]] || die "Missing shared build-root helper: $BUILD_ROOT_HELPER"

source_version="$(cd "$SOURCE_DIR" && dpkg-parsechangelog -S Version 2>/dev/null || true)"
[[ -n "$source_version" ]] || die "Source tree has no Debian changelog version"

install -d -m 0700 -o root -g root "$STATE_ROOT"
if [[ "${SB_GUARD_LOCK_HELD:-0}" != 1 ]]; then
    exec 200>"$GLOBAL_LOCK_FILE"
    flock -w 300 200 || die "Timed out waiting for global sb-guard lock"
    export SB_GUARD_LOCK_HELD=1
fi
exec 9>"$BUILD_ROOT_LOCK_FILE"
flock -w 1800 9 || die "Timed out waiting for shared build-root lock"
export SB_BUILD_ROOT_LOCK_HELD=1
root="$BUILD_ROOT"
cleanup() { "$BUILD_ROOT_HELPER" --clean >/dev/null 2>&1 || true; }
trap cleanup EXIT
trap 'exit 130' INT TERM

log "Using shared cached Debian $SUITE build root for shim version $source_version"
"$BUILD_ROOT_HELPER" --ensure
provision_dependencies "$SOURCE_DIR"
copy_source "$SOURCE_DIR" "$root"
log "Compiling shim with an empty network namespace"
build_no_network "$root"
install -d -m 0700 "$(dirname "$OUTPUT")"
install -m 0600 "$root/build/out/shimx64.efi" "$OUTPUT"
log "Unsigned shim build ready: $OUTPUT sha256=$(sha256_file "$OUTPUT")"
