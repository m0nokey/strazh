#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 m0nokey
#
# Root-only plain dm-crypt vault for Strazh signing keys. This intentionally
# has no LUKS header: all mapping parameters are fixed below and the mounted
# filesystem contains a generation marker to reject a wrong passphrase.
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

STATE_ROOT="${STRAZH_STATE_ROOT:-/var/lib/sb-guard}"
KEY_ROOT="${STRAZH_KEY_ROOT:-$STATE_ROOT/keys}"
VAULT_ROOT="${STRAZH_KEY_VAULT_ROOT:-$KEY_ROOT/vault}"
RUNTIME_ROOT="${STRAZH_KEY_RUNTIME_ROOT:-/run/strazh/key-vault}"
VAULT_SIZE_MIB="${STRAZH_KEY_VAULT_SIZE_MIB:-64}"

# These values are part of the on-disk format. Do not change them for an
# existing generation or the plain container cannot be reopened.
readonly DMCRYPT_CIPHER='aes-xts-plain64'
readonly DMCRYPT_KEY_SIZE='512'
readonly DMCRYPT_HASH='sha512'
readonly DMCRYPT_SECTOR_SIZE='512'

log() { printf '[strazh-key-vault] %s\n' "$*" >&2; }
die() {
    log "ERROR: $*"
    exit 1
}
need() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }
require_root() { [[ "$(id -u)" -eq 0 ]] || die 'Run this command as root.'; }
require_tty() {
    [[ -r /dev/tty && -w /dev/tty ]] ||
        die 'This vault operation requires an interactive terminal (/dev/tty)'
}

valid_generation() { [[ "$1" =~ ^generation-[1-9][0-9]*$ ]]; }
vault_dir() { printf '%s/%s\n' "$VAULT_ROOT" "$1"; }
vault_path() { printf '%s/private-keys.dmcrypt\n' "$(vault_dir "$1")"; }
metadata_path() { printf '%s/format.conf\n' "$(vault_dir "$1")"; }
mapper_name() { printf 'strazh-keys-%s\n' "${1//[^A-Za-z0-9_-]/_}"; }
mount_path() { printf '%s/%s\n' "$RUNTIME_ROOT" "$1"; }
private_uefi_path() { printf '%s/uefi/%s.key\n' "$(mount_path "$1")" "$2"; }
private_gpg_path() { printf '%s/gpg\n' "$(mount_path "$1")"; }

secure_dir() {
    local path="$1"
    [[ -d "$path" && ! -L "$path" ]] || die "Required directory is missing or symlinked: $path"
    [[ "$(stat -c '%u:%g:%a' "$path")" == '0:0:700' ]] ||
        die "Unsafe owner or mode on directory: $path"
}

secure_file() {
    local path="$1"
    [[ -f "$path" && ! -L "$path" ]] || die "Required file is missing or symlinked: $path"
    [[ "$(stat -c '%u:%g:%a' "$path")" == '0:0:600' ]] ||
        die "Unsafe owner or mode on file: $path"
}

validate_size() {
    [[ "$VAULT_SIZE_MIB" =~ ^[1-9][0-9]*$ ]] ||
        die 'STRAZH_KEY_VAULT_SIZE_MIB must be a positive integer'
    ((VAULT_SIZE_MIB >= 16)) || die 'Key vault must be at least 16 MiB'
}

ensure_roots() {
    install -d -m 0700 -o root -g root "$KEY_ROOT" "$VAULT_ROOT" "$RUNTIME_ROOT"
    secure_dir "$KEY_ROOT"
    secure_dir "$VAULT_ROOT"
    secure_dir "$RUNTIME_ROOT"
}

assert_generation() {
    local generation="$1"
    valid_generation "$generation" || die "Invalid generation name: $generation"
}

write_format_metadata() {
    local generation="$1" metadata tmp
    metadata="$(metadata_path "$generation")"
    tmp="$(mktemp "${metadata}.tmp.XXXXXX")"
    trap 'rm -f -- "${tmp:-}"' RETURN
    umask 077
    {
        printf 'format=plain-dmcrypt\n'
        printf 'cipher=%s\n' "$DMCRYPT_CIPHER"
        printf 'key_size=%s\n' "$DMCRYPT_KEY_SIZE"
        printf 'hash=%s\n' "$DMCRYPT_HASH"
        printf 'sector_size=%s\n' "$DMCRYPT_SECTOR_SIZE"
    } >"$tmp"
    chmod 0600 "$tmp"
    mv -f -- "$tmp" "$metadata"
    trap - RETURN
}

