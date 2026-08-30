#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 m0nokey
# Private implementation invoked by the public ../run.sh entry point.
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

if [[ -n "${PROJECT_ROOT:-}" ]]; then
    PROJECT_ROOT="$(cd -- "$PROJECT_ROOT" && pwd -P)"
elif [[ -n "${BASH_SOURCE[0]:-}" ]]; then
    PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
else
    printf '%s\n' 'ERROR: PROJECT_ROOT must be set when sb_guard_install.sh is read from stdin' >&2
    exit 1
fi

# ==============================================================================
# Paths
# ==============================================================================
CORE_DST="/usr/local/sbin/sb-guard"
SB_INSTALL_DST="/usr/local/sbin/sb-install"
SVC_DST="/usr/local/sbin/sb-guard-svc"
WORKER_DST="/usr/local/sbin/sb-guard-worker"
ROLLBACK_DST="/usr/local/sbin/sb-guard-rollback"

SHIM_REBUILD_DST="/usr/local/sbin/sb-shim-rebuild"
SHIM_AUTO_BUILD_DST="/usr/local/sbin/sb-shim-auto-build"
BUILD_ROOT_HELPER_DST="/usr/local/sbin/sb-build-root"

# Isolated GRUB build profile. The profile contains a reproducibly built
# grub-mkstandalone plus its matching x86_64-efi modules. Its metadata records
# the exact Proxmox source commit/tree hash and installed package version. The
# stage-03 orchestrator activates it only after a complete independent build;
# packaged mode exists solely for install-only migration/recovery.
GRUB_BUILD_POLICY="/etc/sb-guard/grub-build.env"

APT_HOOK_SHIM="/etc/apt/apt.conf.d/89sb-shim-rebuild"
APT_HOOK_GUARD="/etc/apt/apt.conf.d/90sb-guard-after-apt"
APT_CUSTOM_DB_POLICY="/etc/apt/preferences.d/99sb-guard-custom-db"
LEGACY_APT_HOOK="/etc/apt/apt.conf.d/99-sb-maintain"

EVENT_DST="/usr/local/sbin/sb-guard-event"

SYSTEMD_SERVICE="/etc/systemd/system/sb-guard.service"
SYSTEMD_TIMER="/etc/systemd/system/sb-guard.timer"
SYSTEMD_PATH="/etc/systemd/system/sb-guard.path"

LOG_FILE="/var/log/sb-guard.log"
# ==============================================================================
# Helpers
# ==============================================================================
die() {
    echo "ERROR: $*" >&2
    exit 1
}

ok() {
    echo "OK: $*"
}

have_cmd() {
    command -v "$1" >/dev/null 2>&1
}

require_root() {
    [[ "$(id -u)" -eq 0 ]] || die "Run as root"
}

indent() {
    # Remove only the indentation added around generated files in this source.
    # The installed scripts remain self-contained, so this helper is embedded
    # here rather than sourced from the clone after installation.
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

# ==============================================================================
# Install: sb-install (init helper)
# ==============================================================================
install_sb_install() {
    cat <<'EOF' | indent -4 | install -D -m 0750 -o root -g root /dev/stdin "$SB_INSTALL_DST"
    #!/bin/bash
    set -Eeuo pipefail
    IFS=$'\n\t'
    umask 077

    ESP_MNT="${ESP_MNT:-/boot/efi}"

    STATE_ROOT="${STATE_ROOT:-/var/lib/sb-guard}"
    KEY_DIR="${KEY_DIR:-$STATE_ROOT/keys}"
    PIN_DIR="${PIN_DIR:-$STATE_ROOT/pins}"

    ESP_SB_DIR="${ESP_SB_DIR:-$ESP_MNT/EFI/SB}"
    ESP_ENROLL_DIR="${ESP_ENROLL_DIR:-$ESP_SB_DIR/ENROLL}"

    GPG_HOME="${GPG_HOME:-$STATE_ROOT/gpg}"
    GPG_FPR_FILE="${GPG_FPR_FILE:-$GPG_HOME/key.fpr}"

    GRUB_KEYS_DIR="${GRUB_KEYS_DIR:-/boot/grub/keys}"
    GRUB_GPG_KEY_FILE="${GRUB_GPG_KEY_FILE:-$GRUB_KEYS_DIR/sb-guard.gpg}"
    GRUB_GPG_BACKUP_FILE="${GRUB_GPG_BACKUP_FILE:-$STATE_ROOT/keys/grub/sb-guard.gpg}"

    mode="help"
    force=0
    trace=0
    apt_updated=0

    ts() { date '+%F %T'; }
    log() { printf '[%s] %s\n' "$(ts)" "$*" >&2; }
    ok() { log "OK:   $*"; }
    warn() { log "WARN: $*"; }
    die() { log "FAIL: $*"; exit 1; }

    run() {
        if [[ "$trace" == "1" ]]; then
            log "CMD: $(printf '%q ' "$@")"
        fi
        "$@"
    }

    ensure_root() {
        [[ "$(id -u)" == "0" ]] || die "Run as root"
    }

    have_cmd() {
        command -v "$1" >/dev/null 2>&1
    }

    apt_maybe_update() {
        if [[ "$apt_updated" -eq 0 ]]; then
            DEBIAN_FRONTEND=noninteractive run apt-get update >/dev/null
            apt_updated=1
        fi
    }

    apt_install() {
        local pkg="$1"
        ensure_root
        have_cmd apt-get || die "apt-get not found. Install package: $pkg"
        apt_maybe_update
        warn "Installing dependency package: $pkg"
        DEBIAN_FRONTEND=noninteractive run apt-get \
            -o DPkg::Pre-Invoke::= \
            -o DPkg::Post-Invoke::= \
            -o DPkg::Post-Invoke-Success::= \
            -o APT::Update::Post-Invoke::= \
            -o APT::Update::Post-Invoke-Success::= \
            install -y "$pkg" >/dev/null
    }

    need() {
        local cmd="$1"
        if have_cmd "$cmd"; then
            return 0
        fi

        case "$cmd" in
            cert-to-efi-sig-list|sign-efi-sig-list)
                apt_install efitools
                ;;
            uuidgen)
                apt_install uuid-runtime
                ;;
            gpg)
                apt_install gnupg
                ;;
            openssl)
                apt_install openssl
                ;;
            findmnt|lsblk|mount|umount)
                apt_install util-linux
                ;;
            awk|sed|grep)
                apt_install mawk
                apt_install sed
                apt_install grep
                ;;
            *)
                die "Missing command: $cmd"
                ;;
        esac

        have_cmd "$cmd" || die "Missing command after install attempt: $cmd"
    }

    ensure_state_dirs() {
        run install -d -m 0700 -o root -g root "$STATE_ROOT" "$KEY_DIR" "$PIN_DIR"
        run install -d -m 0700 -o root -g root "$STATE_ROOT/keys/grub"
        run install -d -m 0700 -o root -g root "$GPG_HOME"
    }

    findmnt_opts() { findmnt -nro OPTIONS "$1" 2>/dev/null || true; }

    mnt_is_ro() {
        case ",$(findmnt_opts "$1")," in
            *",ro,"*) return 0 ;;
            *) return 1 ;;
        esac
    }

    remount_rw() {
        if mnt_is_ro "$ESP_MNT"; then
            run mount -o remount,rw "$ESP_MNT"
        fi
    }

    remount_ro() {
        if ! mnt_is_ro "$ESP_MNT"; then
            run mount -o remount,ro "$ESP_MNT"
        fi
    }

    ensure_esp_mounted() {
        need findmnt

        if ! findmnt -n "$ESP_MNT" >/dev/null 2>&1; then
            die "ESP not mounted at $ESP_MNT"
        fi

        local fstype
        fstype="$(findmnt -T "$ESP_MNT" -nro FSTYPE 2>/dev/null | sed '/^$/d;1q' || true)"
        if [[ "$fstype" != "vfat" ]]; then
            die "$ESP_MNT is not vfat (got: ${fstype:-empty})"
        fi

        if [[ ! -d "$ESP_MNT/EFI" ]]; then
            die "No $ESP_MNT/EFI directory"
        fi
    }

    find_keytool() {
        local candidates=(
            "/usr/lib/efitools/x86_64-linux-gnu/KeyTool.efi"
            "/usr/lib/efitools/*/KeyTool.efi"
            "/usr/share/efitools/*/KeyTool.efi"
            "/usr/lib/efitools/KeyTool.efi"
            "/usr/share/efitools/KeyTool.efi"
        )

        local p fp
        for p in "${candidates[@]}"; do
            for fp in $p; do
                if [[ -f "$fp" ]]; then
                    printf '%s\n' "$fp"
                    return 0
                fi
            done
        done

        p="$(find /usr -type f -iname 'KeyTool.efi' 2>/dev/null | head -n1 || true)"
        [[ -n "$p" && -f "$p" ]] && { printf '%s\n' "$p"; return 0; }

        return 1
    }

    copy_enrollment_to_esp() {
        log "Copying enrollment files to ESP: ${ESP_ENROLL_DIR}"
        run install -d -m 0700 -o root -g root "$ESP_SB_DIR" "$ESP_ENROLL_DIR"

        # OVMF's file picker accepts DER certificates only.  The canonical
        # *.crt files remain PEM for OpenSSL/sb-guard, while the *.cer files
        # are generated as separate public enrollment artifacts.
        local cert der fmt tmp
        for cert in PK KEK db; do
            for fmt in cer der; do
                der="$KEY_DIR/${cert}.${fmt}"
                tmp="$(mktemp -p "$KEY_DIR" ".${cert}.${fmt}.XXXXXX")" ||
                    die "Cannot create temporary DER certificate for ${cert}.${fmt}"
                if ! openssl x509 -in "$KEY_DIR/${cert}.crt" -outform DER \
                    -out "$tmp" >/dev/null 2>&1; then
                    rm -f -- "$tmp"
                    die "Cannot convert ${cert}.crt to DER"
                fi
                run chmod 0600 "$tmp"
                run mv -f -- "$tmp" "$der"
            done
        done

        run cp -f \
            "${KEY_DIR}/PK.auth"  "${KEY_DIR}/PK.esl"  "${KEY_DIR}/PK.crt" "${KEY_DIR}/PK.cer" "${KEY_DIR}/PK.der" \
            "${KEY_DIR}/KEK.auth" "${KEY_DIR}/KEK.esl" "${KEY_DIR}/KEK.crt" "${KEY_DIR}/KEK.cer" "${KEY_DIR}/KEK.der" \
            "${KEY_DIR}/db.auth"  "${KEY_DIR}/db.esl"  "${KEY_DIR}/db.crt"  "${KEY_DIR}/db.cer"  "${KEY_DIR}/db.der" \
            "$ESP_ENROLL_DIR/"

        local kt=""
        kt="$(find_keytool || true)"
        if [[ -z "$kt" || ! -f "$kt" ]]; then
            warn "KeyTool.efi not found -> installing efitools"
            apt_install efitools
            kt="$(find_keytool || true)"
        fi
        [[ -n "$kt" && -f "$kt" ]] || die "KeyTool.efi not found"

        run cp -f "$kt" "${ESP_SB_DIR}/KeyTool.efi"
        run sync
    }

    openssl_make_keypair() {
        local cn="$1"
        local key="$2"
        local crt="$3"

        run openssl req -new -x509 -newkey rsa:4096 -nodes -sha256 \
            -subj "/CN=${cn}/" \
            -keyout "$key" -out "$crt" -days 3650 >/dev/null 2>&1

        run chmod 0600 "$key" "$crt"
    }

    uefi_cert_policy_ok() {
        local crt="$1"
        [[ -s "$crt" ]] || return 1

        if ! openssl x509 -in "$crt" -noout -text 2>/dev/null \
            | grep -q 'Public-Key: (4096 bit)'; then
            return 1
        fi

        local sigalg=""
        sigalg="$(
            openssl x509 -in "$crt" -noout -text 2>/dev/null \
            | sed -n 's/^[[:space:]]*Signature Algorithm:[[:space:]]*//p' \
            | sed '/^$/d;1q'
        )"
        [[ "$sigalg" == "sha256WithRSAEncryption" ]]
    }

    uefi_keys_policy_ok() {
        uefi_cert_policy_ok "$KEY_DIR/PK.crt"  || return 1
        uefi_cert_policy_ok "$KEY_DIR/KEK.crt" || return 1
        uefi_cert_policy_ok "$KEY_DIR/db.crt"  || return 1
        return 0
    }

    owner_guid_file() {
        printf '%s\n' "$KEY_DIR/owner_guid"
    }

    ensure_owner_guid() {
        local f
        f="$(owner_guid_file)"

        if [[ -s "$f" ]]; then
            cat "$f"
            return 0
        fi

        local g=""
        if command -v uuidgen >/dev/null 2>&1; then
            g="$(uuidgen 2>/dev/null || true)"
        elif [[ -r /proc/sys/kernel/random/uuid ]]; then
            g="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || true)"
        fi

        if [[ ! "$g" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
            die "Failed to generate GUID"
        fi

        printf '%s\n' "$g" >"$f"
        run chmod 0600 "$f"
        printf '%s\n' "$g"
    }

    make_esl() {
        local crt="$1"
        local esl="$2"
        local guid="$3"

        run cert-to-efi-sig-list -g "$guid" "$crt" "$esl" >/dev/null 2>&1
        run chmod 0600 "$esl"
    }

    make_auth() {
        local var="$1"
        local esl="$2"
        local auth="$3"
        local guid="$4"
        local sign_key="$5"
        local sign_crt="$6"

        run sign-efi-sig-list -g "$guid" -k "$sign_key" -c "$sign_crt" "$var" "$esl" "$auth" >/dev/null 2>&1
        run chmod 0600 "$auth"
    }

    uefi_keys_complete() {
        local pk_key pk_crt pk_esl pk_auth
        local kek_key kek_crt kek_esl kek_auth
        local db_key db_crt db_esl db_auth

        pk_key="$KEY_DIR/PK.key";   pk_crt="$KEY_DIR/PK.crt";   pk_esl="$KEY_DIR/PK.esl";   pk_auth="$KEY_DIR/PK.auth"
        kek_key="$KEY_DIR/KEK.key"; kek_crt="$KEY_DIR/KEK.crt"; kek_esl="$KEY_DIR/KEK.esl"; kek_auth="$KEY_DIR/KEK.auth"
        db_key="$KEY_DIR/db.key";   db_crt="$KEY_DIR/db.crt";   db_esl="$KEY_DIR/db.esl";   db_auth="$KEY_DIR/db.auth"

        [[ -s "$pk_key" && -s "$pk_crt" && -s "$pk_esl" && -s "$pk_auth" ]] || return 1
        [[ -s "$kek_key" && -s "$kek_crt" && -s "$kek_esl" && -s "$kek_auth" ]] || return 1
        [[ -s "$db_key" && -s "$db_crt" && -s "$db_esl" && -s "$db_auth" ]] || return 1
        return 0
    }

    uefi_keys_any_present() {
        local f
        for f in \
            "$KEY_DIR/PK.key" "$KEY_DIR/PK.crt" "$KEY_DIR/PK.esl" "$KEY_DIR/PK.auth" \
            "$KEY_DIR/KEK.key" "$KEY_DIR/KEK.crt" "$KEY_DIR/KEK.esl" "$KEY_DIR/KEK.auth" \
            "$KEY_DIR/db.key" "$KEY_DIR/db.crt" "$KEY_DIR/db.esl" "$KEY_DIR/db.auth"
        do
            if [[ -e "$f" ]]; then
                return 0
            fi
        done
        return 1
    }

    init_uefi_keys() {
        log "=== INIT BEGIN (uefi-keys) ==="
        ensure_root
        ensure_state_dirs

        need openssl
        need cert-to-efi-sig-list
        need sign-efi-sig-list
        need findmnt
        need mount
        need sync
        need install
        need cp
        need mktemp
        need mv
        need hostname
        need rm
        need sed
        need grep

        if [[ "$force" -ne 1 ]]; then
            if uefi_keys_complete; then
                if ! uefi_keys_policy_ok; then
                    die "UEFI keys exist but do not match policy (RSA4096+SHA256). Use --force."
                fi

                ok "UEFI keys present and match policy; refreshing enrollment bundle"
                ensure_esp_mounted
                remount_rw
                trap 'remount_ro || true' EXIT
                copy_enrollment_to_esp
                remount_ro
                trap - EXIT
                log "=== INIT DONE (uefi-keys) ==="
                return 0
            fi

            if uefi_keys_any_present; then
                die "UEFI keys partially present; refusing without --force"
            fi
        else
            warn "FORCE enabled: overwriting UEFI keys"
            run rm -f -- \
                "$KEY_DIR/PK.key" "$KEY_DIR/PK.crt" "$KEY_DIR/PK.esl" "$KEY_DIR/PK.auth" \
                "$KEY_DIR/KEK.key" "$KEY_DIR/KEK.crt" "$KEY_DIR/KEK.esl" "$KEY_DIR/KEK.auth" \
                "$KEY_DIR/db.key" "$KEY_DIR/db.crt" "$KEY_DIR/db.esl" "$KEY_DIR/db.auth" \
                "$KEY_DIR/owner_guid" || true
        fi

        local pk_key pk_crt pk_esl pk_auth
        local kek_key kek_crt kek_esl kek_auth
        local db_key db_crt db_esl db_auth

        pk_key="$KEY_DIR/PK.key";   pk_crt="$KEY_DIR/PK.crt";   pk_esl="$KEY_DIR/PK.esl";   pk_auth="$KEY_DIR/PK.auth"
        kek_key="$KEY_DIR/KEK.key"; kek_crt="$KEY_DIR/KEK.crt"; kek_esl="$KEY_DIR/KEK.esl"; kek_auth="$KEY_DIR/KEK.auth"
        db_key="$KEY_DIR/db.key";   db_crt="$KEY_DIR/db.crt";   db_esl="$KEY_DIR/db.esl";   db_auth="$KEY_DIR/db.auth"

        local host guid
        host="$(hostname -s 2>/dev/null || hostname || echo sbhost)"
        guid="$(ensure_owner_guid)"

        openssl_make_keypair "sb-guard PK (${host})"  "$pk_key"  "$pk_crt"
        openssl_make_keypair "sb-guard KEK (${host})" "$kek_key" "$kek_crt"
        openssl_make_keypair "sb-guard db (${host})"  "$db_key"  "$db_crt"

        if ! uefi_keys_policy_ok; then
            die "Generated UEFI certs do not match expected policy"
        fi

        make_esl "$pk_crt"  "$pk_esl"  "$guid"
        make_esl "$kek_crt" "$kek_esl" "$guid"
        make_esl "$db_crt"  "$db_esl"  "$guid"

        make_auth "PK"  "$pk_esl"  "$pk_auth"  "$guid" "$pk_key"  "$pk_crt"
        make_auth "KEK" "$kek_esl" "$kek_auth" "$guid" "$pk_key"  "$pk_crt"
        make_auth "db"  "$db_esl"  "$db_auth"  "$guid" "$kek_key" "$kek_crt"

        ok "UEFI keys generated in $KEY_DIR (guid=$guid)"

        ensure_esp_mounted
        remount_rw
        trap 'remount_ro || true' EXIT
        copy_enrollment_to_esp
        remount_ro
        trap - EXIT

        ok "Enrollment bundle refreshed on ESP: $ESP_ENROLL_DIR"
        log "=== INIT DONE (uefi-keys) ==="
    }

    export_gpg_pubkey() {
        local fpr="$1"

        run install -d -m 0700 -o root -g root "$GRUB_KEYS_DIR"
        run install -d -m 0700 -o root -g root "$(dirname "$GRUB_GPG_BACKUP_FILE")"

        local tmp
        tmp="$(mktemp)"
        run gpg --homedir "$GPG_HOME" --batch --yes --export "$fpr" >"$tmp"

        run install -m 0600 -o root -g root "$tmp" "$GRUB_GPG_KEY_FILE"
        ok "Exported GRUB public key: $GRUB_GPG_KEY_FILE"

        run install -m 0600 -o root -g root "$tmp" "$GRUB_GPG_BACKUP_FILE"
        ok "Saved GRUB public key backup: $GRUB_GPG_BACKUP_FILE"

        rm -f -- "$tmp"
    }

    gpg_find_existing_fpr() {
        local fpr=""
        fpr="$(gpg --homedir "$GPG_HOME" --list-secret-keys --with-colons 2>/dev/null \
            | sed -n 's/^fpr:::::::::\([0-9A-F]\{40\}\):.*/\1/p' \
            | sed '/^$/d;1q' || true)"
        [[ -n "$fpr" ]] || return 1
        printf '%s\n' "$fpr"
        return 0
    }

    gpg_key_policy_ok() {
        local line=""
        line="$(
            gpg --homedir "$GPG_HOME" --batch --with-colons --list-secret-keys 2>/dev/null \
            | awk -F: '$1=="sec"{print $3 ":" $4 ":" $12; exit}'
        )"
        [[ -n "$line" ]] || return 1

        local bits algo caps
        IFS=':' read -r bits algo caps <<<"$line"

        [[ "$bits" == "4096" ]] || return 1
        [[ "$algo" == "1" ]] || return 1
        [[ "${caps:-}" == *s* ]] || return 1
        return 0
    }

    gpg_wipe_and_recreate_home() {
        warn "FORCE enabled: wiping GPG home: $GPG_HOME"
        run rm -rf -- "$GPG_HOME"
        run install -d -m 0700 -o root -g root "$GPG_HOME"
        run rm -f -- "$GPG_FPR_FILE"
    }

    init_gpg_keys() {
        log "=== INIT BEGIN (gpg-keys) ==="
        ensure_root
        ensure_state_dirs

        need gpg
        need install
        need grep
        need hostname
        need sed
        need rm
        need awk

        local fpr=""

        if [[ -s "$GPG_FPR_FILE" ]]; then
            fpr="$(cat "$GPG_FPR_FILE" || true)"
            if [[ -n "$fpr" ]] && gpg --homedir "$GPG_HOME" --list-secret-keys --with-colons "$fpr" 2>/dev/null | grep -q '^sec:'; then
                if ! gpg_key_policy_ok; then
                    if [[ "$force" -eq 1 ]]; then
                        gpg_wipe_and_recreate_home
                    else
                        die "GPG key exists but policy mismatch (RSA4096 signing). Use --force."
                    fi
                else
                    ok "GPG key present and matches policy (fpr=$fpr)"
                    export_gpg_pubkey "$fpr"
                    log "=== INIT DONE (gpg-keys) ==="
                    return 0
                fi
            fi
        fi

        fpr="$(gpg_find_existing_fpr || true)"
        if [[ -n "$fpr" ]] && gpg --homedir "$GPG_HOME" --list-secret-keys --with-colons "$fpr" 2>/dev/null | grep -q '^sec:'; then
            if ! gpg_key_policy_ok; then
                if [[ "$force" -eq 1 ]]; then
                    gpg_wipe_and_recreate_home
                else
                    die "GPG secret key exists but policy mismatch. Use --force."
                fi
            else
                warn "Recovered existing GPG key fpr=$fpr"
                printf '%s\n' "$fpr" >"$GPG_FPR_FILE"
                run chmod 0600 "$GPG_FPR_FILE"
                export_gpg_pubkey "$fpr"
                log "=== INIT DONE (gpg-keys) ==="
                return 0
            fi
        fi

        local host uid
        host="$(hostname -s 2>/dev/null || hostname || echo sbhost)"
        uid="sb-guard boot signing (${host})"

        warn "Generating GPG key (rsa4096, no passphrase): $uid"
        run gpg --homedir "$GPG_HOME" --batch --yes \
            --pinentry-mode loopback --passphrase '' \
            --quick-gen-key "$uid" rsa4096 sign 0 >/dev/null 2>&1

        fpr="$(gpg_find_existing_fpr || true)"
        [[ -n "$fpr" ]] || die "Failed to obtain GPG fingerprint after generation"

        if ! gpg_key_policy_ok; then
            die "Generated GPG key policy mismatch"
        fi

        printf '%s\n' "$fpr" >"$GPG_FPR_FILE"
        run chmod 0600 "$GPG_FPR_FILE"
        ok "GPG key generated (fpr=$fpr)"

        export_gpg_pubkey "$fpr"
        log "=== INIT DONE (gpg-keys) ==="
    }

    usage() {
        cat <<'USAGE'
    Usage: sb-install [options] <command>

    Commands:
        --init-uefi-keys      Generate/reuse UEFI PK/KEK/db (RSA4096+SHA256), ESL/AUTH, export to ESP + KeyTool.efi
        --init-gpg-keys       Generate/reuse GPG signing key (rsa4096, no passphrase), export pubkey to /boot/grub/keys + backup

    Options:
        --force               Overwrite/rotate keys
        --trace               Print executed commands
        -h|--help             Show help
USAGE
    }

    main() {
        ensure_root
        need install
        need rm

        while (( $# > 0 )); do
            case "$1" in
                --init-uefi-keys) mode="init-uefi" ;;
                --init-gpg-keys)  mode="init-gpg" ;;
                --force)          force=1 ;;
                --trace)          trace=1 ;;
                -h|--help)        mode="help" ;;
                *) die "Unknown arg: $1" ;;
            esac
            shift
        done

        case "$mode" in
            init-uefi) init_uefi_keys ;;
            init-gpg)  init_gpg_keys ;;
            help|*) usage; exit 0 ;;
        esac
    }

    main "$@"
EOF
    ok "installed sb-install -> $SB_INSTALL_DST"
}

