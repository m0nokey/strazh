#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 m0nokey
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

# Private custom shim builder with our own embedded vendor certificate.
# The public run.sh entry point installs this builder as
# /usr/local/sbin/sb-shim-build-custom; the serialized worker may invoke that
# installed copy only after the APT transaction ends.

# ==============================================================================
# Configuration
# ==============================================================================
STATE_ROOT="${STATE_ROOT:-/var/lib/sb-guard}"
KEY_DIR="${KEY_DIR:-$STATE_ROOT/keys}"
DB_CRT="${DB_CRT:-$KEY_DIR/db.crt}"
DB_KEY="${DB_KEY:-$KEY_DIR/db.key}"
CUSTOM_DIR="${CUSTOM_DIR:-$STATE_ROOT/custom-shim}"
RELEASE_MODE=0
if [[ "${1:-}" == "--release" ]]; then
    RELEASE_MODE=1
    shift
fi
SOURCE_DIR="${SHIM_SOURCE_DIR:-${1:-}}"
BUILD_LOCK_FILE="${SHIM_BUILD_LOCK_FILE:-/run/sb-shim-build.lock}"
BUILD_LOCK_HELD="${SB_SHIM_BUILD_LOCK_HELD:-0}"
GLOBAL_LOCK_FILE="${GLOBAL_LOCK_FILE:-/run/sb-guard.lock}"
SHIM_SOURCE_CHROOT_BUILDER="${SHIM_SOURCE_CHROOT_BUILDER:-/usr/local/sbin/sb-shim-source-chroot}"

# ==============================================================================
# Helpers
# ==============================================================================
die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "[$(date '+%F %T')] $*" >&2; }

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

usage() {
    cat <<'EOF'
Usage:
  /usr/local/sbin/sb-shim-build-custom --release
      Build signed GRUB and custom shim into
      /var/lib/sb-guard/release without writing ESP.
  /usr/local/sbin/sb-shim-build-custom /path/to/verified/efi-boot-shim-source
      Build only a custom shim from an explicitly verified source tree.
EOF
}