verify_format_metadata() {
    local generation="$1" metadata
    metadata="$(metadata_path "$generation")"
    secure_file "$metadata"
    grep -Fxq 'format=plain-dmcrypt' "$metadata" || die "Unsupported vault format: $metadata"
    grep -Fxq "cipher=$DMCRYPT_CIPHER" "$metadata" || die 'Vault cipher policy mismatch'
    grep -Fxq "key_size=$DMCRYPT_KEY_SIZE" "$metadata" || die 'Vault key-size policy mismatch'
    grep -Fxq "hash=$DMCRYPT_HASH" "$metadata" || die 'Vault hash policy mismatch'
    grep -Fxq "sector_size=$DMCRYPT_SECTOR_SIZE" "$metadata" || die 'Vault sector-size policy mismatch'
}

read_vault_passphrase() {
    local prompt="$1" passphrase confirm
    require_tty
    printf '%s: ' "$prompt" >&2
    IFS= read -r -s passphrase </dev/tty || die 'Could not read vault passphrase'
    printf '\n' >&2
    [[ -n "$passphrase" ]] || die 'Vault passphrase cannot be empty'
    if [[ "${2:-}" == confirm ]]; then
        printf 'Confirm vault passphrase: ' >&2
        IFS= read -r -s confirm </dev/tty || die 'Could not read vault passphrase confirmation'
        printf '\n' >&2
        [[ "$passphrase" == "$confirm" ]] || die 'Vault passphrase confirmation does not match'
        unset confirm
    fi
    printf '%s' "$passphrase"
    unset passphrase
}

generate_vault_passphrase() {
    local answer

    require_tty
    DMCRYPT_PASSPHRASE="$(openssl rand -hex 64)" ||
        die 'Cannot generate a random vault passphrase'
    [[ "$DMCRYPT_PASSPHRASE" =~ ^[[:xdigit:]]{128}$ ]] ||
        die 'Random vault passphrase has an unexpected format'

    printf '\n%s\n' 'IMPORTANT: save this vault passphrase securely.' >/dev/tty
    printf '%s\n' 'It is shown once and is never stored by Strazh.' >/dev/tty
    printf '\n%s\n\n' "$DMCRYPT_PASSPHRASE" >/dev/tty
    while true; do
        printf 'Have you saved the passphrase? [y/n] ' >/dev/tty
        IFS= read -r answer </dev/tty || die 'Could not read save confirmation'
        case "$answer" in
        y | Y | yes | YES)
            unset answer
            return 0
            ;;
        n | N | no | NO)
            unset DMCRYPT_PASSPHRASE answer
            die 'Creation cancelled; passphrase was not accepted'
            ;;
        *) printf '%s\n' 'Please answer y or n.' >/dev/tty ;;
        esac
    done
}

open_mapping() {
    local vault="$1" mapper="$2" passphrase="$3"
    printf '%s' "$passphrase" |
        cryptsetup open --type plain --cipher "$DMCRYPT_CIPHER" \
            --key-size "$DMCRYPT_KEY_SIZE" --hash "$DMCRYPT_HASH" \
            --sector-size "$DMCRYPT_SECTOR_SIZE" --key-file - "$vault" "$mapper"
}

