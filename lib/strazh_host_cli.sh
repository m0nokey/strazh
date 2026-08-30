#!/usr/bin/env bash
# Strazh: small interactive administration utility installed on the host.
#
# The repository run.sh owns the initial installation pipeline.  This command
# remains available after that directory is removed and provides the safe,
# interactive FDE passphrase rotation and read-only verification operations.
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

STATE_FILE="/var/lib/strazh/pipeline.state"
PIPELINE_LOCK_FILE="/run/strazh-pipeline.lock"
SB_GUARD_LOCK_FILE="/run/sb-guard.lock"
FDE_KEYFILE_PATH="/etc/cryptsetup-keys.d/root.key"
FDE_MIN_PASSPHRASE_LENGTH="${STRAZH_FDE_MIN_PASSPHRASE_LENGTH:-12}"
PBKDF2_ITER_TIME_MS="${STRAZH_PBKDF2_ITER_TIME_MS:-5000}"

if [[ -t 1 ]]; then
    BLUE=$'\033[38;5;117m'
    WHITE=$'\033[97m'
    MUTED_ITALIC=$'\033[3;38;5;245m'
    WARN=$'\033[38;5;221m'
    RESET=$'\033[0m'
else
    BLUE=''
    WHITE=''
    MUTED_ITALIC=''
    WARN=''
    RESET=''
fi

log() {
    printf '[strazh] %s\n' "$*" >&2
}

die() {
    log "ERROR: $*"
    exit 1
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

require_root() {
    [[ "$(id -u)" -eq 0 ]] || die "Run this command as root."
}

ui_clear() {
    [[ -t 1 ]] || return 0
    printf '\033[H\033[2J\033[3J'
}

ui_heading() {
    printf '%s%s%s\n' "$BLUE" "$1" "$RESET"
}

ui_option() {
    local number="$1" title="$2" description="${3:-}"
    printf '%s%s.%s %s%s%s\n' "$BLUE" "$number" "$RESET" "$WHITE" "$title" "$RESET"
    [[ -n "$description" ]] &&
        printf '   %s%s%s\n' "$MUTED_ITALIC" "$description" "$RESET"
}

ui_control() {
    printf '%s%s.%s %s%s%s\n' "$BLUE" "$1" "$RESET" "$WHITE" "$2" "$RESET"
}

ui_confirm() {
    local prompt="$1" answer
    while true; do
        printf '%b [y/n] ' "$prompt" >&2
        IFS= read -r answer < /dev/tty || return 1
        case "$answer" in
            y|Y|yes|YES) return 0 ;;
            n|N|no|NO) return 1 ;;
            *) printf '%bPlease answer y or n.%b\n' "$WARN" "$RESET" >&2 ;;
        esac
    done
}

ui_return_to_menu() {
    local key
    printf '\n%bPress Enter or Space to return to the menu.%b' \
        "$MUTED_ITALIC" "$RESET"
    while true; do
        IFS= read -r -n 1 -s key < /dev/tty || return 0
        case "$key" in
            ''|' ')
                printf '\n'
                return 0
                ;;
        esac
    done
}

with_locks() {
    local rc=0
    exec 9>"$PIPELINE_LOCK_FILE"
    flock -w 300 9 || die "Could not acquire lock: $PIPELINE_LOCK_FILE"
    exec 200>"$SB_GUARD_LOCK_FILE"
    flock -w 300 200 || {
        flock -u 9 >/dev/null 2>&1 || true
        die "Could not acquire lock: $SB_GUARD_LOCK_FILE"
    }
    export SB_GUARD_LOCK_HELD=1
    if "$@"; then
        rc=0
    else
        rc=$?
    fi
    flock -u 200 >/dev/null 2>&1 || true
    flock -u 9 >/dev/null 2>&1 || true
    unset SB_GUARD_LOCK_HELD
    return "$rc"
}

with_pipeline_lock() {
    local rc=0
    exec 9>"$PIPELINE_LOCK_FILE"
    flock -w 300 9 || die "Could not acquire lock: $PIPELINE_LOCK_FILE"
    if "$@"; then
        rc=0
    else
        rc=$?
    fi
    flock -u 9 >/dev/null 2>&1 || true
    return "$rc"
}