run_release() {
    local profile=/usr/local/sbin/sb-grub-profile-chroot
    local shim_auto=/usr/local/sbin/sb-shim-auto-build
    local shim_rebuild=/usr/local/sbin/sb-shim-rebuild
    local guard=/usr/local/sbin/sb-guard
    [[ $# -eq 0 ]] || die "Usage: $0 --release"
    [[ -s "$DB_CRT" && -s "$DB_KEY" ]] || die "Missing db key/certificate"
    for cmd in "$profile" "$shim_auto" "$shim_rebuild" "$guard"; do
        [[ -x "$cmd" ]] || die "Missing installed sb-guard command: $cmd"
    done

    # Serialize the complete build → publish → stage transaction with the
    # systemd reconcile worker.  The individual builders retain their own
    # locks, but those alone do not protect the transaction as a whole.
    if [[ "${SB_GUARD_LOCK_HELD:-0}" != 1 ]]; then
        exec 200>/run/sb-guard.lock
        flock -w 300 200 || die "Timed out waiting for sb-guard reconcile lock"
        export SB_GUARD_LOCK_HELD=1
    fi

    log "Ensuring source-matched Proxmox GRUB profile in the shared cached Trixie root"
    "$profile" --ensure-auto
    log "Building matching custom shim from installed shim-unsigned"
    "$shim_auto" --force
    log "Publishing verified custom shim to the encrypted golden store"
    "$shim_rebuild" --force
    log "Generating signed release bundle without writing to ESP"
    GRUB_BUILD_POLICY=/dev/null \
    GRUB_BUILD_MODE=profile \
        "$guard" --stage-release

    # Activate profile mode only after the complete release bundle has passed
    # all checks. This changes policy, never ESP; deployment remains the
    # separate controlled sb-guard reconcile transaction.
    local policy_tmp=/etc/sb-guard/grub-build.env.new
    trap 'rm -f -- "$policy_tmp"' EXIT INT TERM
    install -d -m 0700 -o root -g root /etc/sb-guard
    cat <<'EOF' | indent -4 | install -m 0600 -o root -g root /dev/stdin "$policy_tmp"
    # sb-guard GRUB build policy
    # Cached Trixie profile matched to the installed Proxmox source commit.
    GRUB_BUILD_MODE=profile
    GRUB_BUILD_PROFILE=/var/lib/sb-guard/grub-build/profile
    GRUB_PROFILE_ENV=/var/lib/sb-guard/grub-build/profile/profile.env
EOF
    mv -f "$policy_tmp" /etc/sb-guard/grub-build.env
    trap - EXIT INT TERM

    log "Release bundle is ready: $STATE_ROOT/release"
    log "ESP was not modified; deploy only through sb-guard --fix-all after review"
}

# ==============================================================================
# Preconditions and source validation
# ==============================================================================
[[ "$(id -u)" -eq 0 ]] || die "Run as root"
for cmd in sed install mv rm flock; do
    command -v "$cmd" >/dev/null 2>&1 || die "Missing command: $cmd"
done
if (( RELEASE_MODE == 0 )); then
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        usage
        exit 0
    fi
    [[ -n "$SOURCE_DIR" ]] || die "Usage: $0 /path/to/verified/shim-source"
    [[ -d "$SOURCE_DIR" && -f "$SOURCE_DIR/debian/rules" ]] \
        || die "Source directory must contain debian/rules: $SOURCE_DIR"
fi
[[ -s "$DB_CRT" && -s "$DB_KEY" ]] || die "Missing db key/certificate"

# A direct source build also publishes the verified golden shim.  Serialize it
# with the worker and release path, not only with the per-shim build lock.
if [[ "$RELEASE_MODE" -eq 0 && "${SB_GUARD_LOCK_HELD:-0}" != 1 ]]; then
    exec 200>"$GLOBAL_LOCK_FILE"
    flock -w 300 200 || die "Timed out waiting for sb-guard reconcile lock"
    export SB_GUARD_LOCK_HELD=1
fi

if (( RELEASE_MODE == 1 )); then
    run_release "$@"
    exit 0
fi

for cmd in awk openssl sbsign sbverify sbattach dpkg-parsechangelog sha256sum cp find strings objcopy stat dd cmp git; do
    command -v "$cmd" >/dev/null 2>&1 || die "Missing command: $cmd"
done
[[ -x "$SHIM_SOURCE_CHROOT_BUILDER" ]] || die "Missing isolated shim source builder: $SHIM_SOURCE_CHROOT_BUILDER"

if [[ "$BUILD_LOCK_HELD" != 1 ]]; then
    exec 8>"$BUILD_LOCK_FILE"
    flock -w 1800 8 || die "Timed out waiting for shim build lock: $BUILD_LOCK_FILE"
fi

installed_version="$(dpkg-query -W -f='${Version}\n' shim-unsigned 2>/dev/null | sed '/^$/d;1q' || true)"
[[ -n "$installed_version" ]] || die "shim-unsigned is not installed"
[[ -s /usr/lib/shim/shimx64.efi ]] || die "Missing /usr/lib/shim/shimx64.efi"
installed_sha256="$(sha256sum /usr/lib/shim/shimx64.efi | awk '{print $1}')"
vendor_fingerprint="$(openssl x509 -in "$DB_CRT" -noout -fingerprint -sha256 | sed 's/^sha256 Fingerprint=//')"

expected_source_version="${EXPECTED_SHIM_SOURCE_VERSION:-$installed_version}"

# ==============================================================================
# Build and sign
# ==============================================================================
build_dir="$(mktemp -d -p /tmp sb-custom-shim.XXXXXX)"
cleanup() { rm -rf --one-file-system "$build_dir" 2>/dev/null || rm -rf "$build_dir" 2>/dev/null || true; }
trap cleanup EXIT
trap 'exit 130' INT TERM

SOURCE_DIR="$(cd -- "$SOURCE_DIR" && pwd -P)"
source="$SOURCE_DIR"
vendor_der="$build_dir/vendor.der"
openssl x509 -in "$DB_CRT" -outform DER -out "$vendor_der"
chmod 0644 "$vendor_der"

source_version="$(cd "$source" && dpkg-parsechangelog -S Version 2>/dev/null || true)"
[[ -n "$source_version" ]] || die "Source tree has no Debian changelog version"
[[ "$source_version" == "$expected_source_version" ]] || die \
    "Source version $source_version does not match installed Proxmox package $expected_source_version"

log "Building exact base source $source_version in the shared cached Trixie root"

source_git_commit="$(git -C "$source" rev-parse HEAD 2>/dev/null || true)"
source_remote="$(git -C "$source" config --get remote.origin.url 2>/dev/null || true)"
[[ -n "$source_git_commit" ]] || die "Source must be a git checkout so its exact commit can be recorded"
[[ "$source_remote" == "https://git.proxmox.com/git/efi-boot-shim.git" \
    || "$source_remote" == "git://git.proxmox.com/git/efi-boot-shim.git" ]] || die \
    "Source remote is not the official Proxmox efi-boot-shim repository"
source_tree_sha256="$({ find "$source" -type f -not -path '*/.git/*' -not -path '*/debian/tmp/*' -not -path '*/debian/.debhelper/*' -print0 \
    | sort -z \
    | xargs -0r sha256sum; } | sha256sum | awk '{print $1}')"
expected_source_ref="${EXPECTED_SHIM_SOURCE_REF:-}"
expected_source_remote="${EXPECTED_SHIM_SOURCE_REMOTE:-https://git.proxmox.com/git/efi-boot-shim.git}"
if [[ -n "$expected_source_ref" ]]; then
    [[ "$expected_source_ref" =~ ^proxmox/trixie-[0-9A-Za-z.+:~_-]+$ ]] || die \
        "Invalid expected Proxmox shim source ref: $expected_source_ref"
fi
[[ "$source_remote" == "$expected_source_remote" || \
    "$source_remote" == "$expected_source_remote.git" ]] || die \
    "Source remote does not match the resolved Proxmox remote"

unsigned_efi="$build_dir/shimx64.unsigned.efi"
"$SHIM_SOURCE_CHROOT_BUILDER" "$source" "$vendor_der" "$unsigned_efi"
[[ -s "$unsigned_efi" ]] || die "Build did not produce shimx64.efi"
clean_efi="$build_dir/shimx64.clean.efi"
cp -a "$unsigned_efi" "$clean_efi"
# The source build may carry a distro/vendor Authenticode table. Remove it
# before adding our signature so the published image has exactly one signer.
sbattach --remove "$clean_efi" >/dev/null 2>&1 || true
signed_efi="$build_dir/shimx64.signed.efi"
sbsign --key "$DB_KEY" --cert "$DB_CRT" --output "$signed_efi" "$clean_efi" >/dev/null
sbverify --cert "$DB_CRT" "$signed_efi" >/dev/null

sig_count="$(sbverify --list "$signed_efi" 2>/dev/null | grep -cE '^signature[[:space:]]+[0-9]+$' || true)"
[[ "$sig_count" -eq 1 ]] || die "Expected exactly one Authenticode signature, got $sig_count"

# ==============================================================================
# Embedded vendor certificate verification
# ==============================================================================
# shim stores VENDOR_CERT_FILE in a 16-byte metadata prefix followed by the
# exact DER certificate. Compare bytes, not only printable subject strings.
embedded_section="$build_dir/vendor.section"
embedded_der="$build_dir/vendor.embedded.der"
objcopy --dump-section .vendor_cert="$embedded_section" "$signed_efi" "$build_dir/objcopy-output.efi"
der_size="$(stat -c '%s' "$vendor_der")"
dd if="$embedded_section" of="$embedded_der" bs=1 skip=16 count="$der_size" status=none
cmp -s "$vendor_der" "$embedded_der" \
    || die "Embedded .vendor_cert is not byte-identical to current db.crt"

# The embedded public certificate must be ours, not the Proxmox package CA.
our_subject="$(openssl x509 -in "$DB_CRT" -noout -subject | sed 's/^subject=//')"
strings_output="$(strings "$signed_efi" 2>/dev/null || true)"
grep -Fq "sb-guard db" <<<"$strings_output" \
    || die "Custom shim does not contain the expected sb-guard certificate subject"
if grep -Fq "Proxmox Server Solutions GmbH" <<<"$strings_output" \
    || grep -Fq "office@proxmox.com" <<<"$strings_output"; then
    die "Custom shim still contains the Proxmox vendor certificate"
fi

signed_sha256="$(sha256sum "$signed_efi" | awk '{print $1}')"
install -d -m 0700 -o root -g root "$CUSTOM_DIR"
install -m 0600 -o root -g root "$signed_efi" "$CUSTOM_DIR/shimx64.efi.new"
mv -f "$CUSTOM_DIR/shimx64.efi.new" "$CUSTOM_DIR/shimx64.efi"
{
    printf 'mode=custom-built\n'
    printf 'source_package_version=%s\n' "$installed_version"
    printf 'source_tree_version=%s\n' "$source_version"
    printf 'source_package_sha256=%s\n' "$installed_sha256"
    printf 'source_tree_sha256=%s\n' "$source_tree_sha256"
    printf 'source_git_commit=%s\n' "$source_git_commit"
    printf 'source_remote=%s\n' "$source_remote"
    printf 'source_ref=%s\n' "$expected_source_ref"
    printf 'vendor_fingerprint=%s\n' "$vendor_fingerprint"
    printf 'vendor_subject=%s\n' "$our_subject"
    printf 'signed_sha256=%s\n' "$signed_sha256"
    printf 'built_at=%s\n' "$(date -Is)"
} >"$CUSTOM_DIR/shim.state.new"
chmod 0600 "$CUSTOM_DIR/shim.state.new"
mv -f "$CUSTOM_DIR/shim.state.new" "$CUSTOM_DIR/shim.state"

log "Custom shim ready: $CUSTOM_DIR/shimx64.efi"
log "source_package_version=$installed_version"
log "source_package_sha256=$installed_sha256"
log "signed_sha256=$signed_sha256"
log "No ESP files were changed. Run sb-guard-event refresh after review."