create_vault() {
    local generation="$1" directory vault metadata stale tmp mapper device mountpoint
    assert_generation "$generation"
    validate_size
    ensure_roots
    directory="$(vault_dir "$generation")"
    vault="$(vault_path "$generation")"
    metadata="$(metadata_path "$generation")"
    mapper="$(mapper_name "$generation")"
    mountpoint="$(mount_path "$generation")"
    if [[ -e "$directory" ]]; then
        # A complete generation is safe to reuse. This is the normal path on
        # an interrupted or repeated Secure Boot stage; creating it again
        # would incorrectly fail with "Generation already exists".
        if [[ -s "$vault" && -s "$metadata" ]]; then
            verify_format_metadata "$generation"
            log "Key vault already exists; reusing: $vault"
            return 0
        fi

        [[ -d "$directory" && ! -L "$directory" ]] ||
            die "Vault generation path is not a protected directory: $directory"

        # Keep durable or ambiguous material for manual recovery. Only an
        # empty/temporary directory left by an interrupted create operation
        # may be quarantined automatically before a fresh creation.
        if find "$directory" -mindepth 1 -maxdepth 1 \
            ! -name '.private-keys.*' -print -quit 2>/dev/null | grep -q .; then
            die "Vault generation exists but is incomplete; inspect before retrying: $directory"
        fi
        stale="${directory}.stale.$(date +%Y%m%d-%H%M%S).$$"
        mv -- "$directory" "$stale" ||
            die "Cannot quarantine incomplete vault generation: $directory"
        log "Quarantined incomplete vault generation: $stale"
    fi
    install -d -m 0700 -o root -g root "$directory"
    tmp="$(mktemp "$directory/.private-keys.XXXXXX")"
    trap 'rm -f -- "${tmp:-}"; mountpoint -q "${mountpoint:-}" && umount "${mountpoint:-}" || true; cryptsetup close "${mapper:-}" >/dev/null 2>&1 || true' EXIT
    chmod 0600 "$tmp"
    dd if=/dev/urandom of="$tmp" bs=1M count="$VAULT_SIZE_MIB" status=none
    generate_vault_passphrase
    printf '%s' "$DMCRYPT_PASSPHRASE" |
        cryptsetup open \
            --type plain \
            --cipher "$DMCRYPT_CIPHER" \
            --key-size "$DMCRYPT_KEY_SIZE" \
            --hash "$DMCRYPT_HASH" \
            --sector-size "$DMCRYPT_SECTOR_SIZE" \
            --key-file - \
            "$tmp" \
            "$mapper"
    unset DMCRYPT_PASSPHRASE
    device="/dev/mapper/$mapper"
    mkfs.ext4 -F -L "STRAZH-${generation#generation-}" "$device" >/dev/null
    install -d -m 0700 -o root -g root "$mountpoint"
    mount -o nodev,nosuid,noexec,noatime "$device" "$mountpoint"
    printf 'strazh-key-vault:%s\n' "$generation" >"$mountpoint/.strazh-key-vault"
    chmod 0600 "$mountpoint/.strazh-key-vault"
    install -d -m 0700 -o root -g root "$mountpoint/uefi" "$mountpoint/gpg"
    sync
    umount "$mountpoint"
    cryptsetup close "$mapper"
    mv -f -- "$tmp" "$vault"
    chmod 0600 "$vault"
    write_format_metadata "$generation"
    trap - EXIT
    log "Created closed plain dm-crypt key vault: $vault"
}

open_vault() {
    local generation="$1" vault mapper device mountpoint passphrase marker
    assert_generation "$generation"
    ensure_roots
    verify_format_metadata "$generation"
    vault="$(vault_path "$generation")"
    mapper="$(mapper_name "$generation")"
    device="/dev/mapper/$mapper"
    mountpoint="$(mount_path "$generation")"
    secure_file "$vault"
    marker="$mountpoint/.strazh-key-vault"
    [[ ! -L "$mountpoint" ]] || die "Runtime mount path is symlinked: $mountpoint"
    if mountpoint -q "$mountpoint" 2>/dev/null; then
        cryptsetup status "$mapper" >/dev/null 2>&1 ||
            die "Unexpected filesystem mounted at: $mountpoint"
        [[ -f "$marker" ]] || die "Vault marker is missing: $marker"
        grep -Fxq "strazh-key-vault:$generation" "$marker" ||
            die 'Vault generation marker mismatch'
        log "Vault already open: $generation"
        return 0
    fi
    install -d -m 0700 -o root -g root "$mountpoint"
    passphrase="$(read_vault_passphrase 'Enter vault passphrase')"
    if ! open_mapping "$vault" "$mapper" "$passphrase"; then
        unset passphrase
        die 'Plain dm-crypt mapping failed; no changes were made'
    fi
    unset passphrase
    trap 'mountpoint -q "${mountpoint:-}" && umount "${mountpoint:-}" || true; cryptsetup close "${mapper:-}" >/dev/null 2>&1 || true' ERR
    mount -o nodev,nosuid,noexec,noatime "$device" "$mountpoint"
    [[ -f "$marker" && ! -L "$marker" ]] || die 'Vault marker is missing; wrong passphrase or wrong container'
    grep -Fxq "strazh-key-vault:$generation" "$marker" || die 'Vault generation marker mismatch'
    trap - ERR
    log "Opened plain dm-crypt key vault at protected runtime path: $mountpoint"
}