root_luks_device() {
    local root_source dev
    root_source="$(findmnt -nro SOURCE / 2>/dev/null || true)"
    [[ "$root_source" == /dev/mapper/* ]] || return 1
    while IFS=' ' read -r dev _; do
        [[ -b "$dev" ]] || continue
        if cryptsetup isLuks "$dev" >/dev/null 2>&1; then
            printf '%s\n' "$dev"
            return 0
        fi
    done < <(lsblk -r -n -s -p -o NAME,TYPE "$root_source" 2>/dev/null)
    return 1
}

change_fde_passphrase() (
    local luks_dev luks_version old_pass new_pass confirm
    local temp_dir old_file new_file key_stat

    [[ -t 0 && -t 1 ]] || die "Changing the FDE passphrase requires an interactive TTY"
    [[ "$FDE_MIN_PASSPHRASE_LENGTH" =~ ^[1-9][0-9]*$ ]] ||
        die "Invalid STRAZH_FDE_MIN_PASSPHRASE_LENGTH policy"
    [[ "$PBKDF2_ITER_TIME_MS" =~ ^[1-9][0-9]*$ ]] ||
        die "Invalid STRAZH_PBKDF2_ITER_TIME_MS policy"
    luks_dev="$(root_luks_device || true)"
    [[ -n "$luks_dev" && -b "$luks_dev" ]] ||
        die "Cannot detect the LUKS device backing the root filesystem"
    cryptsetup isLuks "$luks_dev" >/dev/null 2>&1 ||
        die "Root device is not a LUKS container: $luks_dev"
    luks_version="$(cryptsetup luksDump "$luks_dev" 2>/dev/null |
        awk -F: '/^Version:/{gsub(/[[:space:]]/, "", $2); print $2; exit}')"
    [[ "$luks_version" == "2" ]] ||
        die "FDE passphrase rotation requires LUKS2 (found ${luks_version:-unknown})"

    temp_dir="$(mktemp -d -p /run strazh-fde-pass.XXXXXX)" ||
        die "Cannot create a protected temporary directory in /run"
    chmod 0700 "$temp_dir"
    old_file="$temp_dir/old"
    new_file="$temp_dir/new"
    cleanup_passphrase_files() {
        unset -v old_pass new_pass confirm
        rm -f -- "$old_file" "$new_file"
        rmdir -- "$temp_dir" 2>/dev/null || true
    }
    trap cleanup_passphrase_files EXIT

    printf 'Enter current FDE passphrase: ' >&2
    IFS= read -r -s old_pass < /dev/tty || die "Could not read the current FDE passphrase"
    printf '\n' >&2
    [[ -n "$old_pass" ]] || die "Current FDE passphrase cannot be empty"
    printf '%s' "$old_pass" >"$old_file"
    chmod 0600 "$old_file"
    cryptsetup open --test-passphrase "$luks_dev" --key-file "$old_file" >/dev/null 2>&1 ||
        die "Current FDE passphrase was rejected; no changes were made"

    printf 'Enter new FDE passphrase (minimum %s characters): ' \
        "$FDE_MIN_PASSPHRASE_LENGTH" >&2
    IFS= read -r -s new_pass < /dev/tty || die "Could not read the new FDE passphrase"
    printf '\n' >&2
    [[ -n "$new_pass" ]] || die "New FDE passphrase cannot be empty"
    (( ${#new_pass} >= FDE_MIN_PASSPHRASE_LENGTH )) ||
        die "New FDE passphrase is too short (minimum ${FDE_MIN_PASSPHRASE_LENGTH} characters)"
    [[ "$new_pass" != "$old_pass" ]] ||
        die "New FDE passphrase must differ from the current one"

    printf 'Confirm new FDE passphrase: ' >&2
    IFS= read -r -s confirm < /dev/tty || die "Could not read passphrase confirmation"
    printf '\n' >&2
    [[ "$new_pass" == "$confirm" ]] || die "New FDE passphrase confirmation does not match"
    printf '%s' "$new_pass" >"$new_file"
    chmod 0600 "$new_file"

    ui_confirm 'Replace the current FDE passphrase now?' || {
        log "FDE passphrase change cancelled; no changes were made"
        return 0
    }

    log "Changing one matching LUKS2 keyslot and preserving PBKDF2 compatibility..."
    cryptsetup luksChangeKey "$luks_dev" "$new_file" \
        --key-file "$old_file" --pbkdf pbkdf2 \
        --iter-time "$PBKDF2_ITER_TIME_MS" --batch-mode

    cryptsetup open --test-passphrase "$luks_dev" --key-file "$new_file" >/dev/null 2>&1 ||
        die "New FDE passphrase verification failed"
    cryptsetup luksDump "$luks_dev" 2>/dev/null |
        grep -qE 'PBKDF:[[:space:]]*pbkdf2' ||
        die "PBKDF2 slot is missing after passphrase change"

    if [[ -f "$FDE_KEYFILE_PATH" && ! -L "$FDE_KEYFILE_PATH" ]]; then
        key_stat="$(stat -c '%u:%g:%a' "$FDE_KEYFILE_PATH" 2>/dev/null || true)"
        [[ "$key_stat" == "0:0:400" ]] ||
            die "FDE keyfile owner/mode changed unexpectedly"
        cryptsetup open --test-passphrase "$luks_dev" --key-file "$FDE_KEYFILE_PATH" >/dev/null 2>&1 ||
            die "FDE keyfile no longer unlocks its LUKS slot"
    fi

    if cryptsetup open --test-passphrase "$luks_dev" --key-file "$old_file" >/dev/null 2>&1; then
        log "WARNING: the old passphrase still unlocks another LUKS slot; no slots were removed automatically"
    else
        log "Old FDE passphrase no longer unlocks the changed keyslot"
    fi
    log "FDE passphrase changed and verified; PBKDF2 and keyfile checks passed"
)

state_value() {
    local key="$1"
    [[ -r "$STATE_FILE" ]] || return 0
    awk -F= -v wanted="$key" '$1 == wanted { print substr($0, index($0, "=") + 1); exit }' \
        "$STATE_FILE"
}

show_status() {
    ui_heading 'Strazh — host status'
    printf '  phase=%s\n' "$(state_value phase || true)"
    printf '  fde_ready=%s\n' "$(state_value phase | grep -Eq 'complete|secure_boot|release' && printf yes || printf unknown)"
    if [[ -x /usr/local/sbin/sb-guard-svc ]]; then
        printf '  sb_guard=installed\n'
    else
        printf '  sb_guard=not-installed\n'
    fi
}

verify_secure_boot() {
    [[ -x /usr/local/sbin/sb-guard-svc ]] || die "sb-guard-svc is not installed"
    /usr/local/sbin/sb-guard-svc --verify
}

reconcile_boot_files() {
    [[ -x /usr/local/sbin/sb-guard-svc ]] || die "sb-guard-svc is not installed"
    ui_confirm 'Reconcile boot files now?' || {
        log "Boot reconciliation cancelled; no changes were made"
        return 0
    }
    /usr/local/sbin/sb-guard-svc --fix-all
}

restore_last_good() {
    [[ -x /usr/local/sbin/sb-guard-rollback ]] ||
        die "sb-guard-rollback is not installed"
    ui_confirm 'Restore the last known-good boot set now?' || {
        log "Rollback cancelled; no changes were made"
        return 0
    }
    /usr/local/sbin/sb-guard-rollback --restore
}

draw_menu() {
    ui_heading 'Strazh — host administration'
    echo
    ui_option 1 'Show System Status' \
        'Display the saved Strazh pipeline state'
    ui_option 2 'Change FDE Passphrase' \
        'Replace the human LUKS unlock phrase with confirmation and verification'
    ui_option 3 'Verify Secure Boot' \
        'Run strict ESP, signature, SBAT and GPG verification'
    ui_option 4 'Reconcile Boot Files' \
        'Build, verify and atomically deploy the approved boot set'
    ui_option 5 'Restore Last Known-good Boot Set' \
        'Restore the verified rollback copy after a failed update'
    echo
    ui_control x 'Exit'
    echo
}

usage() {
    printf 'Usage: %s [--menu|--status|--change-fde-passphrase|--verify|--reconcile|--restore]\n' "$0"
    printf '%s\n' '--menu: open the interactive host administration menu.'
    printf '%s\n' '--status: show the saved installation state.'
    printf '%s\n' '--change-fde-passphrase: rotate one root LUKS2 passphrase interactively.'
    printf '%s\n' '--verify: run strict Secure Boot verification.'
    printf '%s\n' '--reconcile: verify and atomically reconcile the approved boot files.'
    printf '%s\n' '--restore: restore the last known-good boot set after confirmation.'
}

menu() {
    local choice
    [[ -t 0 && -t 1 ]] || die "The menu requires a TTY; use an explicit command option"
    while true; do
        ui_clear
        draw_menu
        read -r -p "${BLUE}?:${RESET} " choice || return 0
        ui_clear
        case "$choice" in
            1)
                show_status
                ui_return_to_menu
                ;;
            2)
                if ! with_locks change_fde_passphrase; then
                    :
                fi
                ui_return_to_menu
                ;;
            3)
                if ! with_locks verify_secure_boot; then
                    :
                fi
                ui_return_to_menu
                ;;
            4)
                if ! with_pipeline_lock reconcile_boot_files; then
                    :
                fi
                ui_return_to_menu
                ;;
            5)
                if ! with_pipeline_lock restore_last_good; then
                    :
                fi
                ui_return_to_menu
                ;;
            x|X) return 0 ;;
            *)
                die "Unknown menu option: $choice"
                ;;
        esac
    done
}

main() {
    local mode=menu
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --menu) mode=menu ;;
            --status) mode=status ;;
            --change-fde-passphrase) mode=change ;;
            --verify) mode=verify ;;
            --reconcile) mode=reconcile ;;
            --restore|--rollback) mode=restore ;;
            -h|--help) usage; return 0 ;;
            *) die "Unknown argument: $1" ;;
        esac
        shift
    done

    require_root
    need_cmd awk
    need_cmd cryptsetup
    need_cmd findmnt
    need_cmd flock
    need_cmd lsblk
    need_cmd grep
    need_cmd mktemp
    need_cmd stat

    case "$mode" in
        menu) menu ;;
        status) show_status ;;
        change) with_locks change_fde_passphrase ;;
        verify) with_locks verify_secure_boot ;;
        reconcile) with_pipeline_lock reconcile_boot_files ;;
        restore) with_pipeline_lock restore_last_good ;;
    esac
}

trap 'exit 130' INT TERM
main "$@"