# ==============================================================================
# Install: sb-shim-rebuild (autonomous rebuild + logs + cleanup)
# ==============================================================================
install_shim_rebuild() {
    cat <<'EOF' | indent -4 | install -D -m 0750 -o root -g root /dev/stdin "$SHIM_REBUILD_DST"
    #!/usr/bin/env bash
    set -Eeuo pipefail
    IFS=$'\n\t'
    umask 077

    STATE_ROOT="${STATE_ROOT:-/var/lib/sb-guard}"
    KEY_DIR="${KEY_DIR:-$STATE_ROOT/keys}"
    DB_CRT="${DB_CRT:-$KEY_DIR/db.crt}"
    DB_KEY="${DB_KEY:-$KEY_DIR/db.key}"

    GOLDEN_DIR="${GOLDEN_DIR:-$STATE_ROOT/golden}"
    GOLDEN_SHIM="${GOLDEN_SHIM:-$GOLDEN_DIR/shimx64.efi}"
    STATE_FILE="${STATE_FILE:-$GOLDEN_DIR/shim.state}"
    UNSIGNED_SHIM="${UNSIGNED_SHIM:-/usr/lib/shim/shimx64.efi}"
    # The normal lifecycle is custom-only: the installed shim-unsigned binary
    # supplies the version/hash signal, while the matching official source is
    # rebuilt to replace .vendor_cert before our Authenticode signature is
    # applied.  Direct package-only mode is deliberately not permitted.
    SHIM_SOURCE_MODE="${SHIM_SOURCE_MODE:-custom}"
    CUSTOM_SHIM_ARTIFACT="${CUSTOM_SHIM_ARTIFACT:-$STATE_ROOT/custom-shim/shimx64.efi}"
    CUSTOM_SHIM_STATE="${CUSTOM_SHIM_STATE:-$STATE_ROOT/custom-shim/shim.state}"

    BACKUP_DIR="${BACKUP_DIR:-$STATE_ROOT/backups}"
    LOG_DIR="${LOG_DIR:-/var/log/sb-guard/shim-rebuild}"

    WORK_PARENT="${WORK_PARENT:-/tmp}"
    RUN_DIR=""
    RC=0
    UNSIGNED_SHA256=""
    SIGNED_SHA256=""
    DB_FINGERPRINT=""

    LOCK_FILE="${LOCK_FILE:-/run/sb-guard.lock}"

    KEEP_SUCCESS_RUNS="${KEEP_SUCCESS_RUNS:-3}"
    KEEP_FAILED_RUNS="${KEEP_FAILED_RUNS:-2}"
    MAX_AGE_DAYS="${MAX_AGE_DAYS:-14}"

    mode="maybe"
    force=0
    trace=0

    ts() { date '+%F %T'; }
    log() { printf '[%s] %s\n' "$(ts)" "$*" >&2; }
    ok() { log "OK:   $*"; }
    warn() { log "WARN: $*"; }
    die() { log "FAIL: $*"; exit 1; }

    run() {
        if [[ "$trace" -eq 1 ]]; then
            log "CMD: $(printf '%q ' "$@")"
        fi
        "$@"
    }

    require_root() {
        [[ "$(id -u)" -eq 0 ]] || die "Run as root"
    }

    have_cmd() {
        command -v "$1" >/dev/null 2>&1
    }

    need_cmd() {
        local c="$1"
        have_cmd "$c" || die "Missing command: $c (dependencies must be installed outside reconcile)"
    }

    ensure_prereqs() {
        need_cmd dpkg-query
        need_cmd openssl
        need_cmd sbsign
        need_cmd sbverify
        need_cmd sbattach
        need_cmd sha256sum
        need_cmd find
        need_cmd sort
        need_cmd awk
        need_cmd sed
        need_cmd grep
        need_cmd head
        need_cmd xargs
        need_cmd rm
        need_cmd mv
        need_cmd cp
        need_cmd install
        need_cmd sync
        need_cmd flock
        need_cmd stat
        need_cmd strings
        need_cmd objcopy
        need_cmd dd
        need_cmd cmp
    }

    ensure_dirs() {
        run install -d -m 0700 -o root -g root "$STATE_ROOT" "$GOLDEN_DIR" "$BACKUP_DIR"
        run install -d -m 0750 -o root -g root "$LOG_DIR"
    }

    lock_or_exit() {
        [[ "${SB_GUARD_LOCK_HELD:-0}" == "1" ]] && return 0
        exec 9>"$LOCK_FILE"
        flock -w 300 9 || die "Timed out waiting for sb-guard reconcile lock"
    }

    new_run_dir() {
        RUN_DIR="$(mktemp -d -p "$WORK_PARENT" build_shim_XXXXXX)"
        run chmod 0700 "$RUN_DIR"
        run install -d -m 0700 -o root -g root "$RUN_DIR/logs"
        {
            echo "ts=$(ts)"
            echo "host=$(hostname -f 2>/dev/null || hostname || true)"
            echo "uname=$(uname -a 2>/dev/null || true)"
        } >"$RUN_DIR/meta.txt"
        log "RUN_DIR=$RUN_DIR"
    }

    persist_logs() {
        local stamp dst
        stamp="$(date +%F-%H%M%S)"
        dst="$LOG_DIR/run-$stamp-rc${RC}"
        run install -d -m 0750 -o root -g root "$dst"

        [[ -f "$RUN_DIR/meta.txt" ]] && cp -a "$RUN_DIR/meta.txt" "$dst/" 2>/dev/null || true
        [[ -d "$RUN_DIR/logs" ]] && cp -a "$RUN_DIR/logs/." "$dst/" 2>/dev/null || true
        [[ -f "$RUN_DIR/build.log" ]] && cp -a "$RUN_DIR/build.log" "$dst/" 2>/dev/null || true

        if [[ -f "$RUN_DIR/shimx64.efi" ]]; then
            (sha256sum "$RUN_DIR/shimx64.efi" 2>/dev/null || true) >"$dst/shimx64.efi.sha256" || true
            (stat -c '%s' "$RUN_DIR/shimx64.efi" 2>/dev/null || true) >"$dst/shimx64.efi.size" || true
            (sbverify --list "$RUN_DIR/shimx64.efi" 2>/dev/null || true) >"$dst/shimx64.efi.sblist" || true
        fi

        log "Logs: $dst"
    }

    cleanup() {
        RC=$?
        set +e
        if [[ -n "${RUN_DIR:-}" && -d "$RUN_DIR" ]]; then
            persist_logs || true
            rm -rf --one-file-system "$RUN_DIR" 2>/dev/null || rm -rf "$RUN_DIR" 2>/dev/null || true
        fi
        exit "$RC"
    }

    trap cleanup EXIT INT TERM

    db_fingerprint() {
        openssl x509 -in "$DB_CRT" -noout -fingerprint -sha256 | sed 's/^sha256 Fingerprint=//'
    }

    get_target_shim_version() {
        dpkg-query -W -f='${Version}\n' shim-unsigned 2>/dev/null | sed '/^$/d;1q' || true
    }

    state_get() {
        local key="$1"
        [[ -s "$STATE_FILE" ]] || return 0
        sed -n "s/^${key}=//p" "$STATE_FILE" | sed '/^$/d;1q'
    }

    embedded_vendor_cert_ok() {
        local image="$1" db_der section dumped der_size strings_output
        [[ -s "$image" && -s "$DB_CRT" ]] || return 1
        db_der="$RUN_DIR/golden-db.crt.der"
        section="$RUN_DIR/golden-vendor.section"
        dumped="$RUN_DIR/golden-vendor.dump.efi"
        openssl x509 -in "$DB_CRT" -outform DER -out "$db_der" >/dev/null 2>&1 || return 1
        objcopy --dump-section .vendor_cert="$section" "$image" "$dumped" >/dev/null 2>&1 || return 1
        der_size="$(stat -c '%s' "$db_der" 2>/dev/null || true)"
        [[ "$der_size" =~ ^[1-9][0-9]*$ ]] || return 1
        dd if="$section" of="$RUN_DIR/golden-vendor.der" bs=1 skip=16 count="$der_size" status=none 2>/dev/null || return 1
        cmp -s "$db_der" "$RUN_DIR/golden-vendor.der" || return 1
        strings_output="$(strings "$image" 2>/dev/null || true)"
        grep -Fq "sb-guard db" <<<"$strings_output" || return 1
        ! grep -Fq "Proxmox Server Solutions GmbH" <<<"$strings_output" || return 1
        ! grep -Fq "office@proxmox.com" <<<"$strings_output" || return 1
    }

    golden_shim_ok() {
        [[ -s "$DB_CRT" ]] || die "Missing DB_CRT: $DB_CRT"
        [[ -s "$DB_KEY" ]] || die "Missing DB_KEY: $DB_KEY"
        [[ -s "$GOLDEN_SHIM" ]] || return 1

        sbverify --cert "$DB_CRT" "$GOLDEN_SHIM" >/dev/null 2>&1 || return 1
        [[ "$(sbverify --list "$GOLDEN_SHIM" 2>/dev/null | grep -cE '^signature[[:space:]]+[0-9]+$' || true)" -eq 1 ]] || return 1
        embedded_vendor_cert_ok "$GOLDEN_SHIM" || return 1
        [[ "$(state_get signed_sha256)" == "$(sha256sum "$GOLDEN_SHIM" | awk '{print $1}')" ]]
    }

    prune_logs() {
        [[ "$LOG_DIR" == /var/log/* || "$LOG_DIR" == /var/lib/* ]] || die "Refuse prune outside /var: LOG_DIR=$LOG_DIR"

        find "$LOG_DIR" -mindepth 1 -maxdepth 1 -type d -name 'run-*' -mtime "+$MAX_AGE_DAYS" -print0 | xargs -0r rm -rf --

        local -a runs=()
        mapfile -t runs < <(
            find "$LOG_DIR" -mindepth 1 -maxdepth 1 -type d -name 'run-*' -printf '%T@ %p\n' | sort -nr | awk '{print $2}'
        )

        local s=0 f=0
        local p
        for p in "${runs[@]}"; do
            if [[ "$p" == *"/run-"*"-rc0" ]]; then
                s=$((s + 1))
                if (( s > KEEP_SUCCESS_RUNS )); then
                    rm -rf -- "$p" 2>/dev/null || true
                fi
            else
                f=$((f + 1))
                if (( f > KEEP_FAILED_RUNS )); then
                    rm -rf -- "$p" 2>/dev/null || true
                fi
            fi
        done
    }

    custom_state_get() {
        local key="$1"
        [[ -s "$CUSTOM_SHIM_STATE" ]] || return 0
        sed -n "s/^${key}=//p" "$CUSTOM_SHIM_STATE" | sed '/^$/d;1q'
    }

    stage_shim_from_custom_artifact() {
        local ver="$1"
        local package_sha="$2"
        local cert_fp="$3"
        [[ -s "$CUSTOM_SHIM_ARTIFACT" ]] \
            || die "Missing custom shim artifact: $CUSTOM_SHIM_ARTIFACT (run ./run.sh --release)"
        [[ -s "$CUSTOM_SHIM_STATE" ]] \
            || die "Missing custom shim metadata: $CUSTOM_SHIM_STATE (run ./run.sh --release)"

        [[ "$(custom_state_get mode)" == "custom-built" ]] \
            || die "Custom shim metadata mode is not custom-built"
        [[ "$(custom_state_get source_package_version)" == "$ver" ]] \
            || die "Custom shim was built for package $(custom_state_get source_package_version), installed package is $ver"
        [[ "$(custom_state_get source_package_sha256)" == "$package_sha" ]] \
            || die "Custom shim source hash is stale; run ./run.sh --release again"
        [[ "$(custom_state_get vendor_fingerprint)" == "$cert_fp" ]] \
            || die "Custom shim vendor certificate differs from current db.crt"

        log "Staging custom-built shim: $CUSTOM_SHIM_ARTIFACT"
        run cp -a "$CUSTOM_SHIM_ARTIFACT" "$RUN_DIR/shimx64.efi"
        run sbverify --cert "$DB_CRT" "$RUN_DIR/shimx64.efi" >/dev/null
        [[ "$(sbverify --list "$RUN_DIR/shimx64.efi" 2>/dev/null | grep -cE '^signature[[:space:]]+[0-9]+$' || true)" -eq 1 ]] \
            || die "Custom shim must contain exactly one Authenticode signature"
        local db_der="$RUN_DIR/db.crt.der"
        local embedded_section="$RUN_DIR/vendor.section"
        local embedded_der="$RUN_DIR/vendor.embedded.der"
        local objcopy_output="$RUN_DIR/objcopy-output.efi"
        run openssl x509 -in "$DB_CRT" -outform DER -out "$db_der"
        run objcopy --dump-section .vendor_cert="$embedded_section" "$RUN_DIR/shimx64.efi" "$objcopy_output"
        local der_size
        der_size="$(stat -c '%s' "$db_der")"
        run dd if="$embedded_section" of="$embedded_der" bs=1 skip=16 count="$der_size" status=none
        cmp -s "$db_der" "$embedded_der" \
            || die "Custom shim embedded .vendor_cert differs from current db.crt"
        local embedded_strings
        embedded_strings="$(strings "$RUN_DIR/shimx64.efi" 2>/dev/null || true)"
        grep -Fq "sb-guard db" <<<"$embedded_strings" \
            || die "Custom shim does not contain our embedded vendor certificate"
        if grep -Fq "Proxmox Server Solutions GmbH" <<<"$embedded_strings" \
            || grep -Fq "office@proxmox.com" <<<"$embedded_strings"; then
            die "Custom shim still contains the Proxmox vendor certificate"
        fi

        UNSIGNED_SHA256="$package_sha"
        SIGNED_SHA256="$(sha256sum "$RUN_DIR/shimx64.efi" | awk '{print $1}')"
        DB_FINGERPRINT="$cert_fp"
    }

    publish_golden_atomically() {
        [[ -s "$RUN_DIR/shimx64.efi" ]] || die "Missing built shim: $RUN_DIR/shimx64.efi"

        run sbverify --cert "$DB_CRT" "$RUN_DIR/shimx64.efi" >/dev/null

        # Keep one previous signed shim for local diagnostics only.  The
        # complete boot-set recovery copy is managed separately by
        # backup_current_esp and never gets replaced by an unverified state.
        if [[ -f "$GOLDEN_SHIM" ]]; then
            run install -m 0600 -o root -g root "$GOLDEN_SHIM" "$BACKUP_DIR/shimx64.efi.previous.new"
            run mv -f "$BACKUP_DIR/shimx64.efi.previous.new" "$BACKUP_DIR/shimx64.efi.previous"
        fi

        run install -m 0600 -o root -g root "$RUN_DIR/shimx64.efi" "${GOLDEN_SHIM}.new"
        run sbverify --cert "$DB_CRT" "${GOLDEN_SHIM}.new" >/dev/null

        run mv -f "${GOLDEN_SHIM}.new" "$GOLDEN_SHIM"
        run chmod 0600 "$GOLDEN_SHIM"
        run sync

        ok "Published: $GOLDEN_SHIM"
    }

    write_state() {
        local ver="$1"
        {
            printf 'package_version=%s\n' "$ver"
            printf 'unsigned_sha256=%s\n' "$UNSIGNED_SHA256"
            printf 'db_fingerprint=%s\n' "$DB_FINGERPRINT"
            printf 'signed_sha256=%s\n' "$SIGNED_SHA256"
        } >"${STATE_FILE}.new"
        run chmod 0600 "${STATE_FILE}.new"
        run mv -f "${STATE_FILE}.new" "$STATE_FILE"
    }

    rebuild_if_needed() {
        local target source_sha cert_fp custom_sha
        [[ "$SHIM_SOURCE_MODE" == "custom" ]] ||
            die "Only SHIM_SOURCE_MODE=custom is permitted by custom-only policy"
        target="$(get_target_shim_version)"
        [[ -n "$target" ]] || die "shim-unsigned is not installed"
        [[ -s "$UNSIGNED_SHIM" ]] || die "Missing package artifact: $UNSIGNED_SHIM"
        source_sha="$(sha256sum "$UNSIGNED_SHIM" | awk '{print $1}')"
        cert_fp="$(db_fingerprint)"
        custom_sha=""
        if [[ -s "$CUSTOM_SHIM_ARTIFACT" ]]; then
            custom_sha="$(sha256sum "$CUSTOM_SHIM_ARTIFACT" | awk '{print $1}')"
        fi

        if [[ "$force" -eq 0 ]]; then
            if [[ "$(state_get package_version)" == "$target" \
                && "$(state_get unsigned_sha256)" == "$source_sha" \
                && "$(state_get db_fingerprint)" == "$cert_fp" ]] \
                && golden_shim_ok; then
                if [[ "$(state_get signed_sha256)" == "$custom_sha" ]]; then
                    ok "Up-to-date (shim-unsigned=$target sha256=$source_sha)"
                    return 0
                fi
                warn "Custom shim artifact changed since last golden publish; reconciling"
            fi
        fi

        warn "Golden shim refresh required (shim-unsigned=$target force=$force)"

        case "$SHIM_SOURCE_MODE" in
            custom)
                stage_shim_from_custom_artifact "$target" "$source_sha" "$cert_fp"
                ;;
            *)
                die "Unsupported SHIM_SOURCE_MODE=$SHIM_SOURCE_MODE (custom-only policy)"
                ;;
        esac
        publish_golden_atomically
        write_state "$target"

        ok "Golden shim refreshed (version=$target unsigned_sha256=$UNSIGNED_SHA256 signed_sha256=$SIGNED_SHA256)"
    }

    usage() {
        cat <<'USAGE'
    Usage: sb-shim-rebuild [options]

    Options:
        --maybe        Refresh if package/hash/cert/golden state differs (default)
        --force        Always refresh from installed shim-unsigned
        --trace        Print executed commands
        -h|--help      Show help

    Env:
        STATE_ROOT, KEY_DIR, DB_CRT, DB_KEY,
        GOLDEN_DIR, GOLDEN_SHIM, STATE_FILE, UNSIGNED_SHIM,
        SHIM_SOURCE_MODE=custom, CUSTOM_SHIM_ARTIFACT, CUSTOM_SHIM_STATE,
        BACKUP_DIR, LOG_DIR, WORK_PARENT,
        KEEP_SUCCESS_RUNS, KEEP_FAILED_RUNS, MAX_AGE_DAYS
USAGE
    }

    main() {
        require_root
        lock_or_exit
        ensure_prereqs
        ensure_dirs
        new_run_dir

        while (( $# > 0 )); do
            case "$1" in
                --maybe) mode="maybe" ;;
                --force) force=1 ;;
                --trace) trace=1 ;;
                -h|--help) usage; exit 0 ;;
                *) die "Unknown arg: $1" ;;
            esac
            shift
        done

        case "$mode" in
            maybe) rebuild_if_needed ;;
            *) die "Bad mode: $mode" ;;
        esac

        prune_logs || true
    }

    main "$@"
EOF
    ok "installed sb-shim-rebuild -> $SHIM_REBUILD_DST"
}

# ===============================================================================
# Install: verified source-build helper (invoked only after APT completes)
# ===============================================================================
install_shared_build_root() {
    [[ -s "$PROJECT_ROOT/lib/sb_build_root.sh" ]] ||
        die "Missing shared build-root helper in project: $PROJECT_ROOT/lib/sb_build_root.sh"
    install -D -m 0750 -o root -g root \
        "$PROJECT_ROOT/lib/sb_build_root.sh" "$BUILD_ROOT_HELPER_DST"
    ok "installed shared Trixie build-root helper -> $BUILD_ROOT_HELPER_DST"
}

install_shim_auto_build() {
    # There is one canonical runtime implementation.  A partial checkout must
    # fail closed instead of falling back to a historical branch-tip clone,
    # which could build a source tree unrelated to the installed package.
    [[ -s "$PROJECT_ROOT/lib/sb_shim_auto_build.sh" ]] ||
        die "Missing canonical shim resolver: $PROJECT_ROOT/lib/sb_shim_auto_build.sh"
    install -D -m 0750 -o root -g root \
        "$PROJECT_ROOT/lib/sb_shim_auto_build.sh" "$SHIM_AUTO_BUILD_DST"
    ok "installed shared-cache shim resolver -> $SHIM_AUTO_BUILD_DST"
}
# ==============================================================================
# Install: sb-guard core + wrapper
# ==============================================================================
install_core() {
    cat <<'EOF' | indent -4 | install -D -m 0750 -o root -g root /dev/stdin "$CORE_DST"
    #!/bin/bash
    # sb-guard: strict verify/repair helper (SHIM-based, "only my keys", NO /EFI/BOOT)
    # Policy: single EFI vendor dir (default: debian) with minimal files:
    #   - shimx64.efi
    #   - grubx64.efi (contains the signed early grub.cfg stub)
    # Optional:
    #   - mmx64.efi (MokManager) (KEEP_MMX=1)
    #
    # Also: mount policy, strict signatures (single+ours), pins and NVRAM.
    # NVRAM records are firmware metadata; Secure Boot still authenticates the
    # EFI image selected by any record. The policy requires our shim to be
    # first, but does not reject recreated firmware fallback records.
    #
    # IMPORTANT MODEL NOTE:
    #   The only ESP shim input is the already verified golden artifact under
    #   STATE_ROOT/golden.  The normal fix-all path refreshes that artifact from
    #   /usr/lib/shim/shimx64.efi, signs it with db.key/db.crt, and deploys it
    #   atomically.  Direct SHIM_SRC overrides are intentionally ignored.
    #
    # NOTES (important):
    #  - This script does NOT generate keys. It expects PK/KEK/db material under KEY_DIR.
    #
    set -Eeuo pipefail
    IFS=$'\n\t'
    umask 077

    # needed for existing norm_mask() implementation
    shopt -s extglob

    # ==============================================================================
    # Config / knobs
    # ==============================================================================
    ESP_MNT="${ESP_MNT:-/boot/efi}"
    STATE_ROOT="${STATE_ROOT:-/var/lib/sb-guard}"
    KEY_DIR="${KEY_DIR:-$STATE_ROOT/keys}"
    PIN_DIR="${PIN_DIR:-$STATE_ROOT/pins}"
    ESP_BACKUP_DIR="${ESP_BACKUP_DIR:-$STATE_ROOT/backups/esp-last-good}"

    DB_CRT="${DB_CRT:-$KEY_DIR/db.crt}"     # may be PEM or DER; script will normalize to PEM for signing/verifying
    DB_KEY="${DB_KEY:-$KEY_DIR/db.key}"
    SHIM_REBUILD="${SHIM_REBUILD:-/usr/local/sbin/sb-shim-rebuild}"

    MODE="verify"          # verify|stage-release|apply-release|fix-mount|fix-structure|fix-sign|fix-nvram|fix-pins|fix-gpg|fix-esp|fix-all|break-signatures
    TRACE=0
    DEBUG_PRE=0
    VERIFY_PINS=1
    VERIFY_SHIM_VENDOR=1
    # NVRAM is part of the final strict policy. The policy requires our shim
    # to be the first BootOrder entry. Other firmware records are retained by
    # default because OVMF and physical firmware commonly recreate them after
    # every reboot.
    VERIFY_NVRAM=1
    # Never delete firmware-created fallback/setup records by default. A
    # caller may opt into removing non-firmware records with --purge-foreign.
    NVRAM_PURGE_FOREIGN="${NVRAM_PURGE_FOREIGN:-0}"

    # strict knobs (golden defaults)
    STRICT_OWNER=0         # optional: require uid=0 gid=0 (only if you mount that way)
    ALLOW_EXEC=0           # if 1 -> don't require noexec
    ALLOW_ATIME=0          # if 1 -> don't require noatime (warn only)

    REQUIRE_NOEXEC=1       # golden: require noexec
    REQUIRE_NOATIME=1      # golden: require noatime
    REQUIRE_FMASK="0177"   # golden: files show 600 (no exec bits)
    REQUIRE_DMASK="0077"   # golden: dirs show 700

    # Remount options for ESP (used by remount_rw/remount_ro).
    # Must be set because we run with "set -u".
    ESP_REMOUNT_OPTS="${ESP_REMOUNT_OPTS:-nodev,nosuid,noexec,noatime,fmask=${REQUIRE_FMASK},dmask=${REQUIRE_DMASK}}"

    # SHIM/BOOT policy
    KEEP_BOOT_DIR="${KEEP_BOOT_DIR:-0}"     # 0 = delete /EFI/BOOT completely (recommended)
    KEEP_MMX="${KEEP_MMX:-0}"               # 1 = keep mmx64.efi, 0 = strict 2 files only

    # The early GRUB stub is embedded in grubx64.efi.  The old external ESP
    # copy is retained only as a migration aid and is never part of the
    # canonical production layout.
    ESP_CFG_MODE="${ESP_CFG_MODE:-embedded}"       # embedded (canonical) | external (legacy)
    ALLOW_LEGACY_ESP_STUB="${ALLOW_LEGACY_ESP_STUB:-0}" # backup preflight only
    # During the first Proxmox migration the existing Debian directory is kept
    # only long enough to validate and back up the old boot set.  Deployment
    # then sets this override to the canonical Proxmox directory explicitly.
    EFI_ID_OVERRIDE=""
    # Keep the public firmware-enrollment bundle only while the explicit hold
    # marker exists.  The default is derived at runtime so a direct
    # sb-guard-svc invocation cannot accidentally delete a bundle needed for
    # manual PK/KEK/db enrollment; callers may override it after enrollment.
    if [[ -z "${KEEP_ENROLLMENT_BUNDLE+x}" ]]; then
        [[ -e "$STATE_ROOT/awaiting-enrollment" ]] && KEEP_ENROLLMENT_BUNDLE=1 || KEEP_ENROLLMENT_BUNDLE=0
    fi
    [[ "$KEEP_ENROLLMENT_BUNDLE" =~ ^[01]$ ]] ||
        { printf 'FAIL: Invalid KEEP_ENROLLMENT_BUNDLE=%s\n' "$KEEP_ENROLLMENT_BUNDLE" >&2; exit 1; }
    [[ "$VERIFY_NVRAM" =~ ^[01]$ ]] ||
        { printf 'FAIL: Invalid VERIFY_NVRAM=%s\n' "$VERIFY_NVRAM" >&2; exit 1; }
    [[ "$NVRAM_PURGE_FOREIGN" =~ ^[01]$ ]] ||
        { printf 'FAIL: Invalid NVRAM_PURGE_FOREIGN=%s\n' "$NVRAM_PURGE_FOREIGN" >&2; exit 1; }
    case "$ESP_CFG_MODE" in
        embedded|external) ;;
        *) printf 'FAIL: Invalid ESP_CFG_MODE=%s (expected embedded or external)\n' "$ESP_CFG_MODE" >&2; exit 1 ;;
    esac

    # Refresh policy (critical):
    #  - REFRESH_SHIM=0 (default): NEVER overwrite shim on ESP
    #  - REFRESH_SHIM=1: copy shim from SHIM_SRC to ESP
    #  - REFRESH_MMX=0 (default): never overwrite mmx (if KEEP_MMX=1 and mmx missing -> fail)
    #  - REFRESH_MMX=1: copy mmx from MMX_SRC to ESP (only if KEEP_MMX=1)
    REFRESH_SHIM="${REFRESH_SHIM:-0}"
    REFRESH_MMX="${REFRESH_MMX:-0}"

    # The packaged monolithic image is used only as the trusted SBAT source.
    # The deployed GRUB is rebuilt as a standalone image with our GPG public
    # key and a signed early configuration embedded before it is
    # Authenticode-signed.
    GRUB_MONOLITH="${GRUB_MONOLITH:-/usr/lib/grub/x86_64-efi/monolithic/grubx64.efi}"

    # Optional isolated source-build profile. A profile contains a pinned
    # grub-mkstandalone and matching x86_64-efi modules. It is selected
    # explicitly; a missing or stale profile fails closed instead of silently
    # falling back to an unreviewed image.
    GRUB_BUILD_POLICY="${GRUB_BUILD_POLICY:-/etc/sb-guard/grub-build.env}"
    if [[ -r "$GRUB_BUILD_POLICY" ]]; then
        # Root-owned, mode 0600 policy installed by sb-guard. It is the only
        # persistent switch that can enable the isolated profile.
        # shellcheck disable=SC1090
        . "$GRUB_BUILD_POLICY"
    fi
    GRUB_BUILD_MODE="${GRUB_BUILD_MODE:-packaged}"       # packaged|profile
    GRUB_BUILD_PROFILE="${GRUB_BUILD_PROFILE:-$STATE_ROOT/grub-build/profile}"
    GRUB_PROFILE_ENV="${GRUB_PROFILE_ENV:-$GRUB_BUILD_PROFILE/profile.env}"

    # Shim source is HARD-CODED to golden (ALWAYS).
    # Env SHIM_SRC is ignored by design.
    SHIM_SRC="$STATE_ROOT/golden/shimx64.efi"
    MMX_SRC="${MMX_SRC:-}"
    ESP_STAGE_DIR=""
    STAGED_GRUB=""
    STAGED_MMX=""
    RELEASE_TMP_DIR=""
    RELEASE_OUTPUT_DIR="$STATE_ROOT/release"

    # NVRAM entry label (label is cosmetic; matching is by path)
    NVRAM_LABEL="${NVRAM_LABEL:-sb-shim}"
    # GRUB runtime root (where $prefix points once root is found)
    GRUB_PREFIX="${GRUB_PREFIX:-/boot/grub}"
    GRUB_PLATFORM_DIR="${GRUB_PLATFORM_DIR:-}"

    # ==============================================================================
    # Logging / helpers
    # ==============================================================================
    ts() { date '+%F %T'; }
    log() { printf '[%s] %s\n' "$(ts)" "$*" >&2; }
    ok() { log "OK:   $*"; }
    warn() { log "WARN: $*"; }
    fail() { log "FAIL: $*"; }
    die() { fail "$*"; exit 1; }

    run() {
        if [[ "$TRACE" == "1" ]]; then
            log "CMD: $(printf '%q ' "$@")"
        fi
        "$@"
    }

    require_cmd() {
        if ! command -v "$1" >/dev/null 2>&1; then
            die "Missing required command: $1"
        fi
    }

    sha256_file() {
        local out
        out="$(sha256sum "$1")"
        printf '%s\n' "${out%% *}"
    }

    trim_ws() {
        local s="$1"
        s="${s#"${s%%[![:space:]]*}"}"
        s="${s%"${s##*[![:space:]]}"}"
        printf '%s' "$s"
    }

    write_file_if_changed() {
        local path="$1"
        local dir base tmp

        dir="$(dirname "$path")"
        base="$(basename "$path")"

        run install -d -m 0755 -o root -g root "$dir"

        # IMPORTANT: temp file must be on the SAME filesystem as destination
        # to avoid EXDEV+unlink issues on RO ESP.
        tmp="$(mktemp -p "$dir" ".${base}.tmp.XXXXXX")"
        trap 'rm -f -- "${tmp:-}" >/dev/null 2>&1 || true' RETURN
        cat >"$tmp"

        if [[ -f "$path" ]]; then
            if cmp -s "$tmp" "$path"; then
                rm -f -- "$tmp"
                trap - RETURN
                return 1
            fi
        fi

        run mv -f "$tmp" "$path"
        trap - RETURN
        return 0
    }

    try_check() {
        if "$@"; then
            return 0
        fi
        rc=1
        return 1
    }

    norm_mask() {
        # normalize "0177" vs "177" vs "0077" vs "77"
        local s="$1"
        s="${s##+(0)}"
        [[ -z "$s" ]] && s="0"
        printf '%s\n' "$s"
    }

    # Nested callers share one controlled ESP rw transaction.
    ESP_RW_DEPTH=0

    esp_rw_begin() {
        if (( ESP_RW_DEPTH == 0 )); then
            remount_rw
        fi
        ESP_RW_DEPTH=$((ESP_RW_DEPTH + 1))
    }

    esp_rw_end() {
        (( ESP_RW_DEPTH > 0 )) || return 0
        ESP_RW_DEPTH=$((ESP_RW_DEPTH - 1))
        if (( ESP_RW_DEPTH == 0 )); then
            remount_ro || die "ESP remount ro failed; refusing to continue with writable ESP"
            mnt_is_ro "$ESP_MNT" || die "ESP is still writable after controlled transaction"
        fi
    }

    # ==============================================================================
    # GRUB path resolution helpers (for "everything GRUB loads from disk")
    # ==============================================================================
    grub_strip_device_prefix() {
        # strips "(...)" leading device like "(hd0,gpt1)" or "($root)"
        local p="$1"
        if [[ "$p" == \(*\)* ]]; then
            p="${p#*)}"
        fi
        printf '%s\n' "$p"
    }

    grub_unquote() {
        local p="$1"
        p="${p%\"}"; p="${p#\"}"
        p="${p%\'}"; p="${p#\'}"
        printf '%s\n' "$p"
    }

    grub_resolve_path_try() {
        # best-effort: resolve GRUB-ish path to absolute linux path
        # returns 0 and prints path if exists; returns 1 otherwise
        local raw="$1"
        local p

        p="$(grub_unquote "$raw")"
        p="$(grub_strip_device_prefix "$p")"

        p="${p//\$\{prefix\}/$GRUB_PREFIX}"
        p="${p//\$prefix/$GRUB_PREFIX}"

        # if it still contains "$" vars, cannot resolve
        if [[ "$p" == *'$'* ]]; then
            return 1
        fi

        if [[ "$p" != /* ]]; then
            p="$GRUB_PREFIX/$p"
        fi

        if [[ -f "$p" ]]; then
            printf '%s\n' "$p"
            return 0
        fi

        # common case: "/vmlinuz-..." lives under /boot
        if [[ "$p" == /* && -f "/boot${p}" ]]; then
            printf '%s\n' "/boot${p}"
            return 0
        fi

        return 1
    }

    grub_resolve_path_or_die() {
        local raw="$1"
        local out
        if out="$(grub_resolve_path_try "$raw")"; then
            printf '%s\n' "$out"
            return 0
        fi
        die "Cannot resolve grub path: $raw"
    }

    grub_detect_platform_dir() {
        # Return GRUB platform dir name under $prefix, e.g. x86_64-efi
        # Prefer actual existing directories to avoid guessing.
        local p="$GRUB_PREFIX"

        if [[ -d "$p/x86_64-efi" ]]; then
            echo "x86_64-efi"; return 0
        fi
        if [[ -d "$p/x86_64-efi-signed" ]]; then
            echo "x86_64-efi-signed"; return 0
        fi

        # fallback: pick first "*-efi" dir
        local d
        d="$(find "$p" -mindepth 1 -maxdepth 1 -type d -name '*-efi*' -printf '%f\n' 2>/dev/null | sort | head -n1 || true)"
        [[ -n "$d" ]] || die "Cannot detect GRUB platform dir under $GRUB_PREFIX (no *-efi* dirs)"
        echo "$d"
    }

    # ==============================================================================
    # ESP mount helpers
    # ==============================================================================
    findmnt_opts() { findmnt -nro OPTIONS "$1" 2>/dev/null || true; }

    mnt_is_ro() {
        case ",$(findmnt_opts "$1")," in
            *",ro,"*) return 0 ;;
            *) return 1 ;;
        esac
    }

    remount_rw() {
        local src
        src="$(findmnt -T "$ESP_MNT" -nro SOURCE 2>/dev/null | sed '/^$/d;1q' || true)"
        if [[ -n "$src" ]]; then
            run mount -o "remount,rw,${ESP_REMOUNT_OPTS}" "$src" "$ESP_MNT" 2>/dev/null \
                || run mount -o "rw,remount,${ESP_REMOUNT_OPTS}" "$src" "$ESP_MNT" 2>/dev/null \
                || run mount -o "remount,rw,${ESP_REMOUNT_OPTS}" "$ESP_MNT"
        else
            run mount -o "remount,rw,${ESP_REMOUNT_OPTS}" "$ESP_MNT"
        fi
    }

    remount_ro() {
        # guard: don't drop RO while someone holds RW
        if (( ${ESP_RW_DEPTH:-0} > 0 )); then
            [[ "$TRACE" == "1" ]] && warn "remount_ro ignored: ESP_RW_DEPTH=$ESP_RW_DEPTH"
            return 0
        fi

        local src
        src="$(findmnt -T "$ESP_MNT" -nro SOURCE 2>/dev/null | sed '/^$/d;1q' || true)"
        if [[ -n "$src" ]]; then
            run mount -o "remount,ro,${ESP_REMOUNT_OPTS}" "$src" "$ESP_MNT" 2>/dev/null \
                || run mount -o "ro,remount,${ESP_REMOUNT_OPTS}" "$src" "$ESP_MNT" 2>/dev/null \
                || run mount -o "remount,ro,${ESP_REMOUNT_OPTS}" "$ESP_MNT"
        else
            run mount -o "remount,ro,${ESP_REMOUNT_OPTS}" "$ESP_MNT"
        fi
    }

    remount_ro_force() {
        local src
        src="$(findmnt -T "$ESP_MNT" -nro SOURCE 2>/dev/null | sed '/^$/d;1q' || true)"
        if [[ -n "$src" ]]; then
            run mount -o remount,ro,nodev,nosuid,noexec "$src" "$ESP_MNT" 2>/dev/null \
                || run mount -o ro,remount,nodev,nosuid,noexec "$src" "$ESP_MNT" 2>/dev/null \
                || run mount -o remount,ro,nodev,nosuid,noexec "$ESP_MNT"
        else
            run mount -o remount,ro,nodev,nosuid,noexec "$ESP_MNT"
        fi
    }

    ensure_esp_mounted() {
        if ! findmnt -n "$ESP_MNT" >/dev/null 2>&1; then
            die "ESP not mounted at $ESP_MNT"
        fi

        local fstype
        fstype="$(findmnt -T "$ESP_MNT" -nro FSTYPE 2>/dev/null | sed '/^$/d;1q' || true)"
        if [[ "$fstype" != "vfat" ]]; then
            die "$ESP_MNT is not vfat (got: ${fstype:-empty})"
        fi

        if [[ ! -d "$ESP_MNT/EFI" ]]; then
            die "No $ESP_MNT/EFI directory (not an ESP?)"
        fi
    }

    mount_has_opt() {
        local mnt="$1"
        local want="$2"
        local opts
        opts="$(findmnt -nro OPTIONS "$mnt" 2>/dev/null || true)"
        [[ -n "$opts" ]] || return 1

        local IFS=,
        local o
        for o in $opts; do
            [[ "$o" == "$want" ]] && return 0
        done
        return 1
    }

    mount_get_kv() {
        local mnt="$1"
        local key="$2"
        local opts
        opts="$(findmnt -nro OPTIONS "$mnt" 2>/dev/null || true)"
        [[ -n "$opts" ]] || { printf '%s\n' ""; return 0; }

        local IFS=,
        local o
        for o in $opts; do
            case "$o" in
                "$key="*)
                    printf '%s\n' "${o#*=}"
                    return 0
                    ;;
            esac
        done
        printf '%s\n' ""
        return 0
    }

    # ==============================================================================
    # System detection / EFI vendor dir detection
    # ==============================================================================
    is_proxmox_installed() {
        [[ -d /etc/pve ]] && return 0
        command -v pveversion >/dev/null 2>&1 && return 0
        if command -v dpkg-query >/dev/null 2>&1; then
            dpkg-query -W -f='${Status}\n' proxmox-ve 2>/dev/null | grep -q "install ok installed" && return 0
            dpkg-query -W -f='${Status}\n' pve-manager 2>/dev/null | grep -q "install ok installed" && return 0
        fi
        return 1
    }

    detect_system() {
        if is_proxmox_installed; then
            echo "proxmox"
        else
            echo "debian"
        fi
    }

    list_efi_top() {
        find "$ESP_MNT/EFI" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort
    }

    detect_efi_id() {
        if [[ -n "$EFI_ID_OVERRIDE" ]]; then
            [[ "$EFI_ID_OVERRIDE" =~ ^[A-Za-z0-9._-]+$ ]] || die "Invalid EFI_ID_OVERRIDE: $EFI_ID_OVERRIDE"
            echo "$EFI_ID_OVERRIDE"
            return 0
        fi
        # Prefer existing dirs on ESP to avoid "proxmox vs debian" mismatch
        if [[ -d "$ESP_MNT/EFI/debian" ]]; then
            echo "debian"; return 0
        fi
        if [[ -d "$ESP_MNT/EFI/proxmox" ]]; then
            echo "proxmox"; return 0
        fi

        local -a dirs=()
        mapfile -t dirs < <(list_efi_top)
        local -a filtered=()
        local d
        for d in "${dirs[@]}"; do
            [[ "$d" == "BOOT" ]] && continue
            filtered+=( "$d" )
        done
        if (( ${#filtered[@]} == 1 )); then
            echo "${filtered[0]}"; return 0
        fi

        detect_system
    }

    # ==============================================================================
    # Mount policy (strict) + fixer
    # ==============================================================================
    mount_remediate_hint() {
        log "  remediation:"
        log "    systemctl daemon-reload"
        log "    umount $ESP_MNT"
        log "    mount $ESP_MNT"
        log "  re-check:"
        log "    findmnt -no OPTIONS $ESP_MNT"
    }

    verify_mount_policy() {
        local rc=0

        if mnt_is_ro "$ESP_MNT"; then
            ok "ESP mount: ro"
        else
            fail "ESP mount not ro"
            rc=1
        fi
        mount_has_opt "$ESP_MNT" nodev  && ok "ESP mount opt OK: nodev"  || { fail "ESP mount opt MISSING: nodev";  rc=1; }
        mount_has_opt "$ESP_MNT" nosuid && ok "ESP mount opt OK: nosuid" || { fail "ESP mount opt MISSING: nosuid"; rc=1; }

        local need_noexec="$REQUIRE_NOEXEC"
        [[ "$ALLOW_EXEC" -eq 1 ]] && need_noexec=0
        if [[ "$need_noexec" -eq 1 ]]; then
            mount_has_opt "$ESP_MNT" noexec && ok "ESP mount opt OK: noexec" || { fail "ESP mount opt MISSING: noexec"; rc=1; }
        else
            mount_has_opt "$ESP_MNT" noexec && ok "ESP mount opt present: noexec" || warn "ESP mount opt not set: noexec (allowed; not recommended)"
        fi

        local fmask dmask
        fmask="$(mount_get_kv "$ESP_MNT" fmask || true)"
        dmask="$(mount_get_kv "$ESP_MNT" dmask || true)"

        if [[ -z "$fmask" ]]; then
            fail "ESP mount opt MISSING: fmask=$REQUIRE_FMASK"; rc=1
        else
            [[ "$(norm_mask "$fmask")" == "$(norm_mask "$REQUIRE_FMASK")" ]] \
                && ok "ESP mount opt OK: fmask=$fmask" \
                || { fail "ESP mount opt BAD: fmask=$fmask (expected $REQUIRE_FMASK)"; rc=1; }
        fi

        if [[ -z "$dmask" ]]; then
            fail "ESP mount opt MISSING: dmask=$REQUIRE_DMASK"; rc=1
        else
            [[ "$(norm_mask "$dmask")" == "$(norm_mask "$REQUIRE_DMASK")" ]] \
                && ok "ESP mount opt OK: dmask=$dmask" \
                || { fail "ESP mount opt BAD: dmask=$dmask (expected $REQUIRE_DMASK)"; rc=1; }
        fi

        local need_noatime="$REQUIRE_NOATIME"
        [[ "$ALLOW_ATIME" -eq 1 ]] && need_noatime=0
        if [[ "$need_noatime" -eq 1 ]]; then
            mount_has_opt "$ESP_MNT" noatime && ok "ESP mount opt OK: noatime" || { fail "ESP mount opt MISSING: noatime"; rc=1; }
        else
            mount_has_opt "$ESP_MNT" noatime && ok "ESP mount opt present: noatime" || warn "ESP mount opt not set: noatime (allowed)"
        fi

        [[ "$rc" -ne 0 ]] && mount_remediate_hint
        return "$rc"
    }

    fix_mount_policy() {
        log "=== FIX BEGIN (mount-policy) ==="
        if ! findmnt -n "$ESP_MNT" >/dev/null 2>&1; then
            run mount "$ESP_MNT"
        fi
        ensure_esp_mounted

        if verify_mount_policy; then
            ok "Mount policy already compliant; no remount required"
            log "=== FIX DONE (mount-policy) ==="
            return 0
        fi

        # Never stop/unmount boot-efi.mount from a service which has
        # RequiresMountsFor=/boot/efi: systemd would terminate this worker.
        warn "Repairing ESP mount flags with an in-place RO remount"
        ESP_RW_DEPTH=0
        remount_ro
        verify_mount_policy || die "ESP mount policy remains invalid after remount"
        log "=== FIX DONE (mount-policy) ==="
    }

    # ==============================================================================
    # Structure allowlist + fixer (NO /EFI/BOOT)
    # ==============================================================================
    verify_exact_dir_set() {
        local dir="$1"
        shift
        local -a expected=( "$@" )
        local -a actual=()
        mapfile -t actual < <(find "$dir" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | sort)

        local exp_join act_join
        exp_join="$(printf '%s\n' "${expected[@]}" | sort)"
        act_join="$(printf '%s\n' "${actual[@]}" | sort)"

        if [[ "$exp_join" != "$act_join" ]]; then
            fail "Dir contents mismatch: $dir"
            log "  expected:"
            printf '%s\n' "${expected[@]}" | sort | while IFS= read -r item; do
                printf '    - %s\n' "$item"
            done >&2
            log "  actual:"
            if (( ${#actual[@]} == 0 )); then
                printf '    - (empty)\n' >&2
            else
                printf '    - %s\n' "${actual[@]}" >&2
            fi
            return 1
        fi

        ok "Dir contents exact OK: $dir"
        return 0
    }

    esp_stub_path() {
        local efi_id="${1:-$(detect_efi_id)}"
        printf '%s\n' "$ESP_MNT/EFI/$efi_id/grub.cfg"
    }

    esp_stub_expected() {
        local efi_id="$1"
        local path
        path="$(esp_stub_path "$efi_id")"
        [[ "$ESP_CFG_MODE" == external ]] ||
            [[ "$ALLOW_LEGACY_ESP_STUB" -eq 1 && -f "$path" ]]
    }

    verify_structure() {
        local rc=0
        local efi_id
        efi_id="$(detect_efi_id)"

        local -a actual_top=()
        mapfile -t actual_top < <(list_efi_top)

        local -a expected_top=( "$efi_id" )
        if [[ "$KEEP_BOOT_DIR" -eq 1 ]]; then
            expected_top+=( "BOOT" )
        fi
        [[ "$KEEP_ENROLLMENT_BUNDLE" -eq 1 ]] && expected_top+=( "SB" )

        local exp_join act_join
        exp_join="$(printf '%s\n' "${expected_top[@]}" | sort)"
        act_join="$(printf '%s\n' "${actual_top[@]}" | sort)"

        if [[ "$exp_join" != "$act_join" ]]; then
            fail "EFI root allowlist mismatch: $ESP_MNT/EFI"
            log "  expected:"
            printf '%s\n' "${expected_top[@]}" | sort | while IFS= read -r item; do
                printf '    - %s\n' "$item"
            done >&2
            log "  actual:"
            printf '    - %s\n' "${actual_top[@]}" >&2
            rc=1
        else
            ok "EFI root allowlist exact OK: $ESP_MNT/EFI"
        fi

        local -a sys_expected=( "shimx64.efi" "grubx64.efi" )
        esp_stub_expected "$efi_id" && sys_expected+=( "grub.cfg" )
        [[ "$KEEP_MMX" -eq 1 ]] && sys_expected+=( "mmx64.efi" )

        if ! verify_exact_dir_set "$ESP_MNT/EFI/$efi_id" "${sys_expected[@]}"; then
            rc=1
        fi

        if [[ "$KEEP_BOOT_DIR" -eq 1 ]]; then
            if ! verify_exact_dir_set "$ESP_MNT/EFI/BOOT" "BOOTX64.EFI" "grub.cfg"; then
                rc=1
            fi
        fi

        if [[ "$KEEP_ENROLLMENT_BUNDLE" -eq 1 ]]; then
            # KeyTool and the signed public enrollment payload are the only
            # permitted contents while firmware enrollment is pending.
            if ! verify_exact_dir_set "$ESP_MNT/EFI/SB" "ENROLL" "KeyTool.efi"; then
                rc=1
            fi
            if ! verify_exact_dir_set "$ESP_MNT/EFI/SB/ENROLL" \
                PK.auth PK.crt PK.cer PK.der PK.esl \
                KEK.auth KEK.crt KEK.cer KEK.der KEK.esl \
                db.auth db.crt db.cer db.der db.esl; then
                rc=1
            fi
        fi

        return "$rc"
    }

    fix_structure() {
        log "=== FIX BEGIN (structure) ==="
        ensure_esp_mounted

        local efi_id
        efi_id="$(detect_efi_id)"
        log "Policy: keep only EFI/$efi_id (and KEEP_BOOT_DIR=$KEEP_BOOT_DIR)."

        local efi_root="$ESP_MNT/EFI"
        local sys_dir="$efi_root/$efi_id"

        esp_rw_begin
        trap 'esp_rw_end || true' RETURN

        local p base
        while IFS= read -r -d '' p; do
            base="$(basename "$p")"
            if [[ "$base" == "$efi_id" ]]; then
                :
            elif [[ "$base" == "BOOT" && "$KEEP_BOOT_DIR" -eq 1 ]]; then
                :
            elif [[ "$base" == "SB" && "$KEEP_ENROLLMENT_BUNDLE" -eq 1 ]]; then
                :
            else
                warn "Removing foreign EFI entry: $p"
                run rm -rf -- "$p"
            fi
        done < <(find "$efi_root" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)

        run mkdir -p -- "$sys_dir"

        while IFS= read -r -d '' p; do
            base="$(basename "$p")"
            case "$base" in
                shimx64.efi|grubx64.efi)
                    ;;
                grub.cfg)
                    if [[ "$ESP_CFG_MODE" == external ]]; then
                        :
                    else
                        warn "Removing redundant external ESP stub: $p"
                        run rm -f -- "$p"
                    fi
                    ;;
                mmx64.efi)
                    if [[ "$KEEP_MMX" -eq 1 ]]; then
                        :
                    else
                        warn "Removing mmx (KEEP_MMX=0): $p"
                        run rm -f -- "$p"
                    fi
                    ;;
                *)
                    warn "Removing foreign file in EFI/$efi_id: $p"
                    run rm -rf -- "$p"
                    ;;
            esac
        done < <(find "$sys_dir" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)

        if [[ "$KEEP_BOOT_DIR" -eq 0 && -d "$efi_root/BOOT" ]]; then
            warn "Removing EFI/BOOT (KEEP_BOOT_DIR=0): $efi_root/BOOT"
            run rm -rf -- "$efi_root/BOOT"
        fi

        run sync
        esp_rw_end
        trap - RETURN

        log "=== FIX DONE (structure) ==="
    }

    # ==============================================================================
    # Stub cfg policy (with boot_lvmid)
    # ==============================================================================
    stub_boot_uuid() {
        local boot_uuid
        boot_uuid="$(findmnt -T /boot/grub -nro UUID 2>/dev/null | sed '/^$/d;1q' || true)"
        [[ -n "$boot_uuid" ]] || die "Cannot determine boot UUID via findmnt -T /boot/grub"
        printf '%s\n' "$boot_uuid"
    }

    stub_boot_src() {
        local boot_src
        boot_src="$(findmnt -T /boot/grub -nro SOURCE 2>/dev/null | sed '/^$/d;1q' || true)"
        [[ -n "$boot_src" ]] || die "Cannot determine boot source via findmnt -T /boot/grub"
        printf '%s\n' "$boot_src"
    }

    stub_luks_uuid() {
        local boot_src luks_uuid
        boot_src="$(stub_boot_src)"
        luks_uuid="$(
            lsblk -p -s -nro FSTYPE,UUID "$boot_src" 2>/dev/null \
            | sed -n 's/^crypto_LUKS[[:space:]]\+//p' \
            | sed '/^$/d;1q'
        )"
        [[ -n "$luks_uuid" ]] || die "Cannot determine LUKS UUID under $boot_src"
        printf '%s\n' "$luks_uuid"
    }

    stub_boot_lvmid() {
        local s
        s="$(grub-probe --target=hints_string /boot 2>/dev/null || true)"
        s="$(printf '%s' "$s" | sed -n "s/.*lvmid\/\([^']*\).*/lvmid\/\1/p" | sed '/^$/d;1q' || true)"
        [[ -n "$s" ]] || die "Cannot determine boot_lvmid via grub-probe (empty)"
        printf '%s\n' "$s"
    }

    render_stub_cfg() {
        local luks_uuid="$1"
        local boot_uuid="$2"
        local boot_lvmid="$3"

    cat <<EOS
    # sb-guard: signed GRUB embedded trust root
    set check_signatures=enforce
    export check_signatures

    if ! cryptomount -u ${luks_uuid}; then
        clear
        echo "Access denied [1/3]"
        if ! cryptomount -u ${luks_uuid}; then
            clear
            echo "Access denied [2/3]"
            if ! cryptomount -u ${luks_uuid}; then
                clear
                echo "Access denied [3/3]"
                sleep 10
                reboot
            fi
        fi
    fi

    search.fs_uuid ${boot_uuid} root ${boot_lvmid}
    set prefix=(\$root)'/boot/grub'
    configfile \$prefix/grub.cfg

    clear
    echo "Boot failed"
    sleep 10
    reboot
    EOS
    }

    stub_cfg_exact_ok() {
        local path="$1"
        local luks_uuid="$2"
        local boot_uuid="$3"
        local boot_lvmid="$4"
        local tmp

        [[ -f "$path" ]] || return 1
        tmp="$(mktemp)"
        render_stub_cfg "$luks_uuid" "$boot_uuid" "$boot_lvmid" >"$tmp"
        if cmp -s "$tmp" "$path"; then rm -f -- "$tmp"; return 0; fi
        rm -f -- "$tmp"
        return 1
    }

    verify_embedded_stub_cfg() {
        local image="$1" luks_uuid="$2" boot_uuid="$3" text
        [[ -f "$image" ]] || { fail "Embedded stub image missing: $image"; return 1; }
        command -v strings >/dev/null 2>&1 || { fail "Missing strings utility for embedded stub verification"; return 1; }
        text="$(strings -a -n 1 "$image" 2>/dev/null || true)"
        grep -qF '# sb-guard: signed GRUB embedded trust root' <<<"$text" || { fail "Embedded GRUB stub marker missing: $image"; return 1; }
        grep -qF 'set check_signatures=enforce' <<<"$text" || { fail "Embedded GRUB signature enforcement missing: $image"; return 1; }
        grep -qF "cryptomount -u $luks_uuid" <<<"$text" || { fail "Embedded GRUB LUKS UUID mismatch: $image"; return 1; }
        grep -qF "search.fs_uuid $boot_uuid" <<<"$text" || { fail "Embedded GRUB /boot UUID mismatch: $image"; return 1; }
        grep -qF "configfile \$prefix/grub.cfg" <<<"$text" || { fail "Embedded GRUB configfile handoff missing: $image"; return 1; }
        grep -qF 'boot/grub/grub.cfg.sig' <<<"$text" || { fail "Embedded GRUB config signature payload missing: $image"; return 1; }
        ok "Embedded GRUB early stub OK: $image"
    }

    fix_stub_cfgs() {
        log "=== FIX BEGIN (stub-cfg) ==="
        ensure_esp_mounted

        if [[ "$ESP_CFG_MODE" == embedded ]]; then
            ok "External ESP grub.cfg disabled; early stub is embedded in grubx64.efi"
            log "=== FIX DONE (stub-cfg; embedded) ==="
            return 0
        fi

        local efi_id luks_uuid boot_uuid boot_lvmid p_sys
        efi_id="$(detect_efi_id)"
        luks_uuid="$(stub_luks_uuid)"
        boot_uuid="$(stub_boot_uuid)"
        boot_lvmid="$(stub_boot_lvmid)"

        p_sys="$ESP_MNT/EFI/$efi_id/grub.cfg"

        esp_rw_begin
        trap 'esp_rw_end || true' RETURN

        if stub_cfg_exact_ok "$p_sys" "$luks_uuid" "$boot_uuid" "$boot_lvmid"; then
            ok "stub cfg exact OK: $p_sys"
        else
            warn "stub cfg FIX: rewriting: $p_sys"
            if render_stub_cfg "$luks_uuid" "$boot_uuid" "$boot_lvmid" |
                write_file_if_changed "$p_sys" >/dev/null; then
                :
            else
                # write_file_if_changed returns 1 when the exact file already
                # exists.  Accept that idempotent result, but fail closed for
                # a renderer or atomic-write error.
                local -a write_status=("${PIPESTATUS[@]}")
                [[ "${write_status[0]:-1}" -eq 0 && "${write_status[1]:-1}" -eq 1 ]] ||
                    die "Could not atomically write ESP stub config: $p_sys"
            fi
            run chmod 0600 "$p_sys"
        fi

        run sync
        esp_rw_end
        trap - RETURN

        log "=== FIX DONE (stub-cfg) ==="
    }

    verify_stub_cfgs() {
        local rc=0
        local efi_id luks_uuid boot_uuid boot_lvmid p_sys grub_efi
        efi_id="$(detect_efi_id)"
        luks_uuid="$(stub_luks_uuid)"
        boot_uuid="$(stub_boot_uuid)"
        boot_lvmid="$(stub_boot_lvmid)"
        grub_efi="$ESP_MNT/EFI/$efi_id/grubx64.efi"

        if [[ "$ESP_CFG_MODE" == embedded ]]; then
            verify_embedded_stub_cfg "$grub_efi" "$luks_uuid" "$boot_uuid" || rc=1
            if [[ "$ALLOW_LEGACY_ESP_STUB" -eq 1 && -f "$(esp_stub_path "$efi_id")" ]]; then
                p_sys="$(esp_stub_path "$efi_id")"
                if stub_cfg_exact_ok "$p_sys" "$luks_uuid" "$boot_uuid" "$boot_lvmid"; then
                    ok "Legacy ESP stub matches embedded policy: $p_sys"
                else
                    fail "Legacy ESP stub is not exact: $p_sys"
                    rc=1
                fi
            fi
            return "$rc"
        fi

        p_sys="$(esp_stub_path "$efi_id")"

        if stub_cfg_exact_ok "$p_sys" "$luks_uuid" "$boot_uuid" "$boot_lvmid"; then
            ok "EFI/$efi_id/grub.cfg: stub cfg exact OK"
        else
            fail "EFI/$efi_id/grub.cfg: stub cfg NOT exact"
            [[ "$DEBUG_PRE" -eq 1 ]] && { log "Expected stub cfg:"; render_stub_cfg "$luks_uuid" "$boot_uuid" "$boot_lvmid" >&2; }
            rc=1
        fi

        return "$rc"
    }

    # ==============================================================================
    # Types/perms policy (vfat aware)
    # ==============================================================================
    stat_mode() { stat -c '%a' -- "$1"; }
    stat_uid() { stat -c '%u' -- "$1"; }
    stat_gid() { stat -c '%g' -- "$1"; }
    stat_type() { stat -c '%F' -- "$1"; }

    is_world_writable_mode() {
        local m="$1"
        local last="${m: -1}"
        case "$last" in
            2|3|6|7) return 0 ;;
            *) return 1 ;;
        esac
    }

    mode_in_allowlist() {
        local mode="$1"; shift
        local a
        for a in "$@"; do [[ "$mode" == "$a" ]] && return 0; done
        return 1
    }

    mode_has_any_exec() {
        local m="$1"
        [[ "$m" =~ ^[0-9]{3,4}$ ]] || return 1
        local last3="${m: -3}"
        local u="${last3:0:1}" g="${last3:1:1}" o="${last3:2:1}"
        case "$u$g$o" in
            *1*|*3*|*5*|*7*) return 0 ;;
            *) return 1 ;;
        esac
    }

    verify_no_exec_bit() {
        local path="$1"
        [[ -e "$path" ]] || { fail "STRICT: missing: $path"; return 1; }
        local m; m="$(stat_mode "$path")"
        if mode_has_any_exec "$m"; then
            fail "STRICT: exec bit forbidden: $path (mode=$m)"
            return 1
        fi
        ok "STRICT: no exec bit: $path (mode=$m)"
        return 0
    }

    verify_owner_root_if_enabled() {
        local path="$1"
        [[ "$STRICT_OWNER" -eq 1 ]] || return 0
        local u g
        u="$(stat_uid "$path")"
        g="$(stat_gid "$path")"
        if [[ "$u" != "0" || "$g" != "0" ]]; then
            fail "STRICT: owner not root:root: $path (uid=$u gid=$g)"
            return 1
        fi
        ok "STRICT: owner OK (root:root): $path"
        return 0
    }

    verify_path_strict() {
        local path="$1"
        local want_kind="$2"
        shift 2
        local -a allow_modes=( "$@" )

        [[ -e "$path" ]] || { fail "STRICT: missing: $path"; return 1; }

        local t; t="$(stat_type "$path")"
        case "$want_kind" in
            file) [[ "$t" == "regular file" ]] || { fail "STRICT: not a regular file: $path (type=$t)"; return 1; } ;;
            dir)  [[ "$t" == "directory"    ]] || { fail "STRICT: not a directory: $path (type=$t)"; return 1; } ;;
            *) die "verify_path_strict: bad want_kind=$want_kind" ;;
        esac

        local m; m="$(stat_mode "$path")"
        mode_in_allowlist "$m" "${allow_modes[@]}" || { fail "STRICT: bad mode: $path (mode=$m)"; return 1; }
        is_world_writable_mode "$m" && { fail "STRICT: world-writable forbidden: $path (mode=$m)"; return 1; }

        ok "STRICT: type+mode OK: $path (type=$t mode=$m)"
        return 0
    }

    verify_tree_no_weird_objects() {
        local dir="$1"
        local bad=0 p t
        while IFS= read -r -d '' p; do
            t="$(stat_type "$p")"
            case "$t" in
                "regular file"|"directory") : ;;
                *) fail "STRICT: forbidden object under $dir: $p (type=$t)"; bad=1 ;;
            esac
        done < <(find "$dir" -xdev -print0 2>/dev/null)

        [[ "$bad" -eq 0 ]] && ok "STRICT: no symlinks/devices/etc in tree: $dir"
        [[ "$bad" -eq 0 ]]
    }

    verify_perms_types() {
        local rc=0
        local efi_id; efi_id="$(detect_efi_id)"
        local sys_dir="$ESP_MNT/EFI/$efi_id"

        # With dmask=0077, dirs should be 700
        try_check verify_path_strict "$ESP_MNT/EFI" dir 700
        try_check verify_path_strict "$sys_dir"  dir 700
        try_check verify_owner_root_if_enabled "$ESP_MNT/EFI"
        try_check verify_owner_root_if_enabled "$sys_dir"

        # With fmask=0177, files should be 600
        try_check verify_path_strict "$sys_dir/shimx64.efi" file 600
        try_check verify_path_strict "$sys_dir/grubx64.efi" file 600
        if [[ "$KEEP_MMX" -eq 1 ]]; then
            try_check verify_path_strict "$sys_dir/mmx64.efi" file 600
        fi

        if esp_stub_expected "$efi_id"; then
            try_check verify_path_strict "$sys_dir/grub.cfg" file 600
            try_check verify_no_exec_bit "$sys_dir/grub.cfg"
        else
            ok "No external ESP grub.cfg required (embedded mode)"
        fi

        try_check verify_owner_root_if_enabled "$sys_dir/shimx64.efi"
        try_check verify_owner_root_if_enabled "$sys_dir/grubx64.efi"
        [[ "$KEEP_MMX" -eq 1 ]] && try_check verify_owner_root_if_enabled "$sys_dir/mmx64.efi"
        if esp_stub_expected "$efi_id"; then
            try_check verify_owner_root_if_enabled "$sys_dir/grub.cfg"
        fi

        try_check verify_tree_no_weird_objects "$ESP_MNT/EFI"

        return "$rc"
    }

    # ==============================================================================
    # Keys presence (state)
    # ==============================================================================
    verify_keys_present() {
        local -a need_keys=( "PK.crt" "PK.key" "PK.auth" "KEK.crt" "KEK.key" "KEK.auth" "db.crt" "db.key" "db.auth" )
        local missing=0 k
        for k in "${need_keys[@]}"; do
            if [[ ! -s "$KEY_DIR/$k" ]]; then
                missing=1
                warn "Missing key file: $KEY_DIR/$k"
            fi
        done
        [[ "$missing" -eq 0 ]] && { ok "UEFI key material present in $KEY_DIR"; return 0; }
        return 1
    }

    # ==============================================================================
    # Normalize db cert to PEM (needed for sbsign/sbverify)
    # ==============================================================================
    DB_CRT_PEM=""

    ensure_db_cert_pem() {
        [[ -s "$DB_CRT" ]] || die "Missing db cert: $DB_CRT"
        [[ -s "$DB_KEY" ]] || die "Missing db key: $DB_KEY"

        local out="$KEY_DIR/db.pem"
        if openssl x509 -in "$DB_CRT" -inform PEM -noout >/dev/null 2>&1; then
            DB_CRT_PEM="$DB_CRT"
            ok "db cert is PEM: $DB_CRT"
            return 0
        fi
        if openssl x509 -in "$DB_CRT" -inform DER -noout >/dev/null 2>&1; then
            warn "db.crt is DER; converting to PEM -> $out"
            run openssl x509 -in "$DB_CRT" -inform DER -out "$out" -outform PEM >/dev/null
            run chmod 0600 "$out"
            DB_CRT_PEM="$out"
            ok "db cert converted to PEM: $DB_CRT_PEM"
            return 0
        fi

        die "db cert is not valid X509 PEM/DER: $DB_CRT"
    }

    # ==============================================================================
    # EFI signature policy (strict): single signature AND verifies with our db cert
    # ==============================================================================
    sig_count() {
        sbverify --list "$1" 2>/dev/null | grep -cE '^signature[[:space:]]+[0-9]+$' || true
    }

    efi_sig_strict_ok() {
        local f="$1"
        ensure_db_cert_pem
        local c; c="$(sig_count "$f")"
        [[ "$c" -eq 1 ]] || return 1
        sbverify --cert "$DB_CRT_PEM" "$f" >/dev/null 2>&1
    }

    verify_shim_vendor_cert() (
        local image="$1" tmp db_der section dumped der_size strings_output
        [[ -s "$image" ]] || return 1
        tmp="$(mktemp -d -p "$STATE_ROOT" .shim-vendor-check.XXXXXX 2>/dev/null)" || return 1
        trap 'rm -rf -- "$tmp"' EXIT

        db_der="$tmp/db.crt.der"
        section="$tmp/vendor.section"
        dumped="$tmp/image.dump.efi"
        ensure_db_cert_pem
        if ! openssl x509 -in "$DB_CRT_PEM" -outform DER -out "$db_der" >/dev/null 2>&1; then
            return 1
        fi
        if ! objcopy --dump-section .vendor_cert="$section" "$image" "$dumped" >/dev/null 2>&1; then
            return 1
        fi
        der_size="$(stat -c '%s' "$db_der" 2>/dev/null || true)"
        [[ "$der_size" =~ ^[1-9][0-9]*$ ]] || return 1
        if ! dd if="$section" of="$tmp/vendor.der" bs=1 skip=16 count="$der_size" status=none 2>/dev/null; then
            return 1
        fi
        cmp -s "$db_der" "$tmp/vendor.der" || return 1
        strings_output="$(strings "$image" 2>/dev/null || true)"
        grep -Fq "sb-guard db" <<<"$strings_output" || return 1
        ! grep -Fq "Proxmox Server Solutions GmbH" <<<"$strings_output" || return 1
        ! grep -Fq "office@proxmox.com" <<<"$strings_output" || return 1
    )

    verify_efi_sig_strict() {
        local f="$1"
        [[ -f "$f" ]] || die "Missing EFI binary: $f"
        ensure_db_cert_pem

        if efi_sig_strict_ok "$f"; then
            ok "EFI signature strict OK (single+ours): $f"
            return 0
        fi

        local c; c="$(sig_count "$f")"
        fail "EFI signature strict FAIL: $f (sig_count=$c)"
        log "  sbverify --list (first 40 lines):"
        sbverify --list "$f" 2>&1 | sed -n '1,40p' >&2 || true
        return 1
    }

    # SBAT is embedded in the PE image.  A valid Authenticode signature is
    # not sufficient if the deployed GRUB lost its SBAT section.
    verify_grub_sbat_section() (
        local image="$1" tmp
        [[ -s "$image" ]] || return 1
        tmp="$(mktemp -d -p "$STATE_ROOT" .grub-sbat-check.XXXXXX 2>/dev/null)" || return 1
        trap 'rm -rf -- "$tmp"' EXIT
        objcopy --dump-section .sbat="$tmp/sbat" "$image" "$tmp/image.efi" >/dev/null 2>&1 || return 1
        [[ -s "$tmp/sbat" ]] || return 1
        tr -d '\000\r' <"$tmp/sbat" |
            awk -F, '$1 != "" && $2 ~ /^[0-9]+$/ { found=1 } END { exit !found }' ||
            return 1
        ok "GRUB SBAT section present and parseable: $image"
    )

    sign_one_strict() {
        local f="$1"
        [[ -f "$f" ]] || die "Missing EFI file: $f"
        ensure_db_cert_pem

        local dir base work out
        dir="$(dirname "$f")"
        base="$(basename "$f")"

        work="$(mktemp)"

        cleanup() {
            rm -f -- "$work" "${out:-}" >/dev/null 2>&1 || true
        }
        # Install the cleanup trap before creating the same-filesystem output;
        # otherwise a failed mktemp on a read-only/full ESP would leak the
        # temporary copy in /tmp.
        trap cleanup RETURN

        # Ensure ESP is writable immediately before creating the same-filesystem temp file.
        if [[ "$dir" == "$ESP_MNT"* ]] && mnt_is_ro "$ESP_MNT"; then
            warn "ESP unexpectedly RO during signing; re-remounting RW"
            remount_rw
        fi

        # IMPORTANT: output MUST be on same filesystem as destination to avoid EXDEV+unlink.
        out="$(mktemp -p "$dir" ".${base}.sbnew.XXXXXX")"

        run cp -a "$f" "$work"
        run chmod 0600 "$work"

        run sbattach --remove "$work" >/dev/null 2>&1 || true
        run sbsign --key "$DB_KEY" --cert "$DB_CRT_PEM" --output "$out" "$work" >/dev/null
        run chmod 0600 "$out"

        local c; c="$(sig_count "$out")"
        [[ "$c" -eq 1 ]] || die "Post-sign sig_count != 1 for $f (got $c)"
        sbverify --cert "$DB_CRT_PEM" "$out" >/dev/null 2>&1 || die "Post-sign verification failed for $f"

        run mv -f "$out" "$f"
        rm -f -- "$work" >/dev/null 2>&1 || true
        trap - RETURN
    }

    fix_signatures() {
        log "=== FIX BEGIN (efi-sign-strict) ==="
        ensure_esp_mounted

        local efi_id; efi_id="$(detect_efi_id)"
        local sys_dir="$ESP_MNT/EFI/$efi_id"
        local shim_efi="$sys_dir/shimx64.efi"
        local grub_efi="$sys_dir/grubx64.efi"
        local mmx_efi="$sys_dir/mmx64.efi"

        verify_structure || die "Preconditions failed: structure"
        verify_stub_cfgs || die "Preconditions failed: stub cfgs"
        verify_keys_present || die "Preconditions failed: missing keys in $KEY_DIR"

        esp_rw_begin
        trap 'esp_rw_end || true' RETURN

        # IMPORTANT:
        # Do NOT re-sign shim here. Shim must be provided already signed (golden),
        # otherwise firmware may refuse it and/or shim may fail in weird ways.
        if efi_sig_strict_ok "$shim_efi" && verify_shim_vendor_cert "$shim_efi"; then
            ok "Shim already strict-signed with our vendor cert; skipping re-sign: $shim_efi"
        else
            die "Shim is not custom-only (signature/vendor cert): $shim_efi (use --refresh-shim with a custom golden shim)"
        fi

        warn "Re-signing strictly: $grub_efi"
        sign_one_strict "$grub_efi"

        if [[ "$KEEP_MMX" -eq 1 && -f "$mmx_efi" ]]; then
            warn "Re-signing strictly: $mmx_efi"
            sign_one_strict "$mmx_efi"
        fi

        run sync
        esp_rw_end
        trap - RETURN

        verify_efi_sig_strict "$shim_efi"
        verify_efi_sig_strict "$grub_efi"
        if [[ "$KEEP_MMX" -eq 1 && -f "$mmx_efi" ]]; then
            verify_efi_sig_strict "$mmx_efi"
        fi

        log "=== FIX DONE (efi-sign-strict) ==="
    }

    # ==============================================================================
    # NEW: Kernels referenced from /boot/grub/grub.cfg must be EFI-signed with our db
    # ==============================================================================
    grub_cfg_list_kernels() {
        local cfg="/boot/grub/grub.cfg"
        [[ -f "$cfg" ]] || die "Missing: $cfg"
        # linux|linuxefi <path>
        grep -E '^[[:space:]]*(linux|linuxefi)[[:space:]]+' "$cfg" 2>/dev/null \
            | sed -E 's/^[[:space:]]*(linux|linuxefi)[[:space:]]+([^[:space:]]+).*/\2/' \
            | sed '/^$/d' \
            | while IFS= read -r p; do
                grub_resolve_path_or_die "$p"
            done \
            | sort -u
    }

    list_all_kernels() {
        local k any=0
        for k in /boot/vmlinuz-*; do
            [[ -f "$k" ]] || continue
            [[ "$k" == *.sig ]] && continue
            any=1
            printf '%s\n' "$k"
        done
        [[ "$any" -eq 1 ]] || die "No /boot/vmlinuz-* kernels found"
    }

    verify_kernels_efi_signed_from_grub_cfg() {
        local k
        local any=0
        while IFS= read -r k; do
            [[ -n "$k" ]] || continue
            any=1
            verify_efi_sig_strict "$k"
        done < <(list_all_kernels)
        if [[ "$any" -eq 0 ]]; then
            die "No /boot/vmlinuz-* kernels passed PE verification"
        else
            ok "Every /boot/vmlinuz-* passed strict PE/Authenticode verification"
        fi
    }

    fix_kernels_efi_signed_from_grub_cfg() {
        log "=== FIX BEGIN (kernel-efi-sign) ==="
        verify_keys_present || die "Preconditions failed: missing keys in $KEY_DIR"
        ensure_db_cert_pem

        local k
        local any=0
        while IFS= read -r k; do
            [[ -n "$k" ]] || continue
            any=1
            if efi_sig_strict_ok "$k"; then
                ok "Kernel already strict-signed; skipping: $k"
            else
                warn "EFI-signing kernel (strict): $k"
                sign_one_strict "$k"
            fi
        done < <(list_all_kernels)

        if [[ "$any" -eq 0 ]]; then
            die "No /boot/vmlinuz-* kernels found"
        fi

        log "=== FIX DONE (kernel-efi-sign) ==="
    }

    # ==============================================================================
    # Pins policy + fixer
    # ==============================================================================
    pin_path_for_rel() {
        local rel="$1"
        local safe="${rel#/}"
        safe="${safe//\//_}"
        printf '%s/%s.sha256\n' "$PIN_DIR" "$safe"
    }

    verify_pin_one() {
        local rel="$1"
        local abs="$ESP_MNT$rel"
        local pin; pin="$(pin_path_for_rel "$rel")"

        [[ -f "$abs" ]] || die "Missing file for pin check: $abs"
        if [[ ! -s "$pin" ]]; then
            warn "PIN missing: $pin (rel=$rel)"
            return 2
        fi

        local expected current
        expected="$(cat "$pin")"
        current="$(sha256_file "$abs")"

        if [[ "$expected" != "$current" ]]; then
            fail "PIN MISMATCH: $rel"
            log "  expected=$expected"
            log "  current  =$current"
            return 1
        fi

        ok "PIN OK: $rel"
        return 0
    }

    write_pin_one() {
        local rel="$1"
        local pin; pin="$(pin_path_for_rel "$rel")"
        local cur; cur="$(sha256_file "$ESP_MNT$rel")"

        run install -d -m 0700 -o root -g root "$PIN_DIR"
        printf '%s\n' "$cur" >"$pin"
        run chmod 0600 "$pin"
        ok "PIN UPDATED: $rel = $cur"
    }

    verify_pins() {
        local rc=0
        local efi_id; efi_id="$(detect_efi_id)"
        local sys_dir="/EFI/$efi_id"

        local rel_shim="$sys_dir/shimx64.efi"
        local rel_grub="$sys_dir/grubx64.efi"
        local rel_mmx="$sys_dir/mmx64.efi"

        try_check verify_pin_one "$rel_shim"
        try_check verify_pin_one "$rel_grub"
        if [[ "$ESP_CFG_MODE" == external ]]; then
            try_check verify_pin_one "$sys_dir/grub.cfg"
        fi
        if [[ "$KEEP_MMX" -eq 1 && -f "$ESP_MNT$rel_mmx" ]]; then
            try_check verify_pin_one "$rel_mmx"
        fi

        ok "Pins check finished"
        return "$rc"
    }

    fix_pins() {
        log "=== FIX BEGIN (pins-strict) ==="
        ensure_esp_mounted

        verify_mount_policy || die "Refusing to repin: mount policy failed"
        verify_structure   || die "Refusing to repin: structure failed"
        verify_perms_types || die "Refusing to repin: perms/types failed"
        verify_stub_cfgs   || die "Refusing to repin: embedded/legacy stub verification failed"
        verify_keys_present|| die "Refusing to repin: missing keys"

        local efi_id; efi_id="$(detect_efi_id)"
        local sys_dir="/EFI/$efi_id"

        efi_sig_strict_ok "$ESP_MNT$sys_dir/shimx64.efi" || die "Refusing to repin: shimx64.efi signature not strict"
        verify_shim_vendor_cert "$ESP_MNT$sys_dir/shimx64.efi" || die "Refusing to repin: shim vendor certificate is not ours"
        efi_sig_strict_ok "$ESP_MNT$sys_dir/grubx64.efi" || die "Refusing to repin: grubx64.efi signature not strict"
        if [[ "$KEEP_MMX" -eq 1 && -f "$ESP_MNT$sys_dir/mmx64.efi" ]]; then
            efi_sig_strict_ok "$ESP_MNT$sys_dir/mmx64.efi" || die "Refusing to repin: mmx64.efi signature not strict"
        fi

        local -a rels=( "$sys_dir/shimx64.efi" "$sys_dir/grubx64.efi" )
        [[ "$ESP_CFG_MODE" == external ]] && rels+=( "$sys_dir/grub.cfg" )
        if [[ "$KEEP_MMX" -eq 1 && -f "$ESP_MNT$sys_dir/mmx64.efi" ]]; then
            rels+=( "$sys_dir/mmx64.efi" )
        fi

        local rel trc
        for rel in "${rels[@]}"; do
            set +e
            verify_pin_one "$rel" >/dev/null 2>&1
            trc=$?
            set -e
            case "$trc" in
                0) ok "No repin needed: $rel" ;;
                1) warn "Repinning mismatched: $rel"; write_pin_one "$rel" ;;
                2) warn "Initializing missing pin: $rel"; write_pin_one "$rel" ;;
                *) die "Unexpected pin check rc=$trc for $rel" ;;
            esac
        done

        if [[ "$ESP_CFG_MODE" == embedded ]]; then
            local obsolete_pin
            obsolete_pin="$(pin_path_for_rel "$sys_dir/grub.cfg")"
            if [[ -f "$obsolete_pin" ]]; then
                warn "Removing obsolete ESP grub.cfg pin: $obsolete_pin"
                run rm -f -- "$obsolete_pin"
            fi
        fi

        # Pins are part of the active trust state.  Remove stale entries from
        # previous EFI vendor ids or retired files so they cannot be mistaken
        # for an active rollback target.
        local pin keep rel
        while IFS= read -r -d '' pin; do
            keep=0
            for rel in "${rels[@]}"; do
                [[ "$pin" == "$(pin_path_for_rel "$rel")" ]] && keep=1 && break
            done
            if [[ "$keep" -eq 0 ]]; then
                warn "Removing obsolete pin: $pin"
                run rm -f -- "$pin"
            fi
        done < <(find "$PIN_DIR" -maxdepth 1 -type f -name '*.sha256' -print0 | sort -z)

        log "=== FIX DONE (pins-strict) ==="
    }

    # ==============================================================================
    # NVRAM boot entry policy (ONLY SHIM):
    # ==============================================================================
    nvram_norm() { tr '[:upper:]' '[:lower:]'; }

    nvram_want_path_shim() {
        local efi_id="$1"
        printf '\\EFI\\%s\\shimx64.efi' "$efi_id"
    }

    nvram_get_esp_disk_part() {
        local src dev pk part base
        src="$(findmnt -T "$ESP_MNT" -nro SOURCE 2>/dev/null | sed '/^$/d;1q' | tr -d '\r' || true)"
        [[ -n "$src" ]] || die "NVRAM: cannot determine ESP source via findmnt for $ESP_MNT"

        dev="$(readlink -f -- "$src" 2>/dev/null | sed '/^$/d;1q' | tr -d '\r' || true)"
        [[ -n "$dev" ]] || dev="$src"
        [[ -b "$dev" ]] || die "NVRAM: ESP source is not a block device: $dev"

        pk="$(lsblk -nro PKNAME -- "$dev" 2>/dev/null | sed '/^$/d;1q' | tr -d '\r' || true)"
        [[ -n "$pk" ]] || die "NVRAM: cannot detect parent disk (PKNAME) for ESP dev: $dev"

        part="$(lsblk -nro PARTNUM -- "$dev" 2>/dev/null | sed '/^$/d;1q' | tr -d '\r' || true)"
        if [[ ! "$part" =~ ^[0-9]+$ ]]; then
            base="$(basename -- "$dev")"
            [[ -r "/sys/class/block/$base/partition" ]] && part="$(cat "/sys/class/block/$base/partition" 2>/dev/null | tr -d '\r' | sed '/^$/d;1q' || true)"
        fi
        [[ "$part" =~ ^[0-9]+$ ]] || die "NVRAM: cannot detect partition number for ESP dev: $dev (got: ${part:-empty})"
        printf '/dev/%s\t%s\n' "$pk" "$part"
    }

    nvram_parse_entry_line() {
        local line="$1"
        [[ "$line" =~ ^Boot([0-9A-Fa-f]{4})\*?[[:space:]] ]] || return 1
        local bn="${BASH_REMATCH[1]}"

        local rest label path
        rest="${line#Boot$bn}"
        [[ "$rest" == \** ]] && rest="${rest#\*}"
        rest="$(trim_ws "$rest")"

        path=""
        if [[ "$line" == *"File("* ]]; then
            path="${line#*File(}"
            path="${path%%)*}"
        fi

        if [[ "$rest" == *$'\t'* ]]; then
            label="${rest%%$'\t'*}"
        elif [[ "$rest" == *HD\(* ]]; then
            label="${rest%%HD(*}"
        elif [[ "$rest" == */File\(* ]]; then
            label="${rest%%/File(*}"
        else
            label="$rest"
        fi
        label="$(trim_ws "$label")"

        printf '%s\t%s\t%s\n' "$bn" "$label" "$path"
    }

    nvram_list_entries() {
        local line
        while IFS= read -r line; do
            [[ "$line" =~ ^Boot[0-9A-Fa-f]{4} ]] || continue
            nvram_parse_entry_line "$line" || true
        done < <(efibootmgr -v 2>/dev/null || true)
    }

    nvram_get_bootorder_csv() {
        local line
        while IFS= read -r line; do
            if [[ "$line" == BootOrder:* ]]; then
                line="${line#BootOrder:}"
                printf '%s\n' "$(trim_ws "$line")"
                return 0
            fi
        done < <(efibootmgr 2>/dev/null || true)
        return 1
    }

    nvram_delete_bootnum() {
        local bn="$1"
        [[ "$bn" =~ ^[0-9A-Fa-f]{4}$ ]] || die "NVRAM: refusing to delete non-bootnum: $bn"
        warn "NVRAM: deleting Boot$bn"
        run efibootmgr -b "$bn" -B >/dev/null
    }

    nvram_is_firmware_record() {
        # Firmware utility entries are not alternate OS loaders. OVMF uses
        # labels such as these for its built-in setup applications; many
        # physical systems expose equivalent labels. A bare GUID is the
        # FvFile payload printed by efibootmgr for the same class of entry.
        local label="$1" path="$2" normalized
        normalized="$(printf '%s' "$label" | nvram_norm | tr -s '[:space:]' ' ')"
        case "$normalized" in
            bootmanagermenuapp|efi\ firmware\ setup|uefi\ firmware\ setup|\
                firmware\ setup|uefi\ firmware\ settings)
                return 0
                ;;
        esac
        [[ "$path" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]
    }

    nvram_get_bootorder_first() {
        local order first
        order="$(nvram_get_bootorder_csv || true)"
        [[ -n "$order" ]] || return 1
        first="${order%%,*}"
        first="$(printf '%s' "$first" | tr -d '[:space:]')"
        [[ "$first" =~ ^[0-9A-Fa-f]{4}$ ]] || return 1
        printf '%s\n' "$first"
    }

    nvram_find_shim_entry_bn() {
        local want_path="$1"
        local bn label path
        while IFS=$'\t' read -r bn label path; do
            local pnorm; pnorm="$(printf '%s' "$path" | nvram_norm)"
            if [[ "$pnorm" == "$(printf '%s' "$want_path" | nvram_norm)" ]]; then
                printf '%s\n' "$bn"
                return 0
            fi
        done < <(nvram_list_entries)
        printf '%s\n' ""
        return 0
    }

    nvram_verify_policy() {
        local efi_id="$1"
        local want_path; want_path="$(nvram_want_path_shim "$efi_id")"

        local bn_keep=""
        local extra=0
        local firmware_records=0
        local bn label path

        while IFS=$'\t' read -r bn label path; do
            local pnorm; pnorm="$(printf '%s' "$path" | nvram_norm)"
            if [[ "$pnorm" == "$(printf '%s' "$want_path" | nvram_norm)" ]]; then
                bn_keep="$bn"
            elif nvram_is_firmware_record "$label" "$path"; then
                firmware_records=$((firmware_records + 1))
            else
                extra=$((extra + 1))
            fi
        done < <(nvram_list_entries)

        local rc=0
        if [[ -n "$bn_keep" ]]; then
            ok "NVRAM: shim entry OK: Boot$bn_keep -> $want_path"
        else
            fail "NVRAM: missing shim entry -> $want_path"
            rc=1
        fi

        if [[ "$firmware_records" -gt 0 ]]; then
            ok "NVRAM: firmware utility records retained: $firmware_records"
        fi
        if [[ "$extra" -gt 0 ]]; then
            warn "NVRAM: non-primary Boot#### records retained: $extra (Secure Boot still authenticates selected EFI images)"
        fi

        if [[ -n "$bn_keep" ]]; then
            local bo first
            bo="$(nvram_get_bootorder_csv || true)"
            first="$(nvram_get_bootorder_first || true)"
            if [[ "$(printf '%s' "$first" | nvram_norm)" == "$(printf '%s' "$bn_keep" | nvram_norm)" ]]; then
                ok "NVRAM: shim is first in BootOrder: $bo"
            else
                fail "NVRAM: BootOrder BAD: $bo (shim must be first: $bn_keep)"
                rc=1
            fi
        fi

        return "$rc"
    }

    nvram_fix_policy() {
        local efi_id="$1"
        log "=== FIX BEGIN (nvram) ==="

        local want_path; want_path="$(nvram_want_path_shim "$efi_id")"
        local want_label="${NVRAM_LABEL:-sb-shim}"

        local disk part
        IFS=$'\t' read -r disk part < <(nvram_get_esp_disk_part)

        local bn_keep=""
        local bn label path
        local -a purge_bns=()

        while IFS=$'\t' read -r bn label path; do
            local pnorm; pnorm="$(printf '%s' "$path" | nvram_norm)"
            if [[ "$pnorm" == "$(printf '%s' "$want_path" | nvram_norm)" ]]; then
                bn_keep="$bn"
            elif [[ "$NVRAM_PURGE_FOREIGN" -eq 1 ]] && ! nvram_is_firmware_record "$label" "$path"; then
                purge_bns+=("$bn")
            fi
        done < <(nvram_list_entries)

        if [[ -z "$bn_keep" ]]; then
            warn "NVRAM: creating $want_label -> $want_path"
            run efibootmgr -c -d "$disk" -p "$part" -L "$want_label" -l "$want_path" >/dev/null
            bn_keep="$(nvram_find_shim_entry_bn "$want_path")"
            [[ -n "$bn_keep" ]] || die "NVRAM: failed to create/find shim entry"
        fi

        warn "NVRAM: setting BootOrder to $bn_keep"
        run efibootmgr -o "$bn_keep" >/dev/null

        # Deletion is explicitly opt-in. Firmware recreates fallback records
        # on reboot, and deleting setup entries can remove the normal recovery
        # path. The selected image remains protected by Secure Boot regardless
        # of which unused records are present.
        if [[ "${#purge_bns[@]}" -gt 0 ]]; then
            for bn in "${purge_bns[@]}"; do
                nvram_delete_bootnum "$bn"
            done
            warn "NVRAM: purged ${#purge_bns[@]} non-firmware records"
        else
            ok "NVRAM: retained non-primary records; shim remains first"
        fi

        ok "NVRAM: policy enforced (shim first; firmware records retained)"
        log "=== FIX DONE (nvram) ==="
    }

    fix_nvram() {
        ensure_esp_mounted
        local efi_id; efi_id="$(detect_efi_id)"
        nvram_fix_policy "$efi_id"
    }

    # ==============================================================================
    # ESP "golden" files regen (copy from sources, NOT grub-install)
    # ==============================================================================
    detect_shim_sources() {
        # HARD-CODE: shim always comes from golden
        SHIM_SRC="$STATE_ROOT/golden/shimx64.efi"

        [[ -f "$SHIM_SRC" ]] || die "Golden shim missing: $SHIM_SRC (build it via sb-shim-rebuild)"
        ok "shim source (golden): $SHIM_SRC"

        # MMX is optional; only needed if KEEP_MMX=1 and REFRESH_MMX=1
        if [[ "$KEEP_MMX" -eq 1 && "$REFRESH_MMX" -eq 1 ]]; then
            if [[ -z "${MMX_SRC:-}" ]]; then
                MMX_SRC="$(find /usr/lib -maxdepth 3 -type f \( -name 'mmx64.efi.signed' -o -name 'mmx64.efi' \) 2>/dev/null | head -n1 || true)"
            fi
            [[ -n "${MMX_SRC:-}" && -f "$MMX_SRC" ]] || die "Cannot find mmx source (set MMX_SRC=... or install shim-signed)"
            ok "mmx source:  $MMX_SRC"
        fi
    }

    stage_signed_efi() {
        local src="$1"
        local out="$2"
        local work="${out}.work"
        [[ -s "$src" ]] || die "Missing EFI source: $src"
        ensure_db_cert_pem
        run cp -a "$src" "$work"
        run sbattach --remove "$work" >/dev/null 2>&1 || true
        run sbsign --key "$DB_KEY" --cert "$DB_CRT_PEM" --output "$out" "$work" >/dev/null
        rm -f -- "$work"
        efi_sig_strict_ok "$out" || die "Staged EFI verification failed: $out"
    }

    profile_get() {
        local key="$1"
        [[ -s "$GRUB_PROFILE_ENV" ]] || return 0
        sed -n "s/^${key}=//p" "$GRUB_PROFILE_ENV" | sed '/^$/d;1q'
    }

    installed_grub_version() {
        dpkg-query -W -f='${Version}\n' grub-efi-amd64-bin 2>/dev/null \
            | sed '/^$/d;1q'
    }

    profile_modules_sha256() {
        # Hash relative paths so the value is stable when the profile is moved
        # atomically from a temporary staging directory into its final location.
        (
            cd -- "$1"
            find . -type f -name '*.mod' -print0 \
                | sort -z \
                | xargs -0r sha256sum \
                | sha256sum \
                | awk '{print $1}'
        )
    }

    verify_grub_module_closure() (
        local module_dir="$1" module_list="$2" module saved_ifs
        [[ -d "$module_dir" ]] || die "Missing GRUB module directory: $module_dir"
        saved_ifs="$IFS"
        IFS=$' \n\t'
        for module in $module_list; do
            [[ -f "$module_dir/$module.mod" ]] \
                || die "GRUB module closure missing: $module_dir/$module.mod"
        done
        IFS="$saved_ifs"
        ok "GRUB module closure OK"
    )

    build_trusted_grub_efi() {
        local out="$1" early_cfg early_sig sbat unsigned luks_uuid boot_uuid boot_lvmid gpg_id modules module_list_sha256
        local grub_tool grub_dir sbat_source profile_version installed_version
        local profile_sbat_source profile_builder_sha profile_modules_sha profile_module_list_sha profile_sbat_sha
        early_cfg="$ESP_STAGE_DIR/grub-early.cfg"
        early_sig="$early_cfg.sig"
        sbat="$ESP_STAGE_DIR/grub.sbat"
        unsigned="$ESP_STAGE_DIR/grubx64.unsigned.efi"

        require_cmd dpkg-query
        require_cmd objcopy
        require_cmd gpg
        [[ -s "$GRUB_GPG_BACKUP_FILE" ]] \
            || die "Missing GPG public key for GRUB embedding: $GRUB_GPG_BACKUP_FILE"

        case "$GRUB_BUILD_MODE" in
            packaged)
                grub_tool="$(command -v grub-mkstandalone)"
                grub_dir="/usr/lib/grub/x86_64-efi"
                sbat_source="$GRUB_MONOLITH"
                ;;
            profile)
                [[ -s "$GRUB_PROFILE_ENV" ]] \
                    || die "Missing isolated GRUB profile metadata: $GRUB_PROFILE_ENV"
                [[ "$(profile_get cli_mode)" == "interactive" ]] \
                    || die "GRUB profile does not declare interactive CLI mode"
                profile_version="$(profile_get grub_package_version)"
                installed_version="$(installed_grub_version)"
                [[ -n "$profile_version" && "$profile_version" == "$installed_version" ]] \
                    || die "GRUB profile version mismatch (profile=${profile_version:-empty} installed=${installed_version:-empty})"
                grub_tool="${GRUB_BUILD_PROFILE}/bin/grub-mkstandalone"
                grub_dir="${GRUB_BUILD_PROFILE}/lib/grub/x86_64-efi"
                profile_sbat_source="$(profile_get sbat_source)"
                if [[ -n "$profile_sbat_source" ]]; then
                    sbat_source="$GRUB_BUILD_PROFILE/$profile_sbat_source"
                else
                    sbat_source="$GRUB_BUILD_PROFILE/monolithic/grubx64.efi"
                fi
                [[ -x "$grub_tool" ]] || die "Missing isolated GRUB builder: $grub_tool"
                [[ -d "$grub_dir" ]] || die "Missing isolated GRUB module directory: $grub_dir"
                [[ -s "$sbat_source" ]] || die "Missing isolated GRUB SBAT source: $sbat_source"
                profile_builder_sha="$(profile_get builder_sha256)"
                profile_modules_sha="$(profile_get modules_tree_sha256)"
                profile_module_list_sha="$(profile_get module_list_sha256)"
                profile_sbat_sha="$(profile_get sbat_sha256)"
                [[ "$profile_builder_sha" =~ ^[[:xdigit:]]{64}$ ]] \
                    || die "GRUB profile metadata lacks builder_sha256"
                [[ "$profile_modules_sha" =~ ^[[:xdigit:]]{64}$ ]] \
                    || die "GRUB profile metadata lacks modules_tree_sha256"
                [[ "$profile_module_list_sha" =~ ^[[:xdigit:]]{64}$ ]] \
                    || die "GRUB profile metadata lacks module_list_sha256"
                [[ "$profile_sbat_sha" =~ ^[[:xdigit:]]{64}$ ]] \
                    || die "GRUB profile metadata lacks sbat_sha256"
                [[ "$(sha256_file "$grub_tool")" == "$profile_builder_sha" ]] \
                    || die "GRUB profile builder hash mismatch"
                [[ "$(profile_modules_sha256 "$grub_dir")" == "$profile_modules_sha" ]] \
                    || die "GRUB profile module tree hash mismatch"
                [[ "$(sha256_file "$sbat_source")" == "$profile_sbat_sha" ]] \
                    || die "GRUB profile SBAT source hash mismatch"
                log "Using isolated GRUB profile (version=$profile_version, interactive CLI enabled)"
                ;;
            *)
                die "Unknown GRUB_BUILD_MODE: $GRUB_BUILD_MODE (expected packaged or profile)"
                ;;
        esac

        [[ -x "$grub_tool" ]] || die "Missing GRUB builder: $grub_tool"
        [[ -s "$sbat_source" ]] || die "Missing GRUB SBAT source: $sbat_source"

        luks_uuid="$(stub_luks_uuid)"
        boot_uuid="$(stub_boot_uuid)"
        boot_lvmid="$(stub_boot_lvmid)"
        render_stub_cfg "$luks_uuid" "$boot_uuid" "$boot_lvmid" >"$early_cfg"

        # --pubkey enables signature enforcement before the embedded config
        # runs.  Therefore the embedded config must be shipped together with
        # its detached GPG signature (the same pattern used by the tested
        # Debian/ACRN implementations).
        gpg_id="$(gpg_fpr || true)"
        [[ -n "$gpg_id" ]] || die "Missing GPG signing key for embedded GRUB config"
        run gpg --homedir "$GPG_HOME" --batch --yes \
            --pinentry-mode loopback --passphrase '' \
            --local-user "$gpg_id" --digest-algo SHA512 \
            --detach-sign --output "$early_sig" "$early_cfg" >/dev/null 2>&1
        gpg --homedir "$GPG_HOME" --verify "$early_sig" "$early_cfg" >/dev/null 2>&1 \
            || die "GPG verify failed for embedded GRUB config"

        objcopy --dump-section .sbat="$sbat" "$sbat_source" "$ESP_STAGE_DIR/grub-sbat-source.efi"
        [[ -s "$sbat" ]] || die "GRUB source image has no usable SBAT section"

        # Debian's GnuPG signatures are SHA-512; retain SHA-256 as well for
        # existing runtime artifacts.  diskfilter is required by the GRUB
        # LVM path used by encrypted /boot.  memdisk/tar are included for
        # standalone graft-point handling.
        # Keep only the UEFI GOP video path.  all_video would probe every
        # available framebuffer backend (including Bochs/Cirrus/UGA), which
        # can corrupt the framebuffer after the LUKS hand-off.
        modules="part_gpt diskfilter crypto extcmd test procfs cryptodisk afsplitter \
luks2 json lvm ext2 fshelp gcry_rijndael gcry_sha1 gcry_sha256 \
gcry_sha512 gcry_rsa mpi pbkdf2 pgp configfile search search_fs_file \
search_fs_uuid search_label echo reboot sleep normal boot bufio datetime \
net priority_queue terminal linux mmap relocator memdisk tar archelp font \
video video_fb gfxterm gettext gzio gcry_crc bli efi_gop"
        if [[ "$GRUB_BUILD_MODE" == profile ]]; then
            module_list_sha256="$(printf '%s\n' "$modules" | tr ' ' '\n' | sed '/^$/d' | sha256sum | awk '{print $1}')"
            [[ "$module_list_sha256" == "$profile_module_list_sha" ]] \
                || die "GRUB profile module list hash mismatch"
        fi
        verify_grub_module_closure "$grub_dir" "$modules"
        "$grub_tool" \
            --directory="$grub_dir" \
            --format=x86_64-efi \
            --output="$unsigned" \
            --compress=xz \
            --install-modules="$modules" \
            --modules="$modules" \
            --pubkey="$GRUB_GPG_BACKUP_FILE" \
            --sbat="$sbat" \
            "boot/grub/grub.cfg=$early_cfg" \
            "boot/grub/grub.cfg.sig=$early_sig"
        [[ -s "$unsigned" ]] || die "grub-mkstandalone did not produce an EFI image"

        stage_signed_efi "$unsigned" "$out"
        {
            printf 'mode=embedded-gpg-trust\n'
            printf 'public_key_sha256=%s\n' "$(sha256_file "$GRUB_GPG_BACKUP_FILE")"
            printf 'early_config_sha256=%s\n' "$(sha256_file "$early_cfg")"
            printf 'early_config_sig_sha256=%s\n' "$(sha256_file "$early_sig")"
            printf 'build_mode=%s\n' "$GRUB_BUILD_MODE"
            printf 'cli_mode=interactive\n'
            printf 'grub_builder=%s\n' "$grub_tool"
            printf 'grub_module_dir=%s\n' "$grub_dir"
            printf 'grub_sbat_source=%s\n' "$sbat_source"
            printf 'grub_sbat_sha256=%s\n' "$(sha256_file "$sbat")"
            printf 'signed_sha256=%s\n' "$(sha256_file "$out")"
        } >"$ESP_STAGE_DIR/grub.state"
        ok "Built GRUB with embedded GPG trust root and early enforcement (interactive CLI enabled)"
    }

    atomic_deploy_efi() {
        local src="$1" dst="$2" dir base tmp
        efi_sig_strict_ok "$src" || die "Refusing unverified staged EFI artifact: $src"
        dir="$(dirname "$dst")"
        base="$(basename "$dst")"
        tmp="$(mktemp -p "$dir" ".${base}.deploy.XXXXXX")"
        trap 'rm -f -- "${tmp:-}" >/dev/null 2>&1 || true' RETURN
        run install -m 0600 -o root -g root "$src" "$tmp"
        efi_sig_strict_ok "$tmp" || die "ESP temporary artifact verification failed: $tmp"
        run mv -f "$tmp" "$dst"
        efi_sig_strict_ok "$dst" || die "ESP deployed artifact verification failed: $dst"
        trap - RETURN
    }

    prepare_esp_artifacts() {
        if [[ "$REFRESH_SHIM" -eq 1 || ( "$KEEP_MMX" -eq 1 && "$REFRESH_MMX" -eq 1 ) ]]; then
            detect_shim_sources
        fi

        ESP_STAGE_DIR="$(mktemp -d -p "$STATE_ROOT" .esp-stage.XXXXXX)"
        run chmod 0700 "$ESP_STAGE_DIR"
        STAGED_GRUB="$ESP_STAGE_DIR/grubx64.efi"
        build_trusted_grub_efi "$STAGED_GRUB"
        if [[ "$REFRESH_SHIM" -eq 1 ]]; then
            efi_sig_strict_ok "$SHIM_SRC" || die "Golden shim is not strict-signed: $SHIM_SRC"
        fi
        if [[ "$KEEP_MMX" -eq 1 && "$REFRESH_MMX" -eq 1 ]]; then
            STAGED_MMX="$ESP_STAGE_DIR/mmx64.efi"
            stage_signed_efi "$MMX_SRC" "$STAGED_MMX"
        fi
        ok "All EFI artifacts staged and verified before ESP write window"
    }

    cleanup_esp_stage() {
        local d="${ESP_STAGE_DIR:-}"
        if [[ -n "$d" && "$d" == "$STATE_ROOT"/.esp-stage.* && -d "$d" ]]; then
            rm -rf --one-file-system "$d"
        fi
        ESP_STAGE_DIR=""
        STAGED_GRUB=""
        STAGED_MMX=""
    }

    cleanup_release_stage() {
        local d="${RELEASE_TMP_DIR:-}"
        if [[ -n "$d" && "$d" == "$STATE_ROOT"/.release-stage.* && -d "$d" ]]; then
            rm -rf --one-file-system "$d"
        fi
        RELEASE_TMP_DIR=""
    }

    stage_release_artifacts() {
        local tmp="$RELEASE_TMP_DIR" out="$RELEASE_OUTPUT_DIR"
        local -a manifest_files=(shimx64.efi grubx64.efi grub.state)
        [[ "$GRUB_BUILD_MODE" == profile ]] \
            || die "Release staging requires the verified profile policy (GRUB_BUILD_MODE=profile)"
        [[ -s "$GRUB_PROFILE_ENV" ]] \
            || die "Release staging requires current profile metadata: $GRUB_PROFILE_ENV"
        [[ "$out" == "$STATE_ROOT/release" ]] \
            || die "Release output is fixed to $STATE_ROOT/release"
        [[ -s "$SHIM_SRC" ]] || die "Missing verified golden shim: $SHIM_SRC"
        efi_sig_strict_ok "$SHIM_SRC" || die "Golden shim is not signed only by our db certificate"
        verify_shim_vendor_cert "$SHIM_SRC" || die "Golden shim vendor certificate is not ours"

        install -d -m 0700 -o root -g root "$STATE_ROOT"
        RELEASE_TMP_DIR="$(mktemp -d -p "$STATE_ROOT" .release-stage.XXXXXX)"
        tmp="$RELEASE_TMP_DIR"
        ESP_STAGE_DIR="$(mktemp -d -p "$STATE_ROOT" .esp-stage.XXXXXX)"
        run chmod 0700 "$ESP_STAGE_DIR"
        STAGED_GRUB="$ESP_STAGE_DIR/grubx64.efi"
        build_trusted_grub_efi "$STAGED_GRUB"
        efi_sig_strict_ok "$STAGED_GRUB" || die "New GRUB failed strict signature verification"
        verify_embedded_stub_cfg "$STAGED_GRUB" "$(stub_luks_uuid)" "$(stub_boot_uuid)" \
            || die "New GRUB embedded stub verification failed"

        install -m 0600 -o root -g root "$SHIM_SRC" "$tmp/shimx64.efi"
        install -m 0600 -o root -g root "$STAGED_GRUB" "$tmp/grubx64.efi"
        install -m 0600 -o root -g root "$ESP_STAGE_DIR/grub.state" "$tmp/grub.state"
        if [[ -s "$GRUB_PROFILE_ENV" ]]; then
            install -m 0600 -o root -g root "$GRUB_PROFILE_ENV" "$tmp/profile.env"
            manifest_files+=(profile.env)
        fi
        (cd "$tmp" && sha256sum "${manifest_files[@]}" >manifest.sha256)
        run chmod 0600 "$tmp/manifest.sha256"
        (cd "$tmp" && sha256sum -c manifest.sha256 >/dev/null) \
            || die "Release manifest verification failed"

        local old_out="${out}.old"
        rm -rf -- "$old_out"
        if [[ -e "$out" ]]; then
            mv -- "$out" "$old_out" || die "Unable to stage previous release bundle"
        fi
        if ! mv -- "$tmp" "$out"; then
            [[ -e "$old_out" ]] && mv -- "$old_out" "$out" || true
            die "Unable to publish release bundle"
        fi
        rm -rf -- "$old_out"
        RELEASE_TMP_DIR=""
        cleanup_esp_stage
        ok "Release ready without ESP changes: $out"
        ok "Signed shim: $out/shimx64.efi"
        ok "Signed GRUB: $out/grubx64.efi"
    }

    verify_release_bundle() {
        local out="$RELEASE_OUTPUT_DIR"
        [[ "$out" == "$STATE_ROOT/release" ]] || die "Release output path is not fixed"
        [[ -s "$out/manifest.sha256" && -s "$out/shimx64.efi" &&
            -s "$out/grubx64.efi" && -s "$out/grub.state" ]] ||
            die "Release bundle is incomplete: $out"
        (cd "$out" && sha256sum -c manifest.sha256 >/dev/null) ||
            die "Release manifest verification failed: $out"
        [[ -s "$out/profile.env" ]] || die "Release bundle has no profile metadata"
        [[ "$(sha256_file "$out/profile.env")" == "$(sha256_file "$GRUB_PROFILE_ENV")" ]] \
            || die "Release profile metadata is not the current installed profile"
        [[ -s "$SHIM_SRC" && "$(sha256_file "$out/shimx64.efi")" == "$(sha256_file "$SHIM_SRC")" ]] \
            || die "Release shim is not the current verified golden shim"
        efi_sig_strict_ok "$out/shimx64.efi" || die "Release shim signature is invalid"
        verify_shim_vendor_cert "$out/shimx64.efi" || die "Release shim vendor certificate is not ours"
        efi_sig_strict_ok "$out/grubx64.efi" || die "Release GRUB signature is invalid"
        verify_grub_sbat_section "$out/grubx64.efi" || die "Release GRUB SBAT is invalid"
        verify_embedded_stub_cfg "$out/grubx64.efi" "$(stub_luks_uuid)" "$(stub_boot_uuid)" ||
            die "Release GRUB embedded stub does not match this host"
        grep -Fxq 'build_mode=profile' "$out/grub.state" ||
            die "Release GRUB was not built from the isolated profile"
        grep -Fxq 'cli_mode=interactive' "$out/grub.state" ||
            die "Release GRUB profile does not allow the standard interactive path"
        grep -Fxq "signed_sha256=$(sha256_file "$out/grubx64.efi")" "$out/grub.state" ||
            die "Release GRUB state hash does not match the release byte stream"
        ok "Release bundle manifest, signatures, SBAT and embedded stub verified"
    }

    apply_release_bundle() {
        local out="$RELEASE_OUTPUT_DIR"
        verify_release_bundle
        ESP_STAGE_DIR="$(mktemp -d -p "$STATE_ROOT" .esp-stage.XXXXXX)"
        run chmod 0700 "$ESP_STAGE_DIR"
        STAGED_GRUB="$ESP_STAGE_DIR/grubx64.efi"
        SHIM_SRC="$out/shimx64.efi"
        REFRESH_SHIM=1
        install -m 0600 -o root -g root "$out/grubx64.efi" "$STAGED_GRUB"
        efi_sig_strict_ok "$STAGED_GRUB" || die "Staged release GRUB verification failed"

        backup_current_esp
        if is_proxmox_installed; then
            EFI_ID_OVERRIDE="proxmox"
            log "ESP migration policy: deploy canonical EFI/proxmox and retire any legacy EFI/debian"
        fi
        esp_rw_begin
        fix_esp_files_from_system
        # Keep EFI/debian until the new files are present and NVRAM points at
        # EFI/proxmox.  This makes an unexpected power loss during migration
        # bootable through the old Debian entry instead of leaving NVRAM aimed
        # at a directory that was already removed.
        fix_nvram
        fix_structure
        fix_stub_cfgs
        fix_structure
        run sync
        esp_rw_end

        VERIFY_PINS=0
        do_verify_full
        VERIFY_PINS=1
        fix_pins
        do_verify_full
        ok "Exact verified release bundle deployed; pins committed"
    }

    fix_esp_files_from_system() {
        log "=== FIX BEGIN (esp-files) ==="
        ensure_esp_mounted
        local efi_id; efi_id="$(detect_efi_id)"
        local sys_dir="$ESP_MNT/EFI/$efi_id"

        [[ -n "$ESP_STAGE_DIR" ]] || prepare_esp_artifacts

        esp_rw_begin
        trap 'esp_rw_end || true' RETURN
        run install -d -m 0700 -o root -g root "$sys_dir"

        # SHIM handling (DO NOT overwrite by default!)
        if [[ "$REFRESH_SHIM" -eq 1 ]]; then
            warn "Atomically deploying verified golden shim: $SHIM_SRC -> $sys_dir/shimx64.efi"
            atomic_deploy_efi "$SHIM_SRC" "$sys_dir/shimx64.efi"
        else
            if [[ -f "$sys_dir/shimx64.efi" ]]; then
                ok "Keeping existing shim on ESP (REFRESH_SHIM=0): $sys_dir/shimx64.efi"
            else
                die "shim missing on ESP: $sys_dir/shimx64.efi (set --refresh-shim to install it)"
            fi
        fi

        warn "Atomically deploying staged signed grub: $STAGED_GRUB -> $sys_dir/grubx64.efi"
        atomic_deploy_efi "$STAGED_GRUB" "$sys_dir/grubx64.efi"

        # MMX handling
        if [[ "$KEEP_MMX" -eq 1 ]]; then
            if [[ "$REFRESH_MMX" -eq 1 ]]; then
                [[ -n "${MMX_SRC:-}" && -f "$MMX_SRC" ]] || die "MMX_SRC missing/invalid (set MMX_SRC=...)"
                warn "Atomically deploying staged signed mmx: $STAGED_MMX -> $sys_dir/mmx64.efi"
                atomic_deploy_efi "$STAGED_MMX" "$sys_dir/mmx64.efi"
            else
                if [[ -f "$sys_dir/mmx64.efi" ]]; then
                    ok "Keeping existing mmx on ESP (REFRESH_MMX=0): $sys_dir/mmx64.efi"
                else
                    die "KEEP_MMX=1 but mmx64.efi missing on ESP. Either set --refresh-mmx with MMX_SRC, or set --no-mmx."
                fi
            fi
        else
            run rm -f "$sys_dir/mmx64.efi" >/dev/null 2>&1 ||
                die "Could not remove stale mmx64.efi from ESP"
        fi

        run sync
        esp_rw_end
        trap - RETURN
        cleanup_esp_stage

        ok "ESP files updated."
        log "=== FIX DONE (esp-files) ==="
    }

    # ==============================================================================
    # Test helper (break signatures)
    # ==============================================================================
    break_signatures() {
        log "=== BREAK BEGIN (efi signatures) ==="
        ensure_esp_mounted
        local efi_id; efi_id="$(detect_efi_id)"
        local shim_efi="$ESP_MNT/EFI/$efi_id/shimx64.efi"

        esp_rw_begin
        trap 'esp_rw_end || true' RETURN

        warn "Breaking signature (removing table): $shim_efi"
        run sbattach --remove "$shim_efi" >/dev/null 2>&1 || true
        run sync

        esp_rw_end
        trap - RETURN
        log "=== BREAK DONE (efi signatures) ==="
    }

    # ==============================================================================
    # State dirs + REQUIRED keys (no generation)
    # ==============================================================================
    ensure_state_dirs() {
        run install -d -m 0700 -o root -g root "$STATE_ROOT" "$KEY_DIR" "$PIN_DIR"
        run install -d -m 0700 -o root -g root "$STATE_ROOT/gpg" "$STATE_ROOT/backups" "$ESP_BACKUP_DIR"
        run install -d -m 0700 -o root -g root "$STATE_ROOT/keys/grub"
    }

    fix_keys() {
        log "=== FIX BEGIN (uefi-keys) ==="
        ensure_state_dirs
        if verify_keys_present; then
            ok "UEFI keys already present; nothing to do"
            log "=== FIX DONE (uefi-keys) ==="
            return 0
        fi
        die "UEFI keys missing in $KEY_DIR. Run: sb-install --init-uefi-keys"
    }

    # ==============================================================================
    # GPG layer
    # ==============================================================================
    GPG_HOME="${GPG_HOME:-$STATE_ROOT/gpg}"
    GPG_FPR_FILE="${GPG_FPR_FILE:-$GPG_HOME/key.fpr}"

    GRUB_KEYS_DIR="${GRUB_KEYS_DIR:-/boot/grub/keys}"
    GRUB_GPG_KEY_FILE="${GRUB_GPG_KEY_FILE:-$GRUB_KEYS_DIR/sb-guard.gpg}"
    GRUB_GPG_BACKUP_FILE="${GRUB_GPG_BACKUP_FILE:-$STATE_ROOT/keys/grub/sb-guard.gpg}"

    GRUB_SNIPPET="${GRUB_SNIPPET:-/etc/grub.d/06_sb_gpg_verify}"
    # Legacy gfxterm workaround path.  Current policy removes this generator
    # and keeps GRUB on the firmware-native terminal because gfxterm/GOP is
    # unreliable on some physical UEFI implementations.
    GRUB_VIDEO_INIT_SNIPPET="${GRUB_VIDEO_INIT_SNIPPET:-/etc/grub.d/000_sb_guard_video_init}"
    GPG_MODE="${GPG_MODE:-enforce}"  # warn|enforce

    gpg_fpr() { [[ -s "$GPG_FPR_FILE" ]] && cat "$GPG_FPR_FILE" && return 0; return 1; }

    gpg_require_present() {
        [[ -d "$GPG_HOME" ]] || die "GPG key missing. Run: sb-install --init-gpg-keys"
        [[ -s "$GPG_FPR_FILE" ]] || die "GPG key missing (no $GPG_FPR_FILE). Run: sb-install --init-gpg-keys"
        local fpr; fpr="$(gpg_fpr || true)"
        [[ -n "$fpr" ]] || die "GPG key missing (empty fpr). Run: sb-install --init-gpg-keys"
        gpg --homedir "$GPG_HOME" --list-secret-keys --with-colons "$fpr" 2>/dev/null | grep -q '^sec:' \
            || die "GPG secret key missing. Run: sb-install --init-gpg-keys"
        ok "GPG key present (fpr=$fpr)"
    }

    gpg_export_pub_to_boot_and_backup() {
        run install -d -m 0700 -o root -g root "$GRUB_KEYS_DIR"
        run install -d -m 0700 -o root -g root "$(dirname "$GRUB_GPG_BACKUP_FILE")"

        if [[ ! -f "$GRUB_GPG_KEY_FILE" && -f "$GRUB_GPG_BACKUP_FILE" ]]; then
            run install -m 0600 -o root -g root "$GRUB_GPG_BACKUP_FILE" "$GRUB_GPG_KEY_FILE"
            ok "Restored GRUB public key from backup: $GRUB_GPG_KEY_FILE"
            return 0
        fi

        local fpr tmp
        fpr="$(gpg_fpr || true)"
        [[ -n "$fpr" ]] || die "GPG key missing. Run: sb-install --init-gpg-keys"

        tmp="$(mktemp)"
        run gpg --homedir "$GPG_HOME" --batch --yes --export "$fpr" >"$tmp"

        if [[ -f "$GRUB_GPG_KEY_FILE" ]]; then
            if ! cmp -s "$tmp" "$GRUB_GPG_KEY_FILE"; then
                run install -m 0600 -o root -g root "$tmp" "$GRUB_GPG_KEY_FILE"
                ok "Updated GRUB public key: $GRUB_GPG_KEY_FILE"
            fi
        else
            run install -m 0600 -o root -g root "$tmp" "$GRUB_GPG_KEY_FILE"
            ok "Exported GRUB public key: $GRUB_GPG_KEY_FILE"
        fi

        if [[ -f "$GRUB_GPG_BACKUP_FILE" ]]; then
            if ! cmp -s "$tmp" "$GRUB_GPG_BACKUP_FILE"; then
                run install -m 0600 -o root -g root "$tmp" "$GRUB_GPG_BACKUP_FILE"
                ok "Updated GRUB public key backup: $GRUB_GPG_BACKUP_FILE"
            else
                ok "GRUB public key matches backup"
            fi
        else
            run install -m 0600 -o root -g root "$tmp" "$GRUB_GPG_BACKUP_FILE"
            ok "Created GRUB public key backup: $GRUB_GPG_BACKUP_FILE"
        fi

        rm -f -- "$tmp"
    }

    grub_install_gpg_snippet() {
        local mode="${1:-enforce}"
        [[ "$mode" == "warn" || "$mode" == "enforce" ]] || die "Bad gpg mode: $mode"
        local keyname; keyname="$(basename "$GRUB_GPG_KEY_FILE")"

        if write_file_if_changed "$GRUB_SNIPPET" <<GRUB_SNIPPET
    #!/bin/sh
    set -e
    cat <<'GRUB_EOF'
    # sb-guard: GRUB GPG verification
    if [ -f \${prefix}/keys/${keyname} ]; then
        insmod gcry_sha256
        insmod gcry_sha512
        insmod gcry_rsa
        insmod pgp
        trust \${prefix}/keys/${keyname}
        set check_signatures=${mode}
        export check_signatures
    fi
    GRUB_EOF
    GRUB_SNIPPET
        then
            run chmod 0755 "$GRUB_SNIPPET"
            ok "Updated GRUB GPG snippet: $GRUB_SNIPPET (mode=$mode)"
            return 0
        fi

        ok "GRUB GPG snippet OK; skipping rewrite"
        return 1
    }

    grub_remove_video_init_snippet() {
        if [[ -e "$GRUB_VIDEO_INIT_SNIPPET" ]]; then
            run rm -f -- "$GRUB_VIDEO_INIT_SNIPPET"
            ok "Removed obsolete GRUB gfxterm initialization workaround"
            return 0
        fi
        return 1
    }

    grub_cfg_has_expected() {
        local mode="${1:-enforce}"
        [[ -f /boot/grub/grub.cfg ]] || return 1
        local keyname; keyname="$(basename "$GRUB_GPG_KEY_FILE")"
        grep -qF 'sb-guard: GRUB GPG verification' /boot/grub/grub.cfg || return 1

        # Require pgp module; forbid gpg module (often no gpg.mod, only pgp.mod)
        grep -qE "^[[:space:]]*insmod[[:space:]]+pgp\b" /boot/grub/grub.cfg || return 1
        if grep -qE "^[[:space:]]*insmod[[:space:]]+gpg\b" /boot/grub/grub.cfg; then
            return 1
        fi

        grep -qF "trust \${prefix}/keys/${keyname}" /boot/grub/grub.cfg || return 1
        grep -qE "^[[:space:]]*set[[:space:]]+check_signatures=${mode}\b" /boot/grub/grub.cfg || return 1
        return 0
    }

    # Use the firmware-native terminal.  Forcing gfxterm/GOP after LUKS unlock
    # causes corrupted glyphs on affected GRUB 2.12 + UEFI firmware.  Keeping
    # efi_gop as the sole load_video backend avoids invalid legacy module probes
    # without switching terminal_output away from the native terminal.
    readonly GRUB_VIDEO_BACKEND_POLICY="efi_gop"

    grub_defaults_set() {
        local key="$1"
        local value="$2"
        local file="/etc/default/grub"
        local tmp

        [[ -f "$file" ]] || die "Missing GRUB defaults: $file"
        tmp="$(mktemp "${file}.sb-guard.XXXXXX")"
        awk -v k="$key" -v v="$value" '
            BEGIN { done = 0 }
            $0 ~ "^[[:space:]]*" k "=" {
                if (!done) { print k "=" v; done = 1 }
                next
            }
            { print }
            END { if (!done) print k "=" v }
        ' "$file" >"$tmp"
        if ! cmp -s "$tmp" "$file"; then
            if [[ ! -e "$STATE_ROOT/backups/etc-default-grub.pre-display" ]]; then
                run cp -a "$file" "$STATE_ROOT/backups/etc-default-grub.pre-display"
            fi
            run install -m 0644 -o root -g root "$tmp" "$file"
            ok "Updated GRUB display policy: $key"
        fi
        rm -f -- "$tmp"
    }

    grub_defaults_unset() {
        local key="$1"
        local file="/etc/default/grub"
        local tmp

        [[ -f "$file" ]] || die "Missing GRUB defaults: $file"
        tmp="$(mktemp "${file}.sb-guard.XXXXXX")"
        awk -v k="$key" '$0 !~ "^[[:space:]]*" k "=" { print }' "$file" >"$tmp"
        if ! cmp -s "$tmp" "$file"; then
            if [[ ! -e "$STATE_ROOT/backups/etc-default-grub.pre-display" ]]; then
                run cp -a "$file" "$STATE_ROOT/backups/etc-default-grub.pre-display"
            fi
            run install -m 0644 -o root -g root "$tmp" "$file"
            ok "Removed forced GRUB display setting: $key"
        fi
        rm -f -- "$tmp"
    }

    ensure_grub_display_policy() {
        grub_defaults_unset GRUB_GFXMODE
        # grub-mkconfig defaults to gfxterm when this key is absent on the
        # current Proxmox package, so select its native console explicitly.
        grub_defaults_set GRUB_TERMINAL_OUTPUT '"console"'
        grub_defaults_unset GRUB_TERMINAL
        # If a Linux menu entry calls load_video, constrain it to the UEFI GOP
        # module already embedded in the signed image.  This does not activate
        # gfxterm and does not replace the firmware-native terminal.
        grub_defaults_set GRUB_VIDEO_BACKEND "$GRUB_VIDEO_BACKEND_POLICY"
    }

    grub_cfg_has_display_policy() {
        [[ -f /boot/grub/grub.cfg ]] || return 1
        grep -qE '^[[:space:]]+insmod[[:space:]]+efi_gop[[:space:]]*$' /boot/grub/grub.cfg || return 1
        # Native terminal only: no gfxterm switch, forced graphics mode, or
        # external/legacy video-module fallback is permitted.
        ! grep -qE '^[[:space:]]*set[[:space:]]+gfxmode=' /boot/grub/grub.cfg || return 1
        ! grep -qE '^[[:space:]]*terminal_output[[:space:]]+gfxterm([[:space:]]|$)' /boot/grub/grub.cfg || return 1
        grep -qE '^[[:space:]]*terminal_output[[:space:]]+console[[:space:]]*$' /boot/grub/grub.cfg || return 1
        ! grep -qE '^[[:space:]]+insmod[[:space:]]+(all_video|efi_uga|ieee1275_fb|vbe|vga|video_bochs|video_cirrus)([[:space:]]|$)' /boot/grub/grub.cfg || return 1
        [[ ! -e "$GRUB_VIDEO_INIT_SNIPPET" ]] || return 1
    }

    grub_cfg_has_no_debug_output() {
        [[ -f /boot/grub/grub.cfg ]] || return 1
        ! grep -qE '^[[:space:]]*set[[:space:]]+(debug|pager)=' /boot/grub/grub.cfg
    }

    gpg_sig_ok() {
        local f="$1"
        local fpr; fpr="$(gpg_fpr || true)"
        [[ -n "$fpr" ]] || return 1
        [[ -f "$f.sig" ]] || return 1
        gpg --homedir "$GPG_HOME" --verify "$f.sig" "$f" >/dev/null 2>&1
    }

    gpg_sign_one() {
        local f="$1"
        [[ -f "$f" ]] || return 0
        [[ "$f" == *.sig ]] && return 0  # no sig.sig ever
        local fpr; fpr="$(gpg_fpr || true)"
        [[ -n "$fpr" ]] || die "GPG key missing. Run: sb-install --init-gpg-keys"

        run gpg --homedir "$GPG_HOME" --batch --yes \
            --pinentry-mode loopback --passphrase '' \
            --local-user "$fpr" --detach-sign --output "${f}.sig" "$f" >/dev/null 2>&1
        run chmod 0644 "${f}.sig"
    }

    gpg_ensure_sig_one() {
        local f="$1"
        [[ -f "$f" ]] || return 0
        [[ "$f" == *.sig ]] && return 0  # no sig.sig ever

        if gpg_sig_ok "$f"; then
            ok "SIG OK: $f"
            return 0
        fi

        warn "SIG FIX: $f"
        gpg_sign_one "$f"
        gpg_sig_ok "$f" || die "GPG verify failed after signing: $f"
        ok "SIG FIXED: $f"
    }

    # ------------------------------------------------------------------------------
    # NEW: collect "everything GRUB loads from disk" and enforce GPG .sig for it
    # ------------------------------------------------------------------------------
    grub_cfg_list_insmod_names() {
        local cfg="/boot/grub/grub.cfg"
        [[ -f "$cfg" ]] || die "Missing: $cfg"
        grep -E '^[[:space:]]*insmod[[:space:]]+' "$cfg" 2>/dev/null \
            | sed -E 's/^[[:space:]]*insmod[[:space:]]+([^[:space:]]+).*/\1/' \
            | sed '/^$/d' \
            | sort -u
    }

    grub_cfg_list_loadfont_paths() {
        local cfg="/boot/grub/grub.cfg"
        [[ -f "$cfg" ]] || die "Missing: $cfg"
        grep -E '^[[:space:]]*loadfont[[:space:]]+' "$cfg" 2>/dev/null \
            | sed -E 's/^[[:space:]]*loadfont[[:space:]]+([^[:space:]]+).*/\1/' \
            | sed '/^$/d'
    }

    grub_cfg_list_trust_paths() {
        local cfg="/boot/grub/grub.cfg"
        [[ -f "$cfg" ]] || die "Missing: $cfg"
        grep -E '^[[:space:]]*trust[[:space:]]+' "$cfg" 2>/dev/null \
            | sed -E 's/^[[:space:]]*trust[[:space:]]+([^[:space:]]+).*/\1/' \
            | sed '/^$/d'
    }

    grub_cfg_list_theme_path() {
        local cfg="/boot/grub/grub.cfg"
        [[ -f "$cfg" ]] || die "Missing: $cfg"
        # set theme=...
        grep -E '^[[:space:]]*set[[:space:]]+theme=' "$cfg" 2>/dev/null \
            | sed -E 's/^[[:space:]]*set[[:space:]]+theme=(.*)$/\1/' \
            | head -n1 \
            | sed '/^$/d' || true
    }

    grub_cfg_list_background_image_paths() {
        local cfg="/boot/grub/grub.cfg"
        [[ -f "$cfg" ]] || die "Missing: $cfg"
        # background_image <path>
        grep -E '^[[:space:]]*background_image[[:space:]]+' "$cfg" 2>/dev/null \
            | sed -E 's/^[[:space:]]*background_image[[:space:]]+([^[:space:]]+).*/\1/' \
            | sed '/^$/d'
    }

    grub_cfg_needs_locale() {
        local cfg="/boot/grub/grub.cfg"
        [[ -f "$cfg" ]] || return 1
        grep -qE '^[[:space:]]*insmod[[:space:]]+gettext\b' "$cfg" 2>/dev/null && return 0
        grep -qE '^[[:space:]]*set[[:space:]]+lang=' "$cfg" 2>/dev/null && return 0
        return 1
    }

    theme_list_resources_from_theme_txt() {
        local theme="$1"
        [[ -f "$theme" ]] || return 0
        local d; d="$(dirname "$theme")"
        # pick obvious resource-looking tokens ending with known extensions
        grep -Eo '[A-Za-z0-9_./-]+\.(png|tga|jpg|jpeg|pf2|bmp)' "$theme" 2>/dev/null \
            | while IFS= read -r r; do
                r="$(grub_unquote "$r")"
                if [[ "$r" == /* ]]; then
                    printf '%s\n' "$r"
                else
                    printf '%s\n' "$d/$r"
                fi
                done
    }

    grub_collect_runtime_files() {
        # emits absolute file paths (one per line), WITHOUT any *.sig
        # only for files that actually exist on disk.
        local plat="${GRUB_PLATFORM_DIR:-}"
        [[ -n "$plat" ]] || plat="$(grub_detect_platform_dir)"
        local moddir="$GRUB_PREFIX/$plat"

        # 1) modules referenced by insmod: include only existing *.mod
        local m mp
        while IFS= read -r m; do
            [[ -n "$m" ]] || continue
            [[ "$m" == *.sig ]] && continue
            mp="$moddir/$m.mod"
            if [[ -f "$mp" ]]; then
                printf '%s\n' "$mp"
            else
                # This is normal for dead branches in grub.cfg (e.g. ieee1275_fb on EFI)
                [[ "$TRACE" == "1" ]] && warn "GRUB cfg references module without file (skipping): insmod $m -> $mp"
            fi
        done < <(grub_cfg_list_insmod_names)

        # 2) loadfont files (paths in cfg) - include only if resolvable+exists
        local f rp
        while IFS= read -r f; do
            [[ -n "$f" ]] || continue
            [[ "$f" == *.sig ]] && continue
            if rp="$(grub_resolve_path_try "$f")"; then
                printf '%s\n' "$rp"
            else
                warn "GRUB cfg references loadfont path not found/resolvable (skipping): $f"
            fi
        done < <(grub_cfg_list_loadfont_paths)

        # 3) trusted key(s) (trust ...) - key must exist (and later must have .sig)
        while IFS= read -r f; do
            [[ -n "$f" ]] || continue
            [[ "$f" == *.sig ]] && continue
            if rp="$(grub_resolve_path_try "$f")"; then
                printf '%s\n' "$rp"
            else
                warn "GRUB cfg references trust key not found/resolvable (skipping): $f"
            fi
        done < <(grub_cfg_list_trust_paths)

        # 4) locale files if gettext/lang used
        if grub_cfg_needs_locale; then
            find "$GRUB_PREFIX/locale" -type f -name '*.mo' 2>/dev/null | sort || true
        fi

        # 5) theme + resources
        local theme_raw theme_abs
        theme_raw="$(grub_cfg_list_theme_path || true)"
        if [[ -n "${theme_raw:-}" ]]; then
            if theme_abs="$(grub_resolve_path_try "$theme_raw")"; then
                printf '%s\n' "$theme_abs"
                theme_list_resources_from_theme_txt "$theme_abs" \
                    | while IFS= read -r rp; do
                        [[ -n "$rp" ]] || continue
                        [[ "$rp" == *.sig ]] && continue
                        if [[ -f "$rp" ]]; then
                            printf '%s\n' "$rp"
                        else
                            warn "Theme resource referenced but missing (skipping): $rp"
                        fi
                    done
            else
                warn "Theme set but path not found/resolvable (skipping theme): $theme_raw"
            fi
        fi

        # 6) background_image files
        while IFS= read -r f; do
            [[ -n "$f" ]] || continue
            [[ "$f" == *.sig ]] && continue
            if rp="$(grub_resolve_path_try "$f")"; then
                printf '%s\n' "$rp"
            else
                warn "background_image path not found/resolvable (skipping): $f"
            fi
        done < <(grub_cfg_list_background_image_paths)
    }

    gpg_verify_runtime_files_strict() {
        local f
        while IFS= read -r f; do
            [[ -n "$f" ]] || continue
            [[ "$f" == *.sig ]] && continue

            [[ -f "$f" ]] || die "GRUB runtime file missing: $f"
            [[ -f "$f.sig" ]] || die "Missing signature: $f.sig"
            gpg --homedir "$GPG_HOME" --verify "$f.sig" "$f" >/dev/null 2>&1 || die "GPG verify failed: $f"
            ok "RUNTIME SIG OK: $f"
        done < <(grub_collect_runtime_files | sed '/^$/d' | sort -u)
        ok "GPG: GRUB runtime files signatures OK"
    }

    gpg_ensure_runtime_files_strict() {
        local f
        while IFS= read -r f; do
            [[ -n "$f" ]] || continue
            [[ "$f" == *.sig ]] && continue
            [[ -f "$f" ]] || die "GRUB runtime file missing: $f"
            gpg_ensure_sig_one "$f"
        done < <(grub_collect_runtime_files | sed '/^$/d' | sort -u)
        ok "GPG: GRUB runtime files ensured (.sig present)"
    }

    gpg_ensure_boot_artifacts() {
        [[ -f /boot/grub/grub.cfg ]] || die "/boot/grub/grub.cfg not found"
        gpg_ensure_sig_one /boot/grub/grub.cfg

        local f
        for f in /boot/vmlinuz-* /boot/initrd.img-*; do
            [[ -f "$f" ]] || continue
            [[ "$f" == *.sig ]] && continue
            gpg_ensure_sig_one "$f"
        done
    }

    gpg_verify_boot_artifacts() {
        [[ -f /boot/grub/grub.cfg && -f /boot/grub/grub.cfg.sig ]] || die "Missing grub.cfg signature"
        gpg --homedir "$GPG_HOME" --verify /boot/grub/grub.cfg.sig /boot/grub/grub.cfg >/dev/null 2>&1 \
            || die "GPG verify failed: /boot/grub/grub.cfg"

        local f
        for f in /boot/vmlinuz-* /boot/initrd.img-*; do
            [[ -f "$f" ]] || continue
            [[ "$f" == *.sig ]] && continue
            [[ -f "$f.sig" ]] || die "Missing signature: $f.sig"
            gpg --homedir "$GPG_HOME" --verify "$f.sig" "$f" >/dev/null 2>&1 || die "GPG verify failed: $f"
        done
    }

    verify_gpg_layer() {
        local rc=0
        [[ -x "$GRUB_SNIPPET" ]] && ok "GPG: GRUB snippet present: $GRUB_SNIPPET" || { fail "GPG: GRUB snippet missing: $GRUB_SNIPPET"; rc=1; }
        [[ -f "$GRUB_GPG_KEY_FILE" ]] && ok "GPG: GRUB public key present: $GRUB_GPG_KEY_FILE" || { fail "GPG: GRUB public key missing: $GRUB_GPG_KEY_FILE"; rc=1; }
        [[ -f "$GRUB_GPG_BACKUP_FILE" ]] && ok "GPG: GRUB public key backup present: $GRUB_GPG_BACKUP_FILE" || { fail "GPG: GRUB public key backup missing: $GRUB_GPG_BACKUP_FILE"; rc=1; }

        if [[ -f /boot/grub/grub.cfg ]] && grep -q 'sb-guard: GRUB GPG verification' /boot/grub/grub.cfg 2>/dev/null; then
            ok "GPG: grub.cfg contains verification snippet"
        else
            fail "GPG: grub.cfg does not contain verification snippet (need update-grub)"
            rc=1
        fi

        grub_cfg_has_expected "$GPG_MODE" && ok "GPG: grub.cfg has expected trust+mode lines" || { fail "GPG: grub.cfg trust/mode lines mismatch"; rc=1; }
        grub_cfg_has_display_policy && ok "GPG: grub.cfg native-terminal display policy OK" || { fail "GPG: grub.cfg display policy mismatch"; rc=1; }
        grub_cfg_has_no_debug_output && ok "GPG: GRUB debug/pager output disabled" || { fail "GPG: GRUB debug/pager output enabled"; rc=1; }
        [[ -f /boot/grub/grub.cfg && -f /boot/grub/grub.cfg.sig ]] && ok "GPG: grub.cfg signature present" || { fail "GPG: grub.cfg signature missing"; rc=1; }

        # NEW: the trusted key itself must be signed (so check_signatures=enforce won't choke)
        if [[ -f "$GRUB_GPG_KEY_FILE" ]]; then
            [[ -f "$GRUB_GPG_KEY_FILE.sig" ]] && ok "GPG: key signature present: $GRUB_GPG_KEY_FILE.sig" || { fail "GPG: key signature missing: $GRUB_GPG_KEY_FILE.sig"; rc=1; }
        fi

        if [[ "$rc" -eq 0 ]]; then
            gpg_verify_boot_artifacts
            ok "GPG: boot artifacts signatures OK"

            # NEW: verify "everything GRUB loads" has .sig
            gpg_verify_runtime_files_strict
        fi
        return "$rc"
    }

    fix_gpg() {
        log "=== FIX BEGIN (gpg) ==="
        ensure_state_dirs
        ensure_grub_display_policy
        gpg_require_present
        gpg_export_pub_to_boot_and_backup
        grub_install_gpg_snippet "$GPG_MODE" || true
        grub_remove_video_init_snippet || true

        if grub_cfg_has_expected "$GPG_MODE" && grub_cfg_has_display_policy && grub_cfg_has_no_debug_output; then
            ok "Skipping update-grub: grub.cfg contains expected trust/display policy"
        else
            warn "Running update-grub (to embed trust and display policy into /boot/grub/grub.cfg)..."
            run update-grub >/dev/null
            grub_cfg_has_expected "$GPG_MODE" || die "update-grub did not embed expected sb-guard lines"
            grub_cfg_has_display_policy || die "update-grub did not embed expected display policy"
            grub_cfg_has_no_debug_output || die "update-grub left GRUB debug/pager output enabled"
        fi

        # NEW: kernels referenced by grub.cfg must be EFI-signed by our db
        fix_kernels_efi_signed_from_grub_cfg

        warn "Ensuring signatures for /boot artifacts (grub.cfg + kernel/initrd)..."
        gpg_ensure_boot_artifacts

        # NEW: ensure GRUB runtime files are also signed (mods/fonts/locale/theme/key/...)
        gpg_ensure_sig_one "$GRUB_GPG_KEY_FILE"
        gpg_ensure_runtime_files_strict

        gpg_verify_boot_artifacts
        gpg_verify_runtime_files_strict
        ok "GPG layer enforced + signatures verified"
        log "=== FIX DONE (gpg) ==="
    }

    # ==============================================================================
    # High-level flows
    # ==============================================================================
    do_verify() {
        local rc=0
        log "=== STRICT VERIFY BEGIN ==="
        ensure_esp_mounted

        try_check verify_mount_policy

        local efi_id; efi_id="$(detect_efi_id)"
        ok "EFI vendor dir: /EFI/$efi_id"

        try_check verify_structure
        try_check verify_perms_types
        try_check verify_stub_cfgs
        try_check verify_keys_present

        try_check verify_efi_sig_strict "$ESP_MNT/EFI/$efi_id/shimx64.efi"
        if [[ "$VERIFY_SHIM_VENDOR" -eq 1 ]]; then
            try_check verify_shim_vendor_cert "$ESP_MNT/EFI/$efi_id/shimx64.efi"
        fi
        try_check verify_efi_sig_strict "$ESP_MNT/EFI/$efi_id/grubx64.efi"
        try_check verify_grub_sbat_section "$ESP_MNT/EFI/$efi_id/grubx64.efi"
        if [[ "$KEEP_MMX" -eq 1 && -f "$ESP_MNT/EFI/$efi_id/mmx64.efi" ]]; then
            try_check verify_efi_sig_strict "$ESP_MNT/EFI/$efi_id/mmx64.efi"
        fi

        # NEW: verify kernels referenced from grub.cfg are EFI-signed by our db
        try_check verify_kernels_efi_signed_from_grub_cfg

        if [[ "$VERIFY_NVRAM" -eq 1 ]]; then
            try_check nvram_verify_policy "$efi_id"
        else
            log "NVRAM preflight deferred to controlled reconcile"
        fi
        [[ "$VERIFY_PINS" -eq 0 ]] || try_check verify_pins

        if [[ "$rc" -eq 0 ]]; then
            log "=== RESULT: OK (strict) ==="
        else
            log "=== RESULT: FAIL (strict) ==="
        fi
        return "$rc"
    }

    do_verify_full() {
        local rc=0
        set +e
        do_verify
        rc=$?
        set -e

        log "=== GPG VERIFY BEGIN ==="
        local rcg
        set +e
        verify_gpg_layer
        rcg=$?
        set -e

        [[ "$rcg" -eq 0 ]] && log "=== GPG RESULT: OK ===" || { log "=== GPG RESULT: FAIL ==="; rc=1; }

        [[ "$rc" -eq 0 ]] && log "=== RESULT: OK (full) ===" || log "=== RESULT: FAIL (full) ==="
        return "$rc"
    }

    backup_current_esp() {
        log "=== BACKUP BEGIN (last-known-good boot set) ==="
        ensure_esp_mounted

        local efi_id backup_efi_id sys_dir verify_rc tmp old pin pin_rc
        local old_legacy_stub old_keep_bundle old_verify_nvram old_verify_pins old_verify_shim_vendor
        local -a existing_pins=()
        efi_id="$(detect_efi_id)"
        backup_efi_id="$efi_id"
        if is_proxmox_installed; then
            backup_efi_id="proxmox"
        fi
        sys_dir="$ESP_MNT/EFI/$efi_id"
        if [[ ! -f "$sys_dir/shimx64.efi" || ! -f "$sys_dir/grubx64.efi" ]]; then
            warn "No complete existing ESP boot set; initial deployment has no prior backup"
            log "=== BACKUP SKIP (no prior boot set) ==="
            return 0
        fi

        # Never replace a recovery backup with an unverified state.  Pins are
        # not required for the first migration, but signatures, structure and
        # the full GPG layer must already pass.
        # During migration, accept the old duplicate ESP stub long enough to
        # validate and save the last-known-good set.  fix_structure removes it
        # before the new two-file set is published.
        old_legacy_stub="$ALLOW_LEGACY_ESP_STUB"
        old_keep_bundle="$KEEP_ENROLLMENT_BUNDLE"
        old_verify_nvram="$VERIFY_NVRAM"
        old_verify_pins="$VERIFY_PINS"
        old_verify_shim_vendor="$VERIFY_SHIM_VENDOR"
        ALLOW_LEGACY_ESP_STUB=1
        # Run the preflight in an if-condition.  Bash suppresses errexit for
        # functions called as a conditional, including the helper's internal
        # set -e toggles, so a failed legacy ESP check can be handled below
        # instead of terminating before verify_rc is captured.
        VERIFY_PINS=0
        # The pre-existing set may be from the migration-era Proxmox shim
        # whose embedded vendor CA is being removed by this transaction.  Its
        # PE signature, structure and pins are still required for backup; the
        # new custom-only vendor policy is enforced after deployment.
        VERIFY_SHIM_VENDOR=0
        # The enrollment bundle is deliberately present until the first
        # successful post-enrollment reconcile. Validate it as an exact,
        # allow-listed bundle during backup preflight, then let fix_structure
        # remove it in this transaction.
        #
        # NVRAM is mutable firmware metadata, not part of the EFI bytes being
        # backed up. Do not let a firmware-created fallback entry prevent a
        # valid rollback from being captured. The main reconcile repairs
        # NVRAM and performs the final strict verify after deployment.
        VERIFY_NVRAM=0
        if [[ "$KEEP_ENROLLMENT_BUNDLE" -eq 0 && -d "$ESP_MNT/EFI/SB" ]]; then
            KEEP_ENROLLMENT_BUNDLE=1
            log "Enrollment bundle present: validating it for preflight cleanup"
        fi
        if do_verify_full; then
            verify_rc=0
        else
            verify_rc=$?
        fi
        ALLOW_LEGACY_ESP_STUB="$old_legacy_stub"
        KEEP_ENROLLMENT_BUNDLE="$old_keep_bundle"
        VERIFY_NVRAM="$old_verify_nvram"
        VERIFY_PINS="$old_verify_pins"
        VERIFY_SHIM_VENDOR="$old_verify_shim_vendor"
        if [[ "$verify_rc" -ne 0 ]]; then
            if [[ -d "$ESP_BACKUP_DIR" ]]; then
                # A previous interrupted first migration can leave the backup
                # directory itself behind without a complete manifest.  Do
                # not mistake that empty/incomplete path for a recovery set:
                # quarantine it and continue the initial migration.  A real,
                # self-checking rollback remains a hard stop on inconsistency.
                if [[ -s "$ESP_BACKUP_DIR/manifest.sha256" &&
                    -s "$ESP_BACKUP_DIR/shimx64.efi" &&
                    -s "$ESP_BACKUP_DIR/grubx64.efi" &&
                    -s "$ESP_BACKUP_DIR/boot-grub.cfg" &&
                    -s "$ESP_BACKUP_DIR/boot-grub.cfg.sig" &&
                    -d "$ESP_BACKUP_DIR/pins" ]] &&
                    (cd "$ESP_BACKUP_DIR" && sha256sum -c manifest.sha256 >/dev/null 2>&1); then
                    die "Current ESP is not known-good; refusing update while a verified rollback backup exists"
                fi
                local stale_backup="${ESP_BACKUP_DIR}.stale.$(date +%Y%m%d-%H%M%S).$$"
                mv -f -- "$ESP_BACKUP_DIR" "$stale_backup" ||
                    die "Unable to quarantine incomplete rollback backup: $ESP_BACKUP_DIR"
                chmod 0700 "$stale_backup"
                warn "Quarantined incomplete rollback directory: $stale_backup"
            fi
            warn "Current ESP is not yet strict-good and no rollback exists; treating this as initial migration"
            log "=== BACKUP SKIP (current state failed preflight) ==="
            return 0
        fi

        mapfile -t existing_pins < <(find "$PIN_DIR" -maxdepth 1 -type f -name '*.sha256' -print)
        if [[ "${#existing_pins[@]}" -eq 0 ]]; then
            # First migration may predate pin files.  Initialize them only
            # after the complete current boot-set passed strict verification.
            fix_pins
        else
            set +e
            verify_pins
            pin_rc=$?
            set -e
            [[ "$pin_rc" -eq 0 ]] ||
                die "Existing pins do not match the current ESP; inspect manually before updating"
        fi

        install -d -m 0700 -o root -g root "$STATE_ROOT/backups" "$ESP_BACKUP_DIR"
        tmp="$(mktemp -d -p "$STATE_ROOT/backups" .esp-backup.XXXXXX)"
        run chmod 0700 "$tmp"
        install -m 0600 -o root -g root "$sys_dir/shimx64.efi" "$tmp/shimx64.efi"
        install -m 0600 -o root -g root "$sys_dir/grubx64.efi" "$tmp/grubx64.efi"
        if [[ -f "$sys_dir/grub.cfg" ]]; then
            # Keep the legacy stub in the offline rollback bundle for audit;
            # it is not restored to the canonical two-file ESP layout.
            install -m 0600 -o root -g root "$sys_dir/grub.cfg" "$tmp/grub.cfg"
        fi
        install -m 0600 -o root -g root /boot/grub/grub.cfg "$tmp/boot-grub.cfg"
        install -m 0600 -o root -g root /boot/grub/grub.cfg.sig "$tmp/boot-grub.cfg.sig"
        install -d -m 0700 -o root -g root "$tmp/pins"
        while IFS= read -r -d '' pin; do
            local pin_name pin_target
            pin_name="$(basename "$pin")"
            pin_target="$pin_name"
            if [[ "$efi_id" != "$backup_efi_id" && "$pin_name" == "EFI_${efi_id}_"* ]]; then
                pin_target="EFI_${backup_efi_id}_${pin_name#EFI_${efi_id}_}"
            fi
            install -m 0600 -o root -g root "$pin" "$tmp/pins/$pin_target"
        done < <(find "$PIN_DIR" -maxdepth 1 -type f -name '*.sha256' -print0 | sort -z)
        {
            printf 'efi_id=%s\n' "$backup_efi_id"
            printf 'source_efi_id=%s\n' "$efi_id"
            printf 'created_at=%s\n' "$(date -Is)"
            printf 'shim_package_version=%s\n' "$(dpkg-query -W -f='${Version}\n' shim-unsigned 2>/dev/null | sed '/^$/d;1q' || true)"
            printf 'grub_package_version=%s\n' "$(dpkg-query -W -f='${Version}\n' grub-efi-amd64-bin 2>/dev/null | sed '/^$/d;1q' || true)"
        } >"$tmp/metadata"
        run chmod 0600 "$tmp/metadata"
        (
            cd "$tmp"
            sha256sum shimx64.efi grubx64.efi boot-grub.cfg boot-grub.cfg.sig metadata >manifest.sha256
            [[ -f grub.cfg ]] && sha256sum grub.cfg >>manifest.sha256
            find pins -maxdepth 1 -type f -name '*.sha256' -print0 | sort -z | xargs -0r sha256sum >>manifest.sha256
            sha256sum -c manifest.sha256 >/dev/null
        ) || {
            rm -rf -- "$tmp"
            die "Rollback backup self-check failed"
        }
        run chmod 0600 "$tmp/manifest.sha256"

        old="${ESP_BACKUP_DIR}.old"
        rm -rf -- "$old"
        if [[ -d "$ESP_BACKUP_DIR" ]]; then
            mv -- "$ESP_BACKUP_DIR" "$old"
        fi
        if ! mv -- "$tmp" "$ESP_BACKUP_DIR"; then
            [[ -d "$old" ]] && mv -- "$old" "$ESP_BACKUP_DIR"
            rm -rf -- "$tmp"
            die "Unable to publish rollback backup"
        fi
        rm -rf -- "$old"
        ok "Saved one verified rollback boot set: $ESP_BACKUP_DIR"
        log "=== BACKUP DONE (last-known-good boot set) ==="
    }

    do_fix_all_full() {
        fix_mount_policy
        fix_keys
        SB_GUARD_LOCK_HELD=1 "$SHIM_REBUILD" --maybe
        REFRESH_SHIM=1
        fix_gpg
        # Capture the currently verified boot set after APT-owned /boot files
        # have been signed, but still before any ESP write window is opened.
        # The helper keeps exactly one last-known-good set and refuses to
        # overwrite it when the current state is already inconsistent.
        backup_current_esp
        if is_proxmox_installed; then
            EFI_ID_OVERRIDE="proxmox"
            log "ESP migration policy: deploy canonical EFI/proxmox and retire any legacy EFI/debian"
        fi
        prepare_esp_artifacts

        # One controlled ESP write window. All EFI binaries were staged and
        # verified before atomic_deploy_efi publishes them.
        esp_rw_begin
        fix_esp_files_from_system
        # Publish the canonical files first, switch NVRAM while the legacy
        # Debian directory still exists, then retire that directory.
        fix_nvram
        fix_structure
        fix_stub_cfgs
        fix_structure
        run sync
        esp_rw_end

        # Pins are trust state, not a repair mechanism. Validate the complete
        # deployed chain first, then commit pins, then validate once more.
        VERIFY_PINS=0
        do_verify_full
        VERIFY_PINS=1
        fix_pins
        do_verify_full
    }

    # ==============================================================================
    # CLI
    # ==============================================================================
    usage() {
        cat <<'USAGE'
    Usage:
      sb-guard [options] [mode]

    Modes:
      --verify                strict verify + gpg verify (default)
      --stage-release          build a signed shim+GRUB release under /var/lib/sb-guard/release (no ESP writes)
      --apply-release          verify and deploy the exact /var/lib/sb-guard/release bytes
      --fix-mount             systemd reload + umount/mount ESP
      --fix-structure         keep only /EFI/<vendor> and minimal set inside (no /EFI/BOOT by default)
      --fix-esp               update ESP files (default: refresh grub only; shim is NOT overwritten unless --refresh-shim)
      --fix-sign              strict re-sign grubx64.efi (+ mmx64.efi if KEEP_MMX=1); shim must already be signed
      --fix-nvram             make our shim first in BootOrder (retain other records)
      --purge-foreign         with --fix-nvram/--fix-all, delete non-firmware records
      --fix-pins              repin ONLY if all strict preconditions pass
      --fix-gpg               requires existing GPG key; ensure snippet+keys+signatures
      --fix-all               FULL strict pipeline (includes repin)
      --break-signatures      test helper: removes signature table from shimx64.efi (then verify)

    Options:
      --keep-boot             KEEP_BOOT_DIR=1 (not recommended)
      --no-mmx                KEEP_MMX=0 (strict two EFI files only)
      --with-mmx              KEEP_MMX=1
      --refresh-shim          REFRESH_SHIM=1 (overwrite shim on ESP using golden shim)
      --refresh-mmx           REFRESH_MMX=1 (overwrite mmx on ESP using MMX_SRC; only if KEEP_MMX=1)
      --strict-owner          require uid=0 gid=0 for ESP objects
      --allow-exec            do NOT require noexec (NOT recommended)
      --allow-atime           do NOT require noatime (NOT recommended)
      --trace                 print executed commands
      --debug-pre             print expected stub cfg on failure

    Env overrides:
      ESP_MNT, STATE_ROOT, KEY_DIR, PIN_DIR, ESP_BACKUP_DIR, DB_CRT, DB_KEY,
      GRUB_MONOLITH, GRUB_BUILD_MODE, GRUB_BUILD_PROFILE,
      GRUB_PROFILE_ENV, MMX_SRC, NVRAM_LABEL, NVRAM_PURGE_FOREIGN,
      KEEP_MMX, KEEP_BOOT_DIR, REFRESH_SHIM, REFRESH_MMX

    Notes:
      - No key generation here.
      - If UEFI keys missing: run sb-install --init-uefi-keys
      - If GPG keys missing:  run sb-install --init-gpg-keys
      - IMPORTANT: fix-sign does NOT re-sign shim. shim must already be strict-signed (golden).
    USAGE
    }

    main() {

        # Core requirements (verify/fix basics)
        require_cmd findmnt
        require_cmd mount
        require_cmd umount
        require_cmd sync
        require_cmd find
        require_cmd sort
        require_cmd sha256sum
        require_cmd install
        require_cmd rm
        require_cmd grep
        require_cmd sed
        require_cmd stat
        require_cmd flock
        require_cmd lsblk
        require_cmd efibootmgr
        require_cmd readlink
        require_cmd grub-probe
        require_cmd openssl
        require_cmd cmp
        require_cmd head
        require_cmd xargs
        require_cmd tr
        if [[ "$GRUB_BUILD_MODE" == "packaged" ]]; then
            require_cmd grub-mkstandalone
        elif [[ "$GRUB_BUILD_MODE" == "profile" ]]; then
            [[ -x "$GRUB_BUILD_PROFILE/bin/grub-mkstandalone" ]] \
                || die "Missing isolated GRUB builder: $GRUB_BUILD_PROFILE/bin/grub-mkstandalone"
        else
            die "Unknown GRUB_BUILD_MODE: $GRUB_BUILD_MODE"
        fi
        require_cmd objcopy

        # SecureBoot tooling (verify/sign/break)
        require_cmd sbverify
        require_cmd sbattach
        require_cmd sbsign

        # GPG tooling is always needed because verify_full always checks GPG layer
        require_cmd gpg

        wait_for_package_idle() {
            local i package_pid
            for ((i = 1; i <= 180; i++)); do
                if [[ -e /run/sb-guard-package-active ]]; then
                    package_pid="$(sed -n '1p' /run/sb-guard-package-active 2>/dev/null || true)"
                    if [[ "$package_pid" =~ ^[0-9]+$ && -d "/proc/$package_pid" ]]; then
                        sleep 2
                        continue
                    fi
                    # A stale marker is only removable after both real dpkg
                    # lock files are observed free below.
                fi

                exec 18>/var/lib/dpkg/lock-frontend
                if ! flock -n 18; then
                    exec 18>&-
                    sleep 2
                    continue
                fi
                exec 18>&-
                exec 19>/var/lib/dpkg/lock
                if ! flock -n 19; then
                    exec 19>&-
                    sleep 2
                    continue
                fi
                exec 19>&-
                rm -f -- /run/sb-guard-package-active
                return 0
            done
            return 1
        }

        # Serialize every reconcile and force ESP back to ro on every exit path.
        # A caller that already owns this lock (the rollback helper) explicitly
        # propagates SB_GUARD_LOCK_HELD=1 to avoid a self-deadlock.
        if [[ "${SB_GUARD_LOCK_HELD:-0}" != "1" ]]; then
            exec 200>/run/sb-guard.lock
            flock -w 300 200 || die "Timed out waiting for sb-guard reconcile lock"
        fi

        wait_for_package_idle || die "Timed out waiting for APT/dpkg transaction to become idle"

        # On every exit path, including a failed mount-policy repair, force the
        # ESP back to RO if it is still mounted writable.
        trap 'cleanup_esp_stage; cleanup_release_stage; if findmnt -n "$ESP_MNT" >/dev/null 2>&1 && ! mnt_is_ro "$ESP_MNT"; then ESP_RW_DEPTH=0; remount_ro_force || true; fi' EXIT

        while (( $# > 0 )); do
            case "$1" in
                --verify) MODE="verify" ;;
                --stage-release) MODE="stage-release" ;;
                --apply-release) MODE="apply-release" ;;
                --fix-mount) MODE="fix-mount" ;;
                --fix-structure) MODE="fix-structure" ;;
                --fix-esp) MODE="fix-esp" ;;
                --fix-sign) MODE="fix-sign" ;;
                --fix-nvram) MODE="fix-nvram" ;;
                --fix-pins) MODE="fix-pins" ;;
                --fix-gpg) MODE="fix-gpg" ;;
                --fix-all) MODE="fix-all" ;;
                --break-signatures) MODE="break-signatures" ;;

                --trace) TRACE=1 ;;
                --debug-pre) DEBUG_PRE=1 ;;
                --strict-owner) STRICT_OWNER=1 ;;
                --allow-exec) ALLOW_EXEC=1 ;;
                --allow-atime) ALLOW_ATIME=1 ;;
                --keep-boot) KEEP_BOOT_DIR=1 ;;
                --no-mmx) KEEP_MMX=0 ;;
                --with-mmx) KEEP_MMX=1 ;;
                --refresh-shim) REFRESH_SHIM=1 ;;
                --refresh-mmx) REFRESH_MMX=1 ;;
                --purge-foreign) NVRAM_PURGE_FOREIGN=1 ;;

                -h|--help) usage; exit 0 ;;
                *) die "Unknown arg: $1" ;;
            esac
            shift
        done

        # update-grub is only required in fix-gpg/fix-all flows (verify just greps existing grub.cfg)
        if [[ "$MODE" == "fix-gpg" || "$MODE" == "fix-all" ]]; then
            require_cmd update-grub
        fi

        ensure_state_dirs

        # Cache platform dir once (avoid function lookup surprises inside pipelines)
        GRUB_PLATFORM_DIR="$(grub_detect_platform_dir)"

        case "$MODE" in
            verify) do_verify_full ;;
            stage-release) stage_release_artifacts; ;;
            apply-release) apply_release_bundle ;;
            fix-mount) fix_mount_policy; do_verify_full ;;
            fix-structure) fix_structure; do_verify_full ;;

            # fix-esp: update files + stub + re-sign (pins will likely mismatch -> run --fix-pins intentionally)
            fix-esp)
                fix_structure
                fix_esp_files_from_system
                fix_stub_cfgs
                fix_structure
                do_verify_full
                ;;

            fix-sign) fix_signatures; do_verify_full ;;
            fix-nvram) fix_nvram; do_verify_full ;;
            fix-pins) fix_pins; do_verify_full ;;
            fix-gpg) fix_gpg; do_verify_full ;;
            fix-all) do_fix_all_full ;;
            break-signatures) break_signatures; do_verify_full || true ;;
            *) die "Bad MODE=$MODE" ;;
        esac
    }

    main "$@"
EOF
    ok "installed sb-guard core -> $CORE_DST"
}

install_wrapper() {
    cat <<EOF | indent -4 | install -D -m 0750 -o root -g root /dev/stdin "$SVC_DST"
    #!/usr/bin/env bash
    set -Eeuo pipefail
    IFS=\$'\\n\\t'
    umask 077

    log_file="${LOG_FILE}"
    core="${CORE_DST}"

    mkdir -p "\$(dirname "\$log_file")"

    ts() { date '+%F %T'; }

    mode="--fix-all"
    if [[ "\${1:-}" =~ ^-- ]]; then
        mode="\$1"
        shift || true
    fi

    wait_for_apt_idle() {
        local i package_pid=""
        for ((i = 1; i <= 180; i++)); do
            if [[ -e /run/sb-guard-package-active ]]; then
                package_pid="\$(sed -n '1p' /run/sb-guard-package-active 2>/dev/null || true)"
                if [[ "\${package_pid:-}" =~ ^[0-9]+$ && -d "/proc/\$package_pid" ]]; then
                    sleep 2
                    continue
                fi
                # A stale marker is removed only after both real dpkg locks
                # below are observed free.
            fi
            exec 18>/var/lib/dpkg/lock-frontend
            if flock -n 18; then
                exec 18>&-
                exec 19>/var/lib/dpkg/lock
                if flock -n 19; then
                    exec 19>&-
                    return 0
                fi
                exec 19>&-
            else
                exec 18>&-
            fi
            sleep 2
        done
        return 1
    }

    # Verification is read-only. Every mode that can build, repair, or write
    # boot state must wait for a real idle APT/dpkg transaction before taking
    # the global sb-guard lock and again inside the core.
    if [[ "\$mode" != "--verify" ]]; then
        wait_for_apt_idle || { echo "ERROR: APT/dpkg transaction is still active" >&2; exit 1; }
    fi

    # Own the global transaction lock before any source/profile preparation.
    # A parent lifecycle installer may already hold it and exports the marker;
    # reopening it in this child would self-deadlock the whole Stage 03 run.
    if [[ "\${SB_GUARD_LOCK_HELD:-0}" != "1" ]]; then
        exec 200>/run/sb-guard.lock
        flock -w 300 200 || { echo "ERROR: Timed out waiting for sb-guard reconcile lock" >&2; exit 1; }
        export SB_GUARD_LOCK_HELD=1
    fi

    # Re-check after acquiring the global lock. An APT transaction may have
    # started between the first idle probe and lock acquisition; no builder or
    # deploy operation is allowed to proceed on that stale observation.
    if [[ "\$mode" != "--verify" ]]; then
        wait_for_apt_idle || { echo "ERROR: APT/dpkg transaction became active" >&2; exit 1; }
    fi

    # A direct manual --fix-all follows the exact same source-build stage as
    # the event worker. This helper never invokes host APT; it fetches the
    # matching source and delegates compilation to the shared cached Trixie
    # root with a disposable /build workspace.
    if [[ "\$mode" == "--fix-all" ]]; then
        /usr/local/sbin/sb-grub-profile-chroot --ensure-auto
        /usr/local/sbin/sb-shim-auto-build
    fi

    # Capture the core exit status explicitly.  The core is the first element
    # of a pipeline, so relying on errexit inside the subshell would be brittle.
    set +e
    (
        echo "[\$(ts)] === sb-guard-svc BEGIN: \$mode \$* ==="
        "\$core" "\$mode" "\$@"
        rc=\$?
        echo "[\$(ts)] === sb-guard-svc END: rc=\$rc ==="
        exit "\$rc"
    ) 2>&1 | tee -a "\$log_file"
    pipeline_rc="\${PIPESTATUS[0]}"
    set -e
    exit "\$pipeline_rc"
EOF
    ok "installed sb-guard wrapper -> $SVC_DST"
}

# ==============================================================================
# Install: APT hooks
# ==============================================================================
install_event_dispatcher() {
    cat <<'EOF' | indent -4 | install -D -m 0750 -o root -g root /dev/stdin "$EVENT_DST"
    #!/usr/bin/env bash
    set -Eeuo pipefail
    umask 077

    # Stage 03 creates this marker before installing or updating the hook.
    # Do not queue or start a maintenance worker while the user-driven build
    # and enrollment transaction is in progress.
    if [[ -s /run/sb-guard-installing ]]; then
        if install_pid="$(< /run/sb-guard-installing)"; then
            :
        else
            install_pid=""
        fi
        if [[ "$install_pid" =~ ^[0-9]+$ && -d "/proc/$install_pid" ]]; then
            exit 0
        fi
        rm -f -- /run/sb-guard-installing
    fi

    event_dir="/var/lib/sb-guard/events"
    package_active=/run/sb-guard-package-active
    case "${1:-refresh}" in
        --package-begin)
            # DPkg::Pre-Invoke runs in a child of the dpkg process that still
            # owns the frontend/backend locks. Record that parent PID so a
            # worker already queued by another trigger can defer cleanly.
            if [[ "${PPID:-}" =~ ^[0-9]+$ ]]; then
                printf '%s\n' "$PPID" >"$package_active.new"
                chmod 0600 "$package_active.new"
                mv -f "$package_active.new" "$package_active"
            fi
            exit 0
            ;;
        --package-end)
            # APT may still hold its locks while this callback runs. The marker
            # is advisory; the worker performs a fresh non-blocking check of
            # both real dpkg lock files before any build or ESP operation.
            rm -f -- "$package_active" "$package_active.new"
            ;;
        refresh)
            # During the manual firmware-enrollment pause the public bundle is
            # intentionally waiting for an operator.  Do not queue another
            # event or start the maintenance worker until that pause is
            # cleared by run.sh.  Package begin/end markers above must still
            # be processed so a stale dpkg-lock hint cannot remain forever.
            [[ ! -e /var/lib/sb-guard/awaiting-enrollment ]] || exit 0
            ;;
        *) exit 2 ;;
    esac

    install -d -m 0700 -o root -g root "$event_dir"
    event="$event_dir/refresh.$(date +%s%N).$$"
    : >"$event"

    # Never wait inside an APT/dpkg hook. systemd coalesces starts of this
    # oneshot unit; sb-guard itself provides the cross-trigger flock.
    systemctl start --no-block sb-guard.service >/dev/null 2>&1 || true
EOF
    ok "installed event dispatcher -> $EVENT_DST"
}

install_reconcile_worker() {
    cat <<'EOF' | indent -4 | install -D -m 0750 -o root -g root /dev/stdin "$WORKER_DST"
    #!/usr/bin/env bash
    # Drain every queued event through one serialized reconcile pipeline.
    set -Eeuo pipefail
    IFS=$'\n\t'
    umask 077

    # The installation pipeline remains paused until custom db.crt is
    # enrolled in firmware.  Leaving queued events untouched is deliberate:
    # run.sh clears this marker after enrollment and a later event/start can
    # reconcile the complete system.
    [[ ! -e /var/lib/sb-guard/awaiting-enrollment ]] || exit 0

    event_dir=/var/lib/sb-guard/events
    install -d -m 0700 -o root -g root "$event_dir"

    first=1
    for ((pass = 1; pass <= 32; pass++)); do
        mapfile -d '' events < <(find "$event_dir" -maxdepth 1 -type f -name 'refresh.*' -print0 | sort -z)
        if [[ "$first" -eq 0 && "${#events[@]}" -eq 0 ]]; then
            exit 0
        fi
        first=0

        /usr/local/sbin/sb-guard-svc --fix-all

        if [[ "${#events[@]}" -gt 0 ]]; then
            rm -f -- "${events[@]}"
        fi
    done

    printf 'ERROR: event queue did not converge after 32 passes\n' >&2
    exit 1
EOF
    ok "installed serialized reconcile worker -> $WORKER_DST"
}

install_rollback_helper() {
    cat <<'EOF' | indent -4 | install -D -m 0750 -o root -g root /dev/stdin "$ROLLBACK_DST"
    #!/usr/bin/env bash
    # Restore the single last-known-good boot set created by sb-guard.
    set -Eeuo pipefail
    IFS=$'\n\t'
    umask 077

    ESP_MNT="${ESP_MNT:-/boot/efi}"
    STATE_ROOT="${STATE_ROOT:-/var/lib/sb-guard}"
    BACKUP_DIR="${BACKUP_DIR:-$STATE_ROOT/backups/esp-last-good}"
    PIN_DIR="${PIN_DIR:-$STATE_ROOT/pins}"
    ESP_CFG_MODE="${ESP_CFG_MODE:-embedded}" # embedded (canonical) | external (legacy)
    DB_CRT="${DB_CRT:-$STATE_ROOT/keys/db.crt}"
    LOCK_FILE="${LOCK_FILE:-/run/sb-guard.lock}"

    die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
    log() { printf '[sb-guard-rollback] %s\n' "$*" >&2; }
    need() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

    metadata_get() {
        local key="$1"
        sed -n "s/^${key}=//p" "$BACKUP_DIR/metadata" | sed '/^$/d;1q'
    }

    verify_efi_one() {
        local image="$1" count
        sbverify --cert "$DB_CRT" "$image" >/dev/null \
            || die "EFI signature verification failed: $image"
        count="$(sbverify --list "$image" 2>/dev/null \
            | grep -cE '^signature[[:space:]]+[0-9]+$' || true)"
        [[ "$count" -eq 1 ]] || die "EFI image does not contain exactly one signature: $image"
    }

    verify_backup() {
        [[ -d "$BACKUP_DIR" && -f "$BACKUP_DIR/manifest.sha256" ]] \
            || die "No last-known-good rollback backup: $BACKUP_DIR"
        [[ -d "$BACKUP_DIR/pins" ]] \
            || die "Rollback backup is missing its pins directory"
        [[ "$(stat -c '%U:%G:%a' "$BACKUP_DIR" 2>/dev/null || true)" == "root:root:700" ]] \
            || die "Rollback backup directory ownership/mode is not root:root:700"
        [[ -s "$DB_CRT" ]] || die "Missing db certificate: $DB_CRT"
        (cd "$BACKUP_DIR" && sha256sum -c manifest.sha256 >/dev/null) \
            || die "Rollback backup manifest verification failed"
        local efi_id
        efi_id="$(metadata_get efi_id)"
        [[ "$efi_id" =~ ^[A-Za-z0-9._-]+$ ]] || die "Invalid EFI vendor id in rollback metadata"
        verify_efi_one "$BACKUP_DIR/shimx64.efi"
        verify_efi_one "$BACKUP_DIR/grubx64.efi"
        log "Backup verified: efi_id=$efi_id"
    }

    remount_ro() {
        mount -o remount,ro,nodev,nosuid,noexec,noatime,fmask=0177,dmask=0077 "$ESP_MNT" >/dev/null 2>&1
    }

    atomic_restore() {
        local src="$1" dst="$2" mode="$3" tmp
        tmp="$(mktemp -p "$(dirname "$dst")" ".$(basename "$dst").rollback.XXXXXX")"
        install -m "$mode" -o root -g root "$src" "$tmp"
        mv -f -- "$tmp" "$dst"
    }

    restore() {
        need findmnt; need mount; need mktemp; need mv; need install; need sbverify
        need sha256sum; need stat; need sed; need grep; need sync; need flock
        [[ "$(id -u)" -eq 0 ]] || die "Run as root"
        exec 200>"$LOCK_FILE"
        flock -w 300 200 || die "Timed out waiting for sb-guard lock"
        verify_backup

        local service_active=0 path_active=0 timer_active=0
        local path_enabled=0 timer_enabled=0 rollback_ok=0 lock_released=0
        if command -v systemctl >/dev/null 2>&1; then
            systemctl is-active --quiet sb-guard.service && service_active=1 || true
            systemctl is-active --quiet sb-guard.path && path_active=1 || true
            systemctl is-active --quiet sb-guard.timer && timer_active=1 || true
            systemctl is-enabled --quiet sb-guard.path && path_enabled=1 || true
            systemctl is-enabled --quiet sb-guard.timer && timer_enabled=1 || true
            systemctl stop sb-guard.service sb-guard.path sb-guard.timer >/dev/null 2>&1 || true
        fi

        restore_workers() {
            command -v systemctl >/dev/null 2>&1 || return 0
            if (( path_enabled == 1 )); then
                systemctl enable sb-guard.path >/dev/null 2>&1 || return 1
            else
                systemctl disable sb-guard.path >/dev/null 2>&1 || true
            fi
            if (( timer_enabled == 1 )); then
                systemctl enable sb-guard.timer >/dev/null 2>&1 || return 1
            else
                systemctl disable sb-guard.timer >/dev/null 2>&1 || true
            fi
            if (( service_active == 1 )); then
                systemctl start sb-guard.service >/dev/null 2>&1 || return 1
            else
                systemctl stop sb-guard.service >/dev/null 2>&1 || true
            fi
            if (( path_active == 1 )); then
                systemctl start sb-guard.path >/dev/null 2>&1 || return 1
            else
                systemctl stop sb-guard.path >/dev/null 2>&1 || true
            fi
            if (( timer_active == 1 )); then
                systemctl start sb-guard.timer >/dev/null 2>&1 || return 1
            else
                systemctl stop sb-guard.timer >/dev/null 2>&1 || true
            fi
        }

        release_transaction_lock() {
            (( lock_released == 1 )) && return 0
            flock -u 200 >/dev/null 2>&1 || true
            lock_released=1
        }

        findmnt -n "$ESP_MNT" >/dev/null 2>&1 || die "ESP is not mounted: $ESP_MNT"
        local efi_id sys_dir
        efi_id="$(metadata_get efi_id)"
        sys_dir="$ESP_MNT/EFI/$efi_id"

        rollback_cleanup() {
            local rc=$?
            set +e
            remount_ro >/dev/null 2>&1 || true
            if (( rollback_ok == 0 )); then
                release_transaction_lock
                restore_workers || true
            fi
            exit "$rc"
        }
        trap rollback_cleanup EXIT
        trap 'exit 130' INT TERM
        mount -o remount,rw "$ESP_MNT"
        # A first Proxmox migration may have failed before the canonical
        # directory was created.  Restore into EFI/proxmox and retire only the
        # known Debian legacy directory; enrollment/other policy directories
        # are not guessed at here.
        if [[ "$efi_id" == "proxmox" && -d "$ESP_MNT/EFI/debian" ]]; then
            rm -rf -- "$ESP_MNT/EFI/debian"
        fi
        install -d -m 0700 -o root -g root "$sys_dir"
        atomic_restore "$BACKUP_DIR/shimx64.efi" "$sys_dir/shimx64.efi" 0600
        atomic_restore "$BACKUP_DIR/grubx64.efi" "$sys_dir/grubx64.efi" 0600
        # Remove any old external stub/checksum/foreign file first.  The
        # optional legacy stub is restored below only when external mode was
        # explicitly requested.
        while IFS= read -r -d '' stale; do
            rm -rf -- "$stale"
        done < <(find "$sys_dir" -mindepth 1 -maxdepth 1 \
            ! -name shimx64.efi ! -name grubx64.efi -print0 2>/dev/null)
        if [[ "$ESP_CFG_MODE" == external && -f "$BACKUP_DIR/grub.cfg" ]]; then
            atomic_restore "$BACKUP_DIR/grub.cfg" "$sys_dir/grub.cfg" 0600
        fi
        verify_efi_one "$sys_dir/shimx64.efi"
        verify_efi_one "$sys_dir/grubx64.efi"
        sync
        remount_ro

        atomic_restore "$BACKUP_DIR/boot-grub.cfg" /boot/grub/grub.cfg 0600
        atomic_restore "$BACKUP_DIR/boot-grub.cfg.sig" /boot/grub/grub.cfg.sig 0600
        install -d -m 0700 -o root -g root "$PIN_DIR"
        find "$PIN_DIR" -maxdepth 1 -type f -name '*.sha256' -delete
        while IFS= read -r -d '' src; do
            atomic_restore "$src" "$PIN_DIR/$(basename "$src")" 0600
        done < <(find "$BACKUP_DIR/pins" -maxdepth 1 -type f -name '*.sha256' -print0 | sort -z)
        if [[ "$ESP_CFG_MODE" == embedded ]]; then
            rm -f -- "$PIN_DIR/EFI_${efi_id}_grub.cfg.sha256"
        fi

        log "Rollback files restored; ESP is read-only again"
        SB_GUARD_LOCK_HELD=1 /usr/local/sbin/sb-guard-svc --verify
        release_transaction_lock
        restore_workers || die "Rollback restored files but could not restore worker activation state"
        rollback_ok=1
    }

    case "${1:-}" in
        --verify)
            need sha256sum; need stat; need sed; need grep; need sbverify
            verify_backup
            ;;
        --restore) restore ;;
        -h|--help)
            printf '%s\n' \
                "Usage: sb-guard-rollback --verify | --restore"
            ;;
        *) die "Usage: $0 --verify | --restore" ;;
    esac
EOF
    ok "installed rollback helper -> $ROLLBACK_DST"
}

install_apt_hook_shim() {
    cat <<'EOF' | indent -4 | install -D -m 0644 -o root -g root /dev/stdin "$APT_HOOK_SHIM"
    // Lightweight event only: never run signing, ESP writes, or nested APT here.
    DPkg::Pre-Invoke  { "/usr/local/sbin/sb-guard-event --package-begin || true"; };
    DPkg::Post-Invoke { "/usr/local/sbin/sb-guard-event --package-end || true"; };
EOF
    ok "installed APT event hook -> $APT_HOOK_SHIM"
}

install_apt_hook_guard() {
    # The old file was an active DPkg::Post-Invoke hook.  Remove it during
    # migration instead of installing a permanent tombstone; a clean system
    # must contain only the canonical 89 hook.
    rm -f -- "$APT_HOOK_GUARD"
    ok "removed legacy duplicate APT hook -> $APT_HOOK_GUARD"
}

neutralize_legacy_integrations() {
    # The old hook opened the ESP from DPkg::Pre-Invoke.  Remove it during
    # migration; do not carry an unused compatibility file in the final image.
    rm -f -- "$LEGACY_APT_HOOK"
    rm -f -- /var/lib/sb-guard/events/refresh-required

    if have_cmd systemctl; then
        systemctl disable --now sb-guard-verify.timer >/dev/null 2>&1 || true
        systemctl stop sb-guard-verify.service >/dev/null 2>&1 || true
    fi
    ok "neutralized legacy sb-maintain hook and verify timer"
}

install_grub_build_policy() {
    # Install-only migration starts in packaged mode. The full stage-03
    # orchestrator replaces this file with profile mode only after the dynamic
    # Proxmox source profile has built and passed all checks; a failed build leaves the
    # existing policy untouched.
    install -d -m 0700 -o root -g root "$(dirname "$GRUB_BUILD_POLICY")"
    if [[ ! -s "$GRUB_BUILD_POLICY" ]]; then
        # The heredoc is nested inside the function and this if block; remove
        # both source indentation levels before writing the policy file.
        cat <<'EOF' | indent -8 | install -m 0600 -o root -g root /dev/stdin "$GRUB_BUILD_POLICY"
        # sb-guard GRUB build policy
        # packaged = migration/recovery mode before profile activation
        # profile  = production isolated source-matched profile
        GRUB_BUILD_MODE=packaged
        GRUB_BUILD_PROFILE=/var/lib/sb-guard/grub-build/profile
        GRUB_PROFILE_ENV=/var/lib/sb-guard/grub-build/profile/profile.env
EOF
        ok "installed default GRUB build policy -> $GRUB_BUILD_POLICY"
    else
        ok "preserved existing GRUB build policy -> $GRUB_BUILD_POLICY"
    fi
}

install_custom_db_policy() {
    cat <<'EOF' | indent -4 | install -D -m 0644 -o root -g root /dev/stdin "$APT_CUSTOM_DB_POLICY"
    # sb-guard custom-db policy: Microsoft/Proxmox-signed shim is not bootable
    # with a firmware DB containing only the local db certificate. The package
    # source for boot deployment is shim-unsigned, never shim-signed.
    Package: shim-signed
    Pin: version *
    Pin-Priority: -1
EOF
    if dpkg-query -W -f='${db:Status-Abbrev}\n' shim-signed 2>/dev/null | grep -q '^ii'; then
        # Existing package scripts are never allowed to migrate to the custom-
        # incompatible release. Keep the installed package quarantined; its
        # files are not deployment inputs and sb-guard owns ESP exclusively.
        apt-mark hold shim-signed >/dev/null
        ok "quarantined installed shim-signed with an explicit dpkg hold"
    fi
    ok "installed custom-db APT policy -> $APT_CUSTOM_DB_POLICY"
}

# ==============================================================================
# Install: systemd units
# ==============================================================================
install_systemd_units() {
    cat <<'EOF' | indent -4 | install -D -m 0644 -o root -g root /dev/stdin "$SYSTEMD_SERVICE"
    [Unit]
    Description=SB Guard (single source enforcement)
    After=local-fs.target
    Wants=local-fs.target
    ConditionPathIsDirectory=/sys/firmware/efi/efivars
    RequiresMountsFor=/boot /boot/efi

    [Service]
    Type=oneshot
    TimeoutStartSec=30min
    Restart=on-failure
    RestartSec=60s
    ExecStart=/usr/local/sbin/sb-guard-worker

    NoNewPrivileges=true
    PrivateTmp=true
    ProtectHome=true
    ProtectKernelTunables=true
    ProtectKernelModules=true
    ProtectControlGroups=true

    ReadWritePaths=/var/lib/sb-guard /var/log
    ReadWritePaths=/sys/firmware/efi/efivars
EOF

    cat <<'EOF' | indent -4 | install -D -m 0644 -o root -g root /dev/stdin "$SYSTEMD_TIMER"
    [Unit]
    Description=Run SB Guard periodically

    [Timer]
    OnBootSec=5min
    OnUnitActiveSec=1d
    RandomizedDelaySec=30min
    Persistent=true
    Unit=sb-guard.service

    [Install]
    WantedBy=timers.target
EOF

    cat <<'EOF' | indent -4 | install -D -m 0644 -o root -g root /dev/stdin "$SYSTEMD_PATH"
    [Unit]
    Description=Run SB Guard when boot/EFI artifacts change

    [Path]
    PathChanged=/boot
    PathChanged=/boot/grub
    PathChanged=/var/lib/sb-guard/events
    Unit=sb-guard.service

    [Install]
    WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    ok "installed systemd service -> $SYSTEMD_SERVICE"
    ok "installed systemd timer   -> $SYSTEMD_TIMER (activation deferred until verified enrollment)"
    ok "installed systemd path    -> $SYSTEMD_PATH (activation deferred until verified enrollment)"
}

# ==============================================================================
# Main
# ==============================================================================
main() {
    require_root
    have_cmd awk || die "Missing command: awk"
    have_cmd sed || die "Missing command: sed"

    # Installing or replacing the lifecycle scripts is itself a system-wide
    # transaction.  Stage 03 already owns this lock; direct recovery calls
    # acquire it here so a running worker cannot execute half-written files.
    if [[ "${SB_GUARD_LOCK_HELD:-0}" != "1" ]]; then
        exec 200>/run/sb-guard.lock
        flock -w 300 200 || die "Timed out waiting for sb-guard install lock"
        export SB_GUARD_LOCK_HELD=1
    fi

    install_sb_install
    install_shim_rebuild
    install_shared_build_root
    install_shim_auto_build

    install_core
    install_wrapper
    install_event_dispatcher
    install_reconcile_worker
    install_rollback_helper

    install_apt_hook_shim
    install_apt_hook_guard
    neutralize_legacy_integrations
    install_grub_build_policy
    install_custom_db_policy

    if have_cmd systemctl; then
        install_systemd_units
    else
        echo "WARN: systemctl not found; skipping systemd units." >&2
    fi

    ok "Log: $LOG_FILE"
}

main "$@"