close_vault() {
    local generation="$1" mapper mountpoint
    assert_generation "$generation"
    mapper="$(mapper_name "$generation")"
    mountpoint="$(mount_path "$generation")"
    if mountpoint -q "$mountpoint" 2>/dev/null; then
        umount "$mountpoint" || die "Cannot unmount key vault: $mountpoint"
    fi
    if cryptsetup status "$mapper" >/dev/null 2>&1; then
        cryptsetup close "$mapper" || die "Cannot close key vault mapping: $mapper"
    fi
    log "Closed key vault: $generation"
}

assert_open() {
    local generation="$1" mountpoint mapper marker
    assert_generation "$generation"
    mountpoint="$(mount_path "$generation")"
    mapper="$(mapper_name "$generation")"
    marker="$mountpoint/.strazh-key-vault"
    mountpoint -q "$mountpoint" 2>/dev/null || die "Vault is not mounted: $generation"
    cryptsetup status "$mapper" >/dev/null 2>&1 || die "Vault mapping is not open: $generation"
    [[ -f "$marker" && ! -L "$marker" ]] || die "Vault marker is missing: $marker"
    grep -Fxq "strazh-key-vault:$generation" "$marker" ||
        die "Vault generation marker mismatch"
}

link_private_keys() {
    local generation="$1" key source target gpg_home gpg_target
    assert_open "$generation"
    install -d -m 0700 -o root -g root "$(mount_path "$generation")/uefi" "$(private_gpg_path "$generation")"

    for key in PK KEK db; do
        source="$KEY_ROOT/$key.key"
        target="$(private_uefi_path "$generation" "$key")"
        [[ -s "$target" ]] || die "Private key is missing in the open vault: $target"
        if [[ -L "$source" ]]; then
            [[ "$(readlink "$source")" == "$target" ]] ||
                die "Private key link points outside the vault: $source"
        elif [[ -e "$source" ]]; then
            die "Unvaulted private key exists: $source; migrate it before linking"
        else
            ln -s "$target" "$source"
        fi
    done

    gpg_home="$STATE_ROOT/gpg"
    gpg_target="$(private_gpg_path "$generation")"
    if [[ -L "$gpg_home" ]]; then
        [[ "$(readlink "$gpg_home")" == "$gpg_target" ]] ||
            die "GPG home link points outside the vault: $gpg_home"
    elif [[ -e "$gpg_home" ]]; then
        find "$gpg_home" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q . &&
            die "Unvaulted GPG home is not empty: $gpg_home"
        rmdir "$gpg_home" || die "Cannot replace empty GPG home: $gpg_home"
        ln -s "$gpg_target" "$gpg_home"
    else
        ln -s "$gpg_target" "$gpg_home"
    fi
    log "Private-key paths linked to open vault: $generation"
}

unlink_private_keys() {
    local generation="$1" key source target gpg_home gpg_target
    require_root
    assert_generation "$generation"
    for key in PK KEK db; do
        source="$KEY_ROOT/$key.key"
        target="$(private_uefi_path "$generation" "$key")"
        if [[ -L "$source" ]]; then
            [[ "$(readlink "$source")" == "$target" ]] ||
                die "Refusing to remove private-key link outside the vault: $source"
            rm -f -- "$source"
        fi
    done
    gpg_home="$STATE_ROOT/gpg"
    gpg_target="$(private_gpg_path "$generation")"
    if [[ -L "$gpg_home" ]]; then
        [[ "$(readlink "$gpg_home")" == "$gpg_target" ]] ||
            die "Refusing to remove GPG link outside the vault: $gpg_home"
        rm -f -- "$gpg_home"
    fi
    log "Private-key paths unlinked from vault: $generation"
}

confirm_migration() {
    local answer
    require_tty
    printf 'Move existing private signing material into the open vault and remove the unvaulted copies? [y/n] ' >/dev/tty
    IFS= read -r answer </dev/tty || die 'Could not read migration confirmation'
    case "$answer" in
    y | Y | yes | YES) ;;
    *) die 'Migration cancelled; unvaulted private keys were not changed' ;;
    esac
}

migrate_existing() {
    local generation="$1" source target key gpg_home gpg_target found=0 tmp
    assert_open "$generation"
    for key in PK KEK db; do
        source="$KEY_ROOT/$key.key"
        [[ -f "$source" && ! -L "$source" ]] || continue
        found=1
    done
    gpg_home="$STATE_ROOT/gpg"
    if [[ -d "$gpg_home" && ! -L "$gpg_home" ]] &&
        find "$gpg_home" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then
        found=1
    fi
    ((found == 1)) || return 0

    confirm_migration
    for key in PK KEK db; do
        source="$KEY_ROOT/$key.key"
        [[ -f "$source" && ! -L "$source" ]] || continue
        target="$(private_uefi_path "$generation" "$key")"
        [[ ! -e "$target" ]] || die "Vault target already exists: $target"
        tmp="$(mktemp "${target}.XXXXXX")"
        install -m 0600 -o root -g root "$source" "$tmp"
        cmp -s "$source" "$tmp" || die "Private key copy verification failed: $key"
        mv -f -- "$tmp" "$target"
        shred -u -- "$source" || die "Could not remove unvaulted private key: $source"
    done

    if [[ -d "$gpg_home" && ! -L "$gpg_home" ]]; then
        gpg_target="$(private_gpg_path "$generation")"
        find "$gpg_target" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q . &&
            die "Vault GPG directory is not empty: $gpg_target"
        cp -a -- "$gpg_home/." "$gpg_target/"
        find "$gpg_home" -type f -exec shred -u -- {} +
        rm -rf -- "$gpg_home"
    fi
    log 'Migrated existing private signing material into the key vault'
}

status_vault() {
    local generation="$1" vault mapper mountpoint
    assert_generation "$generation"
    vault="$(vault_path "$generation")"
    mapper="$(mapper_name "$generation")"
    mountpoint="$(mount_path "$generation")"
    printf 'generation=%s\n' "$generation"
    printf 'vault=%s\n' "$vault"
    printf 'format=plain-dmcrypt\n'
    if [[ -f "$vault" ]]; then
        secure_file "$vault"
        printf 'container=present\n'
    else
        printf 'container=missing\n'
    fi
    if cryptsetup status "$mapper" >/dev/null 2>&1; then
        printf 'mapping=open\n'
    else
        printf 'mapping=closed\n'
    fi
    if mountpoint -q "$mountpoint" 2>/dev/null; then
        printf 'mounted=yes\n'
    else
        printf 'mounted=no\n'
    fi
}

usage() {
    cat <<'USAGE'
Usage: strazh-key-vault <create|open|close|migrate|link|unlink|status> generation-N

The vault is a plain dm-crypt container. Its passphrase is never printed or
accepted as a command-line argument. The mapping is opened only for a manual
signing or recovery operation and must be closed afterwards.
USAGE
}

main() {
    local command="${1:-}" generation="${2:-}"
    require_root
    need cryptsetup
    need install
    need mount
    need mountpoint
    need stat
    need umount
    need dd
    need mkfs.ext4
    need openssl
    need ln
    need find
    need readlink
    need rmdir
    need cmp
    need cp
    need shred
    case "$command" in
    create | open | close | migrate | link | unlink | status)
        [[ -n "$generation" ]] || die 'Missing generation (for example generation-1)'
        ;;
    -h | --help | '')
        usage
        return 0
        ;;
    *) die "Unknown command: $command" ;;
    esac
    case "$command" in
    create) create_vault "$generation" ;;
    open) open_vault "$generation" ;;
    close) close_vault "$generation" ;;
    migrate) migrate_existing "$generation" ;;
    link) link_private_keys "$generation" ;;
    unlink) unlink_private_keys "$generation" ;;
    status) status_vault "$generation" ;;
    esac
}

trap 'exit 130' INT TERM
main "$@"
