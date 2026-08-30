#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 m0nokey
# Strazh: one idempotent run.sh entry point for the four installation stages.
#
# The implementation files under lib/ are private building blocks. This file
# is the only public entry point; progress is persisted outside the project
# tree and the user explicitly reruns this script after each required reboot.
# No stage is considered complete from a marker alone: the live system is
# checked before a stale marker can be adopted.
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
FDE_IMPLEMENTATION="$SCRIPT_DIR/lib/fde_debian_net_install.sh"
PVE_IMPLEMENTATION="$SCRIPT_DIR/lib/sb_proxmox.sh"
SB_GUARD_IMPLEMENTATION="$SCRIPT_DIR/lib/sb_guard_install.sh"
STATE_ROOT="${STRAZH_STATE_ROOT:-/var/lib/strazh}"
STATE_FILE="$STATE_ROOT/pipeline.state"
LOCK_FILE="${STRAZH_LOCK_FILE:-/run/strazh-pipeline.lock}"
SB_GUARD_LOCK_FILE="/run/sb-guard.lock"
SB_GUARD_ENROLLMENT_HOLD="/var/lib/sb-guard/awaiting-enrollment"
PVE_STAGE_FILE="/var/lib/pve-install.stage"
FDE_KEYFILE_PATH="/etc/cryptsetup-keys.d/root.key"
STRAZH_HOST_CLI_DST="/usr/local/sbin/strazh"
RESUME_UNIT="strazh-resume.service"
RESUME_UNIT_FILE="/etc/systemd/system/$RESUME_UNIT"
# Before custom Secure Boot is enrolled, one ordinary Debian EFI loader must
# remain available to reach the newly installed kernel.  Stage 3 replaces it
# with the custom-only proxmox layout.
TRANSITIONAL_EFI_DIR="/boot/efi/EFI/debian"

if [[ -t 1 ]]; then
    # Match Nitka's terminal palette: light blue labels, white text and
    # muted gray descriptions.  Never emit escape sequences in redirected
    # output, which keeps agent logs and scripted callers parseable.
    BLUE=$'\033[38;5;117m'
    WHITE=$'\033[97m'
    GRAY=$'\033[38;5;245m'
    MUTED_ITALIC=$'\033[3;38;5;245m'
    SUCCESS=$'\033[32m'
    WARN=$'\033[38;5;221m'
    DANGER=$'\033[31m'
    RESET=$'\033[0m'
else
    BLUE=''
    WHITE=''
    GRAY=''
    MUTED_ITALIC=''
    SUCCESS=''
    WARN=''
    DANGER=''
    RESET=''
fi
RUNNING_PHASE=""
NONINTERACTIVE=0
LOCK_HELD=0
SECURE_BOOT_MODE="full"
DEBUG_MODE="${STRAZH_DEBUG:-0}"
MENU_REQUESTED=0

SECURE_BOOT_CUSTOM_BUILDER_DST="/usr/local/sbin/sb-shim-build-custom"
SECURE_BOOT_GRUB_PROFILE_DST="/usr/local/sbin/sb-grub-profile-chroot"
SECURE_BOOT_SHIM_SOURCE_DST="/usr/local/sbin/sb-shim-source-chroot"
SECURE_BOOT_WORKERS_WERE_ACTIVE=0
SECURE_BOOT_PATH_WAS_ACTIVE=0
SECURE_BOOT_TIMER_WAS_ACTIVE=0
SECURE_BOOT_PATH_WAS_ENABLED=0
SECURE_BOOT_TIMER_WAS_ENABLED=0
SECURE_BOOT_STAGE_COMPLETED=0

log() {
    printf '[strazh] %s\n' "$*" >&2
}

ui_heading() {
    printf '%s%s%s\n' "$BLUE" "$1" "$RESET"
}

ui_clear() {
    # Clear only an interactive terminal. Redirected output must stay plain
    # and complete so that logs and automation remain machine-readable.
    [[ -t 1 ]] || return 0
    printf '\033[H\033[2J\033[3J'
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

ui_step_start() {
    printf '%s…%s %s%s%s\n' "$BLUE" "$RESET" "$WHITE" "$1" "$RESET"
}

ui_step_ok() {
    printf '%s✓%s %s%s%s\n' "$SUCCESS" "$RESET" "$WHITE" "$1" "$RESET"
}

ui_step_fail() {
    printf '%s✗%s %s%s%s\n' "$WARN" "$RESET" "$WHITE" "$1" "$RESET" >&2
}

ui_status_line() {
    local mark="$1" color="$2" label="$3"
    printf '  %b%s%b %s\n' "$color" "$mark" "$RESET" "$label"
}

ui_rule() {
    printf '%b%s%b\n' "$GRAY" '------------------------------------------------------------------------------------------' "$RESET"
}

ui_next() {
    printf '  %bNext:%b %b%s%b\n' "$WHITE" "$RESET" "$DANGER" "$1" "$RESET"
}

ui_next_detail() {
    printf '  %b%s%b\n' "$MUTED_ITALIC" "$1" "$RESET"
}

ui_pause() {
    [[ -t 0 && -t 1 ]] || return 0
    printf '\n%bPress Enter to continue.%b' "$MUTED_ITALIC" "$RESET"
    read -r _ || true
}

ui_confirm() {
    local prompt="$1" answer
    while true; do
        printf '%b [y/n] ' "$prompt" >&2
        IFS= read -r answer < /dev/tty || return 1
        case "$answer" in
            y|Y|yes|YES) return 0 ;;
            n|N|no|NO) return 1 ;;
            *)
                printf '%bPlease answer y or n.%b\n' "$WARN" "$RESET" >&2
                ;;
        esac
    done
}

run_quiet_step() {
    # Build tools are intentionally quiet in the interactive UI.  Their full
    # output remains available for audit and is printed on failure only.
    local label="$1" log_dir log_file rc slug
    shift
    log_dir=/var/log/strazh/pipeline
    install -d -m 0700 -o root -g root "$log_dir"
    slug="${label//[^A-Za-z0-9._-]/_}"
    log_file="$(mktemp "$log_dir/${slug}.XXXXXX.log")"
    ui_step_start "$label"
    if [[ "$DEBUG_MODE" == "1" ]]; then
        # Debug mode mirrors complete child output while retaining the audit log.
        set +e
        "$@" 2>&1 | tee "$log_file"
        rc="${PIPESTATUS[0]}"
        set -e
    else
        set +e
        "$@" >"$log_file" 2>&1
        rc=$?
        set -e
    fi
    if (( rc == 0 )); then
        ui_step_ok "$label"
        [[ "$DEBUG_MODE" == "1" ]] && log "Detailed log: $log_file"
        return 0
    fi
    ui_step_fail "$label (rc=$rc)"
    printf '%s\n' "Log: $log_file" >&2
    tail -n 40 "$log_file" >&2 || true
    return "$rc"
}

die() {
    log "ERROR: $*"
    exit 1
}

require_root() {
    [[ "$(id -u)" -eq 0 ]] || die "Run this command as root."
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

install_host_cli() {
    install -D -m 0750 -o root -g root /dev/stdin "$STRAZH_HOST_CLI_DST" <<'STRAZH_HOST_CLI' || die "Cannot install embedded host utility: $STRAZH_HOST_CLI_DST"
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
    GRAY=$'\033[38;5;245m'
    MUTED_ITALIC=$'\033[3;38;5;245m'
    SUCCESS=$'\033[32m'
    WARN=$'\033[38;5;221m'
    DANGER=$'\033[31m'
    RESET=$'\033[0m'
else
    BLUE=''
    WHITE=''
    GRAY=''
    MUTED_ITALIC=''
    SUCCESS=''
    WARN=''
    DANGER=''
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
STRAZH_HOST_CLI
    bash -n "$STRAZH_HOST_CLI_DST" || {
        rm -f -- "$STRAZH_HOST_CLI_DST"
        die "Embedded host utility failed syntax validation"
    }
}

acquire_lock() {
    ((LOCK_HELD == 1)) && return 0
    exec 9>"$LOCK_FILE"
    flock -w 300 9 || die "Could not acquire lock: $LOCK_FILE"
    LOCK_HELD=1
}

release_lock() {
    ((LOCK_HELD == 1)) || return 0
    # The descriptor is closed automatically at process exit, but keep the
    # caller alive if an unlock ioctl is rejected after the child completed.
    flock -u 9 >/dev/null 2>&1 || true
    LOCK_HELD=0
}

with_lock() {
    acquire_lock
    local rc=0
    if "$@"; then
        rc=0
    else
        rc=$?
    fi
    release_lock
    return "$rc"
}

with_sb_guard_lock() {
    # The pipeline lock serializes the menu/state file.  The sb-guard lock is
    # a separate system-wide lock shared with APT reconciliation, release
    # apply, rollback and direct maintenance commands.  Keep it for the
    # complete build -> apply -> verify transaction, not once per child.
    exec 200>"$SB_GUARD_LOCK_FILE"
    flock -w 300 200 || die "Could not acquire lock: $SB_GUARD_LOCK_FILE"
    export SB_GUARD_LOCK_HELD=1
    set +e
    "$@"
    local rc=$?
    set -e
    # Do not let a cleanup ioctl failure mask the child result; fd 200 is
    # still closed automatically when this process exits.
    flock -u 200 >/dev/null 2>&1 || true
    unset SB_GUARD_LOCK_HELD
    return "$rc"
}

run_external() {
    # Keep the caller's fail-closed mode while preserving the child's status.
    # This avoids the common `if ! command; then rc=$?` status inversion.
    # Run in a subshell and close both orchestration lock descriptors.  The
    # parent keeps the locks; descendants such as grub-probe/vgs must not
    # inherit them and print descriptor-leak warnings.
    local rc
    set +e
    (
        exec 9>&- 200>&-
        "$@"
    )
    rc=$?
    set -e
    return "$rc"
}

state_init() {
    local line key value tmp
    [[ "$STATE_ROOT" == "/var/lib/strazh" && "$LOCK_FILE" == "/run/strazh-pipeline.lock" ]] ||
        die "State and lock paths must remain fixed protected paths"
    [[ ! -L "$STATE_ROOT" ]] || die "State root must not be a symlink: $STATE_ROOT"
    install -d -m 0700 -o root -g root "$STATE_ROOT"
    if [[ ! -e "$STATE_FILE" ]]; then
        tmp="$(mktemp -p "$STATE_ROOT" .pipeline.state.XXXXXX)"
        {
            printf 'schema=1\n'
            printf 'pipeline=strazh-fde-pve-sb-v1\n'
            printf 'phase=init\n'
            printf 'created_at=%s\n' "$(date -Is)"
        } >"$tmp"
        chmod 0600 "$tmp"
        mv -f -- "$tmp" "$STATE_FILE"
    fi

    [[ -f "$STATE_FILE" && ! -L "$STATE_FILE" ]] || die "Invalid state file: $STATE_FILE"
    [[ "$(stat -c '%u:%g:%a' "$STATE_FILE" 2>/dev/null)" == "0:0:600" ]] ||
        die "Invalid owner or mode on state file: $STATE_FILE"
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        [[ "$line" == *=* ]] || die "Corrupt state file: $STATE_FILE"
        key="${line%%=*}"
        value="${line#*=}"
        [[ "$key" =~ ^[a-z_][a-z0-9_]*$ ]] || die "Corrupt state file: $STATE_FILE"
        [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || die "Newline in state file"
    done <"$STATE_FILE"
    [[ "$(state_get schema)" == "1" ]] || die "Unsupported state file version"
    [[ "$(state_get pipeline)" == "strazh-fde-pve-sb-v1" ]] || die "Foreign state file: $STATE_FILE"
}

state_get() {
    local key="$1" fallback="${2:-}"
    [[ -r "$STATE_FILE" ]] || {
        printf '%s\n' "$fallback"
        return 0
    }
    awk -F= -v key="$key" -v fallback="$fallback" '
        $1 == key { value = substr($0, index($0, "=") + 1) }
        END { if (value == "") print fallback; else print value }
    ' "$STATE_FILE"
}

state_set() {
    local key="$1" value="$2" tmp
    [[ "$key" =~ ^[a-z_][a-z0-9_]*$ ]] || die "Invalid state key: $key"
    [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || die "Invalid state value"
    tmp="$(mktemp -p "$STATE_ROOT" .pipeline.state.XXXXXX)"
    if [[ -s "$STATE_FILE" ]]; then
        awk -F= -v key="$key" '$1 != key { print }' "$STATE_FILE" >"$tmp"
    fi
    printf '%s=%s\n' "$key" "$value" >>"$tmp"
    chmod 0600 "$tmp"
    mv -f -- "$tmp" "$STATE_FILE"
}

set_phase() {
    state_set phase "$1"
    state_set updated_at "$(date -Is)"
}

record_error() {
    state_set last_rc "$1"
    state_set last_error_at "$(date -Is)"
}

clear_error() {
    state_set last_rc 0
    state_set last_error_at ""
}

boot_id() {
    cat /proc/sys/kernel/random/boot_id 2>/dev/null || true
}

reboot_seen() {
    local previous current
    previous="$(state_get pending_boot_id)"
    current="$(boot_id)"
    [[ -n "$previous" && -n "$current" && "$previous" != "$current" ]]
}

remove_resume_unit() {
    # The installation pipeline is deliberately user-driven.  Remove a unit
    # left by an older Strazh release so it cannot race a manual invocation.
    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now "$RESUME_UNIT" >/dev/null 2>&1 || true
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    rm -f -- "$RESUME_UNIT_FILE"
}

pipeline_checklist() {
    local phase db_ready=0 sb_state
    local fde_mark='·' fde_color="$GRAY"
    local pve_mark='·' pve_color="$GRAY"
    local sb_mark='·' sb_color="$GRAY"
    local release_mark='·' release_color="$GRAY"
    phase="$(state_get phase init)"
    db_is_enrolled && db_ready=1 || true
    sb_state="$(firmware_secure_boot_state)"

    if fde_ready; then
        fde_mark='✓'
        fde_color="$SUCCESS"
    fi
    if pve_ready; then
        pve_mark='✓'
        pve_color="$SUCCESS"
    fi
    if (( db_ready == 1 )) && secure_boot_artifacts_ready; then
        sb_mark='✓'
        sb_color="$SUCCESS"
    elif secure_boot_artifacts_ready; then
        sb_mark='…'
        sb_color="$WARN"
    fi
    if [[ "$phase" == complete ]]; then
        release_mark='✓'
        release_color="$SUCCESS"
    fi

    printf '\n'
    ui_rule
    printf '%bPipeline status%b\n' "$BLUE" "$RESET"
    ui_status_line "$fde_mark" "$fde_color" 'Full Disk Encryption'
    ui_status_line "$pve_mark" "$pve_color" 'Proxmox VE'
    ui_status_line "$sb_mark" "$sb_color" 'Secure Boot'
    ui_status_line "$release_mark" "$release_color" 'Production release'
    printf '  %bphase=%s%b\n' "$GRAY" "$phase" "$RESET"
    case "$phase" in
        init|fde_pending)
            if [[ "$sb_state" == enabled ]]; then
                ui_next 'Reboot, enter BIOS/UEFI, disable Secure Boot, boot Debian, then run bash ./run.sh again.'
            else
                ui_next 'Choose a menu item; if unsure, choose 6 to continue automatically.'
            fi
            ;;
        fde_reboot_pending)
            ui_next 'Reboot, then run bash ./run.sh again.' ;;
        pve_reboot_pending)
            ui_next 'Reboot into the PVE kernel, then run bash ./run.sh again.' ;;
        secure_boot_enrollment)
            ui_next 'Reboot into UEFI, enroll PK/KEK/db, enable Secure Boot, boot Debian, then run bash ./run.sh again.'
            ui_next_detail 'KeyTool: /boot/efi/EFI/SB/KeyTool.efi'
            ui_next_detail 'Enrollment files: /boot/efi/EFI/SB/ENROLL/ (use PK.auth, KEK.auth, db.auth; .cer/.der are firmware fallbacks)' ;;
        secure_boot_done)
            ui_next 'Choose option 4 or run bash ./run.sh --release.' ;;
        complete)
            ui_next 'Nothing. Run --status for a final report.' ;;
        *)
            ui_next 'Choose a menu item; if unsure, choose 6 to continue automatically.' ;;
    esac
    printf '  %b· not installed   … pending   ✓ installed%b\n' "$GRAY" "$RESET"
    ui_rule
}

schedule_reboot() {
    local reason="$1"
    state_set pending_boot_id "$(boot_id)"
    state_set reboot_reason "$reason"
    pipeline_checklist
    request_reboot "$reason"
}

request_reboot() {
    local reason="$1"
    printf '\n'
    ui_heading 'REBOOT REQUIRED'
    printf '%b%s%b\n' "$WHITE" "$reason" "$RESET"
    printf '  %bThe next pipeline stage starts after reboot.%b\n' "$MUTED_ITALIC" "$RESET"

    if [[ "${STRAZH_NO_REBOOT:-0}" == "1" ]]; then
        log "STRAZH_NO_REBOOT=1: reboot suppressed; run 'reboot' manually."
        return 0
    fi
    if [[ "${STRAZH_AUTO_REBOOT:-0}" == "1" ]]; then
        log "STRAZH_AUTO_REBOOT=1: rebooting in 5 seconds."
        sleep 5
        sync
        systemctl reboot
        return 0
    fi
    if [[ -t 0 && -t 1 ]]; then
        if ui_confirm "${BLUE}Reboot now?${RESET}"; then
            sync
            systemctl reboot
        else
            log "Reboot postponed. Run 'reboot' when ready, then run 'bash ./run.sh'."
        fi
    else
        log "Automatic reboot is disabled. Run 'reboot', then run 'bash ./run.sh'."
    fi
}

fstab_has_active_boot_mount() {
    awk '
        $0 !~ /^[[:space:]]*#/ && $2 == "/boot" { found = 1 }
        END { exit(found ? 0 : 1) }
    ' /etc/fstab 2>/dev/null
}

fde_keyfile_ready() {
    local key_stat initrd crypt_name
    [[ -f "$FDE_KEYFILE_PATH" && ! -L "$FDE_KEYFILE_PATH" ]] || return 1
    key_stat="$(stat -c '%u:%g:%a' "$FDE_KEYFILE_PATH" 2>/dev/null || true)"
    [[ "$key_stat" == "0:0:400" ]] || return 1
    grep -qF -- "$FDE_KEYFILE_PATH" /etc/crypttab 2>/dev/null || return 1
    command -v lsinitramfs >/dev/null 2>&1 || return 1
    crypt_name="$(awk '$1 !~ /^#/ && NF >= 3 { print $1; exit }' /etc/crypttab 2>/dev/null || true)"
    [[ "$crypt_name" =~ ^[A-Za-z0-9_.@:-]+$ ]] || return 1
    for initrd in /boot/initrd.img-*; do
        [[ -f "$initrd" ]] || continue
        [[ "$initrd" != *.sig ]] || continue
        lsinitramfs "$initrd" 2>/dev/null |
            grep -Fx -- "cryptroot/keyfiles/${crypt_name}.key" >/dev/null ||
            return 1
    done
}

fde_ready() {
    local root_source esp_type
    # A saved old /boot device means a previous migration stopped before its
    # GPT entry was removed.  Do not advance the pipeline until that cleanup
    # transaction is resumed by the FDE implementation.
    [[ ! -e /var/lib/strazh/fde-boot-device ]] || return 1
    ! findmnt -n /boot >/dev/null 2>&1 || return 1
    fstab_has_active_boot_mount && return 1
    root_source="$(findmnt -nro SOURCE / 2>/dev/null || true)"
    [[ "$root_source" == /dev/mapper/* ]] || return 1
    esp_type="$(findmnt -nro FSTYPE /boot/efi 2>/dev/null || true)"
    [[ "$esp_type" == "vfat" ]] || return 1
    grep -q '^GRUB_ENABLE_CRYPTODISK=y$' /etc/default/grub 2>/dev/null || return 1
    [[ -s /etc/crypttab ]] || return 1
    compgen -G '/boot/vmlinuz-*' >/dev/null 2>&1 || return 1
    fde_keyfile_ready || return 1
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

fde_reboot_preflight() {
    local luks_dev luks_version key_stat initrd crypt_name
    need_cmd cryptsetup
    need_cmd lsblk
    need_cmd lsinitramfs
    need_cmd grep
    need_cmd awk

    fde_ready || die "FDE state is not verified before reboot"
    luks_dev="$(root_luks_device || true)"
    [[ -n "$luks_dev" && -b "$luks_dev" ]] ||
        die "Underlying root LUKS device was not found"
    cryptsetup isLuks "$luks_dev" >/dev/null 2>&1 ||
        die "Root device is not a LUKS device: $luks_dev"

    luks_version="$(cryptsetup luksDump "$luks_dev" 2>/dev/null |
        awk -F: '/^Version:/{gsub(/[[:space:]]/, "", $2); print $2; exit}')"
    [[ "$luks_version" == "2" ]] ||
        die "LUKS2 is required before reboot; detected: ${luks_version:-unknown}"
    cryptsetup luksDump "$luks_dev" 2>/dev/null |
        grep -qE 'PBKDF:[[:space:]]*pbkdf2' ||
        die "No compatible PBKDF2 slot exists in LUKS2"

    [[ -f "$FDE_KEYFILE_PATH" && ! -L "$FDE_KEYFILE_PATH" ]] ||
        die "FDE keyfile not found: $FDE_KEYFILE_PATH"
    grep -qF -- "$FDE_KEYFILE_PATH" /etc/crypttab ||
        die "crypttab does not reference the expected FDE keyfile: $FDE_KEYFILE_PATH"
    key_stat="$(stat -c '%u:%g:%a' "$FDE_KEYFILE_PATH" 2>/dev/null || true)"
    [[ "$key_stat" == "0:0:400" ]] ||
        die "Invalid FDE keyfile owner/mode (expected root:root 0400): $FDE_KEYFILE_PATH"
    crypt_name="$(awk '$1 !~ /^#/ && NF >= 3 { print $1; exit }' /etc/crypttab 2>/dev/null || true)"
    [[ "$crypt_name" =~ ^[A-Za-z0-9_.@:-]+$ ]] ||
        die "No valid LUKS mapping name found in /etc/crypttab"
    cryptsetup open --test-passphrase "$luks_dev" --key-file "$FDE_KEYFILE_PATH" >/dev/null 2>&1 ||
        die "FDE keyfile does not unlock the LUKS2 slot; reboot cancelled"

    compgen -G '/boot/initrd.img-*' >/dev/null 2>&1 ||
        die "No initramfs found before reboot"
    for initrd in /boot/initrd.img-*; do
        [[ -f "$initrd" ]] || continue
        [[ "$initrd" != *.sig ]] || continue
        if ! lsinitramfs "$initrd" 2>/dev/null |
            grep -Fx -- "cryptroot/keyfiles/${crypt_name}.key" >/dev/null; then
            die "FDE keyfile mapping is missing from initramfs: $initrd"
        fi
    done
    [[ -s /boot/grub/grub.cfg ]] || die "GRUB configuration not found: /boot/grub/grub.cfg"
    grep -q 'cryptomount' /boot/grub/grub.cfg ||
        die "GRUB configuration has no cryptomount command; reboot cancelled"
    ensure_transitional_efi_loader
    log "FDE preflight passed: LUKS2/PBKDF2, keyfile, initramfs and GRUB cryptomount"
}

package_installed() {
    [[ "$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null || true)" == "install ok installed" ]]
}

pve_kernel_running() {
    [[ "$(uname -r)" == *-pve* ]]
}

transitional_efi_loader_path() {
    local path
    for path in "$TRANSITIONAL_EFI_DIR/shimx64.efi" \
        "$TRANSITIONAL_EFI_DIR/grubx64.efi"; do
        [[ -s "$path" && ! -L "$path" ]] || continue
        printf '%s\n' "$path"
        return 0
    done
    return 1
}

repair_transitional_efi_loader() (
    local esp_rw=0 rc=0

    [[ "$NONINTERACTIVE" -eq 0 && -t 0 && -t 1 ]] ||
        die "No transitional EFI loader exists; interactive repair is required before reboot."
    printf '\n%bNo transitional Debian EFI loader was found on the ESP.%b\n' \
        "$WARN" "$RESET"
    printf '%bThe script can restore it from the installed GRUB packages.\n' "$WHITE"
    printf '  %bNo arbitrary EFI file or network source will be used.%b\n' \
        "$MUTED_ITALIC" "$RESET"
    ui_confirm "${BLUE}Restore the transitional loader now?${RESET}" ||
        die "EFI loader repair declined; reboot cancelled."

    need_cmd findmnt
    need_cmd mount
    need_cmd grub-install
    [[ "$(findmnt -nro FSTYPE /boot/efi 2>/dev/null || true)" == "vfat" ]] ||
        die "The ESP is not mounted as vfat at /boot/efi; loader repair cancelled."
    [[ -d /boot/efi/EFI ]] ||
        die "ESP /boot/efi/EFI is missing; loader repair cancelled."

    # Package scripts are not allowed to write the protected ESP.  This is a
    # one-purpose, short repair window and is always closed by the EXIT trap.
    trap 'rc=$?; if (( esp_rw == 1 )); then
        mount -o remount,ro /boot/efi >/dev/null 2>&1 || {
            log "ERROR: could not restore ESP read-only mount after loader repair";
            rc=1;
        };
    fi; exit "$rc"' EXIT
    mount -o remount,rw /boot/efi ||
        die "Could not open the ESP for the controlled loader repair."
    esp_rw=1

    log "Restoring transitional Debian EFI loader from installed packages…"
    if run_external grub-install --target=x86_64-efi \
        --efi-directory=/boot/efi --bootloader-id=debian --recheck; then
        :
    else
        rc=$?
        log "ERROR: grub-install failed during transitional loader repair (rc=$rc)"
    fi
    if (( rc == 0 )) && ! transitional_efi_loader_path >/dev/null; then
        log "ERROR: grub-install returned success but no Debian EFI loader was created"
        rc=1
    fi
    (( rc == 0 )) || exit "$rc"
    log "Transitional EFI loader restored; ESP will be remounted ro."
)

ensure_transitional_efi_loader() {
    local loader
    if loader="$(transitional_efi_loader_path 2>/dev/null)"; then
        log "Preflight EFI loader OK: $loader"
        return 0
    fi
    repair_transitional_efi_loader
    loader="$(transitional_efi_loader_path 2>/dev/null || true)"
    [[ -n "$loader" ]] || die "Transitional EFI loader is still missing; reboot cancelled."
    log "Preflight EFI loader restored: $loader"
}

firmware_secure_boot_state() {
    local output efivar value

    # mokutil is the least ambiguous interface when available.  Do not
    # silently treat an unreadable/unsupported firmware variable as disabled:
    # Stage 2 installs a vendor-signed PVE kernel before our custom signing
    # lifecycle exists, so an unknown state must stop before any reboot.
    if command -v mokutil >/dev/null 2>&1; then
        output="$(mokutil --sb-state 2>/dev/null || true)"
        if [[ "$output" =~ [Ss]ecure[Bb]oot[[:space:]]+enabled ]]; then
            printf '%s\n' enabled
            return 0
        fi
        if [[ "$output" =~ [Ss]ecure[Bb]oot[[:space:]]+disabled ]]; then
            printf '%s\n' disabled
            return 0
        fi
    fi

    efivar="$(find /sys/firmware/efi/efivars -maxdepth 1 -type f -name 'SecureBoot-*' -print -quit 2>/dev/null || true)"
    [[ -r "$efivar" ]] || {
        printf '%s\n' unknown
        return 0
    }
    value="$(od -An -t u1 -j 4 -N 1 "$efivar" 2>/dev/null | tr -d '[:space:]' || true)"
    case "$value" in
        1) printf '%s\n' enabled ;;
        0) printf '%s\n' disabled ;;
        *) printf '%s\n' unknown ;;
    esac
}

assert_secure_boot_off_for_pve() {
    local state
    state="$(firmware_secure_boot_state)"
    case "$state" in
        disabled) return 0 ;;
        enabled)
            die "Firmware Secure Boot is enabled. Reboot, enter BIOS/UEFI, disable Secure Boot, boot Debian, then run bash ./run.sh again. Stage 2 is blocked until then."
            ;;
        *)
            die "Cannot determine firmware Secure Boot state; refusing to install/reboot into an unsigned-by-strazh PVE kernel."
            ;;
    esac
}

assert_secure_boot_off_before_fde() {
    local state
    state="$(firmware_secure_boot_state)"
    case "$state" in
        disabled) return 0 ;;
        enabled)
            die "Firmware Secure Boot is enabled. Reboot, enter BIOS/UEFI, disable Secure Boot, boot Debian, then run bash ./run.sh again. FDE is blocked until then."
            ;;
        *)
            die "Cannot determine firmware Secure Boot state; refusing to modify disk before FDE."
            ;;
    esac
}

pve_marker_valid() {
    local marker_line
    [[ -f "$PVE_STAGE_FILE" && ! -L "$PVE_STAGE_FILE" ]] || return 1
    marker_line="$(<"$PVE_STAGE_FILE")"
    [[ "$marker_line" == "stage2" ]] || return 1
    package_installed proxmox-default-kernel || return 1
    compgen -G '/boot/vmlinuz-*-pve' >/dev/null 2>&1
}

pve_ready() {
    package_installed proxmox-ve && pve_kernel_running && [[ ! -e "$PVE_STAGE_FILE" ]]
}

pve_reboot_preflight() {
    local kernel version initrd
    need_cmd grep
    pve_marker_valid || die "Valid Proxmox stage marker is missing before reboot"
    compgen -G '/boot/vmlinuz-*-pve' >/dev/null 2>&1 ||
        die "PVE kernel was not found before reboot"
    [[ -s /boot/grub/grub.cfg ]] || die "GRUB configuration not found before reboot"
    for kernel in /boot/vmlinuz-*-pve; do
        [[ -f "$kernel" ]] || continue
        version="${kernel##*/vmlinuz-}"
        initrd="/boot/initrd.img-$version"
        [[ -s "$initrd" ]] || die "No initramfs exists for PVE kernel: $initrd"
        grep -qF -- "$version" /boot/grub/grub.cfg ||
            die "PVE kernel is missing from grub.cfg: $version"
    done
    ensure_transitional_efi_loader
    log "PVE preflight passed: marker, PVE kernel, initramfs and grub.cfg"
}

# ==============================================================================
# Stage 03 implementation
# ==============================================================================
secure_boot_install_prereqs() {
    local -a packages=()
    command -v sbsign >/dev/null 2>&1 || packages+=(sbsigntool)
    command -v objcopy >/dev/null 2>&1 || packages+=(binutils)
    command -v dpkg-parsechangelog >/dev/null 2>&1 || packages+=(dpkg-dev)
    command -v git >/dev/null 2>&1 || packages+=(git)
    command -v curl >/dev/null 2>&1 || packages+=(curl)
    command -v mmdebstrap >/dev/null 2>&1 || packages+=(mmdebstrap)
    command -v unshare >/dev/null 2>&1 || packages+=(util-linux)
    command -v mount >/dev/null 2>&1 || packages+=(util-linux)
    command -v umount >/dev/null 2>&1 || packages+=(util-linux)
    command -v findmnt >/dev/null 2>&1 || packages+=(util-linux)
    command -v chroot >/dev/null 2>&1 || packages+=(coreutils)
    [[ "${#packages[@]}" -gt 0 ]] || return 0

    log "Installing missing Secure Boot prerequisites: ${packages[*]}"
    if ! DEBIAN_FRONTEND=noninteractive \
        DEBIAN_PRIORITY=critical \
        APT_LISTCHANGES_FRONTEND=none \
        apt-get \
        -o DPkg::Pre-Invoke::= \
        -o DPkg::Post-Invoke::= \
        -o DPkg::Post-Invoke-Success::= \
        -o APT::Update::Post-Invoke::= \
        -o APT::Update::Post-Invoke-Success::= \
        update; then
        log "ERROR: Secure Boot prerequisite update failed"
        return 1
    fi
    if ! DEBIAN_FRONTEND=noninteractive \
        DEBIAN_PRIORITY=critical \
        APT_LISTCHANGES_FRONTEND=none \
        apt-get \
        -o DPkg::Pre-Invoke::= \
        -o DPkg::Post-Invoke::= \
        -o DPkg::Post-Invoke-Success::= \
        -o APT::Update::Post-Invoke::= \
        -o APT::Update::Post-Invoke-Success::= \
        install -y "${packages[@]}"; then
        log "ERROR: Secure Boot prerequisite installation failed"
        return 1
    fi
}

quarantine_pve_enterprise_sources() {
    local source target
    local -a sources=()
    shopt -s nullglob
    sources=(/etc/apt/sources.list.d/pve-enterprise.sources
        /etc/apt/sources.list.d/pve-enterprise.list)
    shopt -u nullglob
    for source in "${sources[@]}"; do
        [[ -f "$source" ]] || continue
        target="${source}.disabled"
        if [[ -e "$target" ]]; then
            target="${source}.disabled.$(date +%Y%m%d-%H%M%S).$$"
        fi
        mv -f -- "$source" "$target" || {
            log "ERROR: cannot quarantine Proxmox enterprise source: $source"
            return 1
        }
        log "Disabled Proxmox enterprise source: $source"
    done
}

secure_boot_activate_profile_policy() {
    install -d -m 0700 -o root -g root /etc/sb-guard || return 1
    if ! cat <<'EOF' | install -m 0600 -o root -g root /dev/stdin /etc/sb-guard/grub-build.env
# sb-guard GRUB build policy
# Pinned reproducible Trixie profile with the standard interactive CLI.
GRUB_BUILD_MODE=profile
GRUB_BUILD_PROFILE=/var/lib/sb-guard/grub-build/profile
GRUB_PROFILE_ENV=/var/lib/sb-guard/grub-build/profile/profile.env
EOF
    then
        return 1
    fi
    log "Activated pinned reproducible GRUB profile policy"
}

secure_boot_remember_workers() {
    systemctl is-active --quiet sb-guard.service && SECURE_BOOT_WORKERS_WERE_ACTIVE=1 || true
    systemctl is-active --quiet sb-guard.path && SECURE_BOOT_PATH_WAS_ACTIVE=1 || true
    systemctl is-active --quiet sb-guard.timer && SECURE_BOOT_TIMER_WAS_ACTIVE=1 || true
    systemctl is-enabled --quiet sb-guard.path && SECURE_BOOT_PATH_WAS_ENABLED=1 || true
    systemctl is-enabled --quiet sb-guard.timer && SECURE_BOOT_TIMER_WAS_ENABLED=1 || true
}

secure_boot_stop_workers() {
    systemctl stop sb-guard.service sb-guard.path sb-guard.timer >/dev/null 2>&1 || true
}

secure_boot_restore_workers_on_failure() {
    (( SECURE_BOOT_STAGE_COMPLETED == 1 )) && return 0
    local restore_rc=0
    # Release fd 200 before starting a worker which needs the same lock.
    flock -u 200 >/dev/null 2>&1 || true
    if (( SECURE_BOOT_PATH_WAS_ENABLED == 1 )); then
        systemctl enable sb-guard.path >/dev/null 2>&1 || {
            log "ERROR: could not restore enabled state for sb-guard.path"
            restore_rc=1
        }
    else
        systemctl disable sb-guard.path >/dev/null 2>&1 || {
            log "ERROR: could not restore disabled state for sb-guard.path"
            restore_rc=1
        }
    fi
    if (( SECURE_BOOT_TIMER_WAS_ENABLED == 1 )); then
        systemctl enable sb-guard.timer >/dev/null 2>&1 || {
            log "ERROR: could not restore enabled state for sb-guard.timer"
            restore_rc=1
        }
    else
        systemctl disable sb-guard.timer >/dev/null 2>&1 || {
            log "ERROR: could not restore disabled state for sb-guard.timer"
            restore_rc=1
        }
    fi
    if (( SECURE_BOOT_WORKERS_WERE_ACTIVE == 1 )); then
        systemctl start sb-guard.service >/dev/null 2>&1 || {
            log "ERROR: could not restore active state for sb-guard.service"
            restore_rc=1
        }
    fi
    if (( SECURE_BOOT_PATH_WAS_ACTIVE == 1 )); then
        systemctl start sb-guard.path >/dev/null 2>&1 || {
            log "ERROR: could not restore active state for sb-guard.path"
            restore_rc=1
        }
    fi
    if (( SECURE_BOOT_TIMER_WAS_ACTIVE == 1 )); then
        systemctl start sb-guard.timer >/dev/null 2>&1 || {
            log "ERROR: could not restore active state for sb-guard.timer"
            restore_rc=1
        }
    fi
    return "$restore_rc"
}

secure_boot_db_is_enrolled() (
    local want got tmp cert
    local -a certs=()
    [[ -s /var/lib/sb-guard/keys/db.crt ]] || return 1
    command -v efi-readvar >/dev/null 2>&1 || return 1
    command -v sig-list-to-certs >/dev/null 2>&1 || return 1
    want="$(openssl x509 -in /var/lib/sb-guard/keys/db.crt -noout -fingerprint -sha256 2>/dev/null |
        sed 's/^[^=]*=//' | tr -d ':' | tr '[:upper:]' '[:lower:]')"
    [[ -n "$want" ]] || return 1
    tmp="$(mktemp -d -p /var/lib/sb-guard .db-enroll.XXXXXX)"
    trap 'rm -rf -- "${tmp:-}"' EXIT
    if ! efi-readvar -v db -o "$tmp/db.esl" >/dev/null 2>&1 ||
        ! sig-list-to-certs "$tmp/db.esl" "$tmp/db" >/dev/null 2>&1; then
        return 1
    fi
    shopt -s nullglob
    certs=("$tmp"/db-*.der)
    shopt -u nullglob
    [[ "${#certs[@]}" -eq 1 ]] || return 1
    for cert in "${certs[@]}"; do
        [[ -s "$cert" ]] || continue
        got="$(openssl x509 -inform DER -in "$cert" -noout -fingerprint -sha256 2>/dev/null |
            sed 's/^[^=]*=//' | tr -d ':' | tr '[:upper:]' '[:lower:]')"
        [[ "$got" == "$want" ]] && return 0
    done
    return 1
)

secure_boot_stage() (
    [[ -d /sys/firmware/efi ]] || die "System must be booted in UEFI mode"
    need_cmd systemctl
    quarantine_pve_enterprise_sources || die "Cannot disable Proxmox enterprise repository"
    secure_boot_remember_workers
    printf '%s\n' "$$" > /run/sb-guard-installing
    chmod 0600 /run/sb-guard-installing
    trap 'rc=$?; rm -f -- /run/sb-guard-installing; if ((rc != 0)); then install -D -m 0600 -o root -g root /dev/null "$SB_GUARD_ENROLLMENT_HOLD" || true; fi; secure_boot_restore_workers_on_failure || true; exit "$rc"' EXIT
    trap 'exit 130' INT TERM
    exec 200>"$SB_GUARD_LOCK_FILE"
    flock -w 300 200 || die "Could not acquire lock: $SB_GUARD_LOCK_FILE"
    export SB_GUARD_LOCK_HELD=1
    secure_boot_stop_workers
    run_quiet_step 'Secure Boot: install prerequisites' secure_boot_install_prereqs ||
        die "Secure Boot prerequisites failed"
    run_quiet_step 'Secure Boot: install sb-guard lifecycle' bash "$SB_GUARD_IMPLEMENTATION" ||
        die "sb-guard lifecycle installation failed"

    # Install private runtime helpers outside /usr/lib. Package scripts never
    # own these paths and never receive Secure Boot private keys.
    install -D -m 0750 -o root -g root \
        "$SCRIPT_DIR/lib/sb_grub_profile_chroot.sh" "$SECURE_BOOT_GRUB_PROFILE_DST" ||
        die "Cannot install GRUB profile helper"
    install -D -m 0750 -o root -g root \
        "$SCRIPT_DIR/lib/sb_shim_source_chroot.sh" "$SECURE_BOOT_SHIM_SOURCE_DST" ||
        die "Cannot install shim source helper"
    [[ -s "$SCRIPT_DIR/lib/sb_shim_auto_build.sh" ]] ||
        die "Missing canonical shim resolver: $SCRIPT_DIR/lib/sb_shim_auto_build.sh"
    [[ -s "$SCRIPT_DIR/lib/sb_shim_build_custom.sh" ]] ||
        die "Missing internal custom shim builder implementation"
    install -D -m 0750 -o root -g root \
        "$SCRIPT_DIR/lib/sb_shim_build_custom.sh" "$SECURE_BOOT_CUSTOM_BUILDER_DST" ||
        die "Cannot install custom shim builder"

    [[ "$SECURE_BOOT_MODE" == install-only ]] && {
        log "Lifecycle installed but not activated (--secure-boot-install-only)."
        # This mode is intentionally non-activating.  Restore the exact
        # service/path/timer state that existed before migration instead of
        # leaving an already protected host without its reconcile worker.
        secure_boot_restore_workers_on_failure
        SECURE_BOOT_STAGE_COMPLETED=1
        return 0
    }

    # The profile builder is content/version aware.  Reuse the verified
    # cached profile on reruns and rebuild only when the installed GRUB
    # package or approved Proxmox source changes.
    run_quiet_step 'Secure Boot: reuse or build GRUB profile' \
        /usr/local/sbin/sb-grub-profile-chroot --ensure-auto ||
        die "GRUB profile build failed"
    secure_boot_activate_profile_policy ||
        die "Cannot activate GRUB profile policy"
    if secure_boot_db_is_enrolled; then
        log "Custom db already enrolled; skipping enrollment bundle refresh"
    else
        run_quiet_step 'Secure Boot: initialize UEFI keys' \
            /usr/local/sbin/sb-install --init-uefi-keys ||
            die "UEFI key initialization failed"
    fi
    run_quiet_step 'Secure Boot: initialize GPG trust root' \
        /usr/local/sbin/sb-install --init-gpg-keys ||
        die "GPG key initialization failed"
    run_quiet_step 'Secure Boot: build or reuse custom shim' \
        /usr/local/sbin/sb-shim-auto-build ||
        die "Custom shim source build failed"
    run_quiet_step 'Secure Boot: sign and publish golden shim' \
        /usr/local/sbin/sb-shim-rebuild --maybe ||
        die "Signed shim publication failed"
    # Do not mutate ESP structure before the complete signed artifact set is
    # ready.  --fix-all performs structure migration inside its atomic deploy.
    local keep_enrollment=1
    secure_boot_db_is_enrolled && keep_enrollment=0
    run_quiet_step 'Secure Boot: atomic ESP deploy and reconcile' \
        env KEEP_ENROLLMENT_BUNDLE="$keep_enrollment" /usr/local/sbin/sb-guard-svc --fix-all ||
        die "Initial sb-guard reconcile failed"

    if secure_boot_db_is_enrolled; then
        rm -f -- "$SB_GUARD_ENROLLMENT_HOLD"
        systemctl enable --now sb-guard.path sb-guard.timer ||
            die "Cannot activate sb-guard workers"
        run_quiet_step 'Secure Boot: final full verification' \
            /usr/local/sbin/sb-guard-svc --verify ||
            die "Initial sb-guard verification failed"
        log "Custom db enrolled; strict Secure Boot workers are active."
        SECURE_BOOT_STAGE_COMPLETED=1
        return 0
    fi

    run_quiet_step 'Secure Boot: refresh enrollment bundle' \
        /usr/local/sbin/sb-install --init-uefi-keys ||
        die "UEFI enrollment bundle refresh failed"
    secure_boot_stop_workers
    systemctl disable sb-guard.path sb-guard.timer >/dev/null 2>&1 || true
    log "Prepared custom-signed chain; enroll db.crt in firmware before reboot."
    log "After enrollment and first boot run: bash ./run.sh"
    SECURE_BOOT_STAGE_COMPLETED=1
)

quarantine_stale_pve_marker() {
    local target
    [[ -e "$PVE_STAGE_FILE" ]] || return 0
    target="$STATE_ROOT/stale-pve-install.stage.$(date +%Y%m%d-%H%M%S).$$"
    mv -f -- "$PVE_STAGE_FILE" "$target"
    chmod 0600 "$target"
    log "Stale Proxmox marker moved to $target"
}

db_is_enrolled() {
    # Keep one implementation for both the pre-stage guard and Stage 03.
    # The helper is a subshell, so its temporary enrollment export is always
    # removed without altering the caller's traps or shell options.
    secure_boot_db_is_enrolled
}

sb_guard_ready() {
    [[ -x /usr/local/sbin/sb-guard-svc && -s /var/lib/sb-guard/keys/db.crt ]]
}

secure_boot_artifacts_ready() {
    local image
    [[ -x /usr/local/sbin/sb-guard-svc ]] || return 1
    [[ -s /var/lib/sb-guard/keys/db.crt ]] || return 1
    [[ -s /var/lib/sb-guard/golden/shimx64.efi ]] || return 1
    [[ -s /boot/efi/EFI/proxmox/shimx64.efi &&
        -s /boot/efi/EFI/proxmox/grubx64.efi ]] || return 1
    command -v sbverify >/dev/null 2>&1 || return 1
    for image in /boot/efi/EFI/proxmox/shimx64.efi \
        /boot/efi/EFI/proxmox/grubx64.efi; do
        sbverify --cert /var/lib/sb-guard/keys/db.crt "$image" >/dev/null 2>&1 || return 1
    done
}

run_fde_stage() {
    local phase
    phase="$(state_get phase)"
    case "$phase" in
        init|fde_pending|fde_running) assert_secure_boot_off_before_fde ;;
    esac
    [[ "$(state_get phase)" != complete ]] || {
        log "Pipeline is already complete; Stage 1 cannot move the state backwards."
        return 0
    }
    if [[ "$phase" == "fde_reboot_pending" ]]; then
        if ! reboot_seen; then
            request_reboot 'FDE is complete; reboot is required before its live verification.'
            return 0
        fi
        fde_ready || die "FDE live verification failed after reboot"
        set_phase fde_done
        state_set pending_boot_id ""
        log "FDE verified after reboot; Stage 1 complete."
        return 0
    fi
    if fde_ready; then
        log "FDE already matches the expected layout; running the required preflight before reboot."
        fde_reboot_preflight
        set_phase fde_reboot_pending
        RUNNING_PHASE=""
        schedule_reboot "Stage 2: install Proxmox VE after FDE verification"
        return 0
    fi
    set_phase fde_running
    RUNNING_PHASE=fde_running
    if run_quiet_step 'FDE: migrate /boot and prepare LUKS2' \
        run_external bash "$FDE_IMPLEMENTATION"; then
        :
    else
        local rc=$?
        record_error "$rc"
        return "$rc"
    fi
    fde_ready || die "FDE stage finished but live verification failed"
    fde_reboot_preflight
    set_phase fde_reboot_pending
    RUNNING_PHASE=""
    schedule_reboot "Stage 2: install Proxmox VE after FDE verification"
}

run_pve_stage() {
    [[ "$(state_get phase)" != complete ]] || {
        log "Pipeline is already complete; Stage 2 cannot move the state backwards."
        return 0
    }
    fde_ready || die "Complete Stage 1 (FDE) first"
    if [[ "$(state_get phase)" == "fde_reboot_pending" ]]; then
        if ! reboot_seen; then
            request_reboot 'FDE is complete; reboot is required before Proxmox VE installation.'
            return 0
        fi
        set_phase fde_done
        state_set pending_boot_id ""
    fi
    if [[ "$(state_get phase)" == "pve_reboot_pending" ]] && ! reboot_seen; then
        request_reboot 'The PVE kernel is installed; reboot is required before continuing.'
        return 0
    fi
    if [[ "$(state_get phase)" == "pve_reboot_pending" ]] && ! pve_kernel_running; then
        # A user may deliberately select the previous Debian kernel from the
        # boot menu for recovery.  Do not turn that safe fallback into an
        # endless reboot/retry loop; the next boot (or an explicit --resume)
        # can continue as soon as the PVE kernel is selected.
        log "The Debian kernel is running instead of PVE after reboot; pipeline paused. Select a *-pve kernel and run --resume again."
        return 0
    fi
    if [[ -e "$PVE_STAGE_FILE" ]] && ! pve_marker_valid; then
        quarantine_stale_pve_marker
    fi
    if pve_marker_valid && ! pve_kernel_running; then
        pve_reboot_preflight
        set_phase pve_reboot_pending
        RUNNING_PHASE=""
        schedule_reboot "Stage 2: switch to the installed PVE kernel"
        return 0
    fi
    if pve_ready; then
        log "Proxmox VE is installed and running on the PVE kernel; Stage 2 skipped."
        set_phase pve_done
        return 0
    fi

    assert_secure_boot_off_for_pve

    set_phase pve_running
    RUNNING_PHASE=pve_running
    if run_quiet_step 'Proxmox VE: install packages and PVE kernel' \
        run_external bash "$PVE_IMPLEMENTATION"; then
        :
    else
        local rc=$?
        record_error "$rc"
        return "$rc"
    fi
    if pve_ready; then
        set_phase pve_done
        RUNNING_PHASE=""
        return 0
    fi
    if pve_marker_valid; then
        pve_reboot_preflight
        set_phase pve_reboot_pending
        RUNNING_PHASE=""
        schedule_reboot "Stage 2: switch to the PVE kernel"
        return 0
    fi
    die "Proxmox stage finished without a ready PVE kernel or valid marker"
}

run_secure_boot_stage() {
    [[ "$(state_get phase)" != complete ]] || {
        log "Pipeline is already complete; Stage 3 will not run again from the menu."
        return 0
    }
    pve_ready || die "Complete Proxmox VE on the PVE kernel first"
    if [[ "$(state_get phase)" == "secure_boot_enrollment" ]] && ! db_is_enrolled; then
        # A previous run may have recorded the enrollment phase after a
        # partially failed helper.  Treat the phase as resumable only when
        # the complete local guard installation and public bundle exist.
        if sb_guard_ready &&
            [[ -s /boot/efi/EFI/SB/ENROLL/db.auth &&
                -s /boot/efi/EFI/SB/KeyTool.efi ]]; then
            clear_error
            log "Stage 3 is already prepared; complete enrollment of the custom db.crt in firmware."
            return 0
        fi
        log "Incomplete enrollment state found; restarting Stage 3 fail-closed."
        set_phase secure_boot_running
    fi
    if sb_guard_ready && db_is_enrolled && [[ "$(state_get phase)" == "secure_boot_done" ]]; then
        state_set pending_boot_id ""
        log "Secure Boot lifecycle is already active; Stage 3 skipped."
        return 0
    fi

    set_phase secure_boot_running
    RUNNING_PHASE=secure_boot_running
    if run_external secure_boot_stage; then
        :
    else
        local rc=$?
        record_error "$rc"
        return "$rc"
    fi
    if db_is_enrolled; then
        set_phase secure_boot_done
        state_set pending_boot_id ""
        clear_error
        RUNNING_PHASE=""
        log "Custom db is enrolled; Secure Boot workers are active."
        return 0
    fi

    set_phase secure_boot_enrollment
    clear_error
    RUNNING_PHASE=""
    install -D -m 0600 -o root -g root /dev/null "$SB_GUARD_ENROLLMENT_HOLD" ||
        die "Cannot create enrollment hold marker"
    # Firmware enrollment is an explicit reboot boundary.  Keep the phase
    # resumable, show the checklist once, and use the same y/n confirmation as
    # the FDE and Proxmox reboot boundaries.  If the operator answers n, the
    # saved phase remains authoritative and the next run only displays the
    # enrollment instructions until firmware reports db.crt as enrolled.
    schedule_reboot 'Reboot into UEFI, enroll PK/KEK/db, enable Secure Boot, boot Debian, then run bash ./run.sh again.'
}

run_release_stage() {
    pve_ready || die "A running PVE kernel and proxmox-ve are required before the production release"
    case "$(state_get phase)" in
        secure_boot_done|release_pending|release_running|complete) ;;
        *) die "Production release is allowed only after Secure Boot is complete" ;;
    esac
    sb_guard_ready || die "Complete Stage 3 (Secure Boot) first"
    db_is_enrolled || die "The production bundle requires db.crt enrollment"
    [[ -x /usr/local/sbin/sb-guard-svc ]] || die "sb-guard-svc was not found"

    set_phase release_running
    RUNNING_PHASE=release_running
    # Called indirectly through with_sb_guard_lock; ShellCheck cannot infer
    # this callback invocation.
    # shellcheck disable=SC2329
    release_transaction() {
        run_quiet_step 'Release: build signed GRUB and shim bundle' \
            bash "$SCRIPT_DIR/lib/sb_shim_build_custom.sh" --release || return $?
        run_quiet_step 'Release: atomically apply verified EFI bundle' \
            /usr/local/sbin/sb-guard-svc --apply-release --no-mmx || return $?
        run_quiet_step 'Release: final full verification' \
            /usr/local/sbin/sb-guard-svc --verify || return $?
    }
    if run_external with_sb_guard_lock release_transaction; then
        :
    else
        local rc=$?
        record_error "$rc"
        return "$rc"
    fi
    set_phase complete
    state_set pending_boot_id ""
    state_set completed_at "$(date -Is)"
    RUNNING_PHASE=""
    log "Strazh pipeline complete: run sb-guard verify for the final RESULT: OK."
}

advance_pipeline() {
    local phase marker_valid
    for ((pass = 1; pass <= 8; pass++)); do
        phase="$(state_get phase init)"
        case "$phase" in
            init|fde_pending)
                assert_secure_boot_off_before_fde
                if fde_ready; then
                    set_phase fde_done
                else
                    run_fde_stage || return $?
                    return 0
                fi
                ;;
            fde_running)
                if fde_ready; then
                    fde_reboot_preflight
                    set_phase fde_reboot_pending
                    RUNNING_PHASE=""
                    schedule_reboot "Stage 2: install Proxmox VE after FDE verification"
                    return 0
                fi
                run_fde_stage || return $?
                return 0
                ;;
            fde_reboot_pending)
                if ! reboot_seen; then
                    request_reboot 'FDE is complete; reboot is required before Proxmox VE installation.'
                    return 0
                fi
                if ! fde_ready; then
                    die "FDE live verification failed after reboot; diagnose the system and rerun Stage 1"
                fi
                set_phase fde_done
                state_set pending_boot_id ""
                ;;
            fde_done|pve_pending|pve_running)
                [[ "$phase" == fde_done ]] && state_set pending_boot_id ""
                run_pve_stage || return $?
                [[ "$(state_get phase)" == "pve_reboot_pending" ]] && return 0
                ;;
            pve_reboot_pending)
                if ! reboot_seen; then
                    request_reboot 'The PVE kernel is installed; reboot is required before Secure Boot setup.'
                    return 0
                fi
                if ! pve_kernel_running; then
                    log "The Debian kernel is running instead of PVE after reboot; resume is paused until a *-pve kernel is selected."
                    return 0
                fi
                run_pve_stage || return $?
                [[ "$(state_get phase)" != pve_reboot_pending ]] && state_set pending_boot_id ""
                [[ "$(state_get phase)" == "pve_reboot_pending" ]] && return 0
                ;;
            pve_done|secure_boot_pending|secure_boot_running)
                run_secure_boot_stage || return $?
                [[ "$(state_get phase)" == "secure_boot_enrollment" ]] && return 0
                ;;
            secure_boot_enrollment)
                if ! db_is_enrolled; then
                    # This phase is a deliberate firmware boundary.  Show the
                    # same checklist and y/n reboot confirmation even when a
                    # previous run stopped here before this prompt was added
                    # or the operator chose n earlier.
                    schedule_reboot 'Reboot into UEFI, enroll PK/KEK/db, enable Secure Boot, boot Debian, then run bash ./run.sh again.'
                    return 0
                fi
                run_secure_boot_stage || return $?
                ;;
            secure_boot_done|release_pending|release_running)
                run_release_stage
                return 0
                ;;
            complete)
                log "Pipeline is already complete. Verify with: /usr/local/sbin/sb-guard-svc --verify"
                return 0
                ;;
            *)
                die "Unknown pipeline phase: $phase"
                ;;
        esac
        marker_valid=0
        pve_marker_valid && marker_valid=1 || true
        if ((marker_valid == 1)) && [[ "$(state_get phase)" != pve_reboot_pending ]] && ! pve_kernel_running; then
            pve_reboot_preflight
            set_phase pve_reboot_pending
            schedule_reboot "Stage 2: switch to the PVE kernel"
            return 0
        fi
    done
    die "Pipeline state did not stabilize after 8 transitions"
}

status() {
    printf 'state=%s\n' "$STATE_FILE"
    printf 'phase=%s\n' "$(state_get phase unknown)"
    printf 'fde_ready=%s\n' "$(check_status fde_ready)"
    printf 'pve_ready=%s\n' "$(check_status pve_ready)"
    printf 'sb_guard_ready=%s\n' "$(check_status sb_guard_ready)"
    printf 'sb_artifacts_ready=%s\n' "$(check_status secure_boot_artifacts_ready)"
    printf 'db_enrolled=%s\n' "$(check_status db_is_enrolled)"
    printf 'secure_boot=%s\n' "$(firmware_secure_boot_state)"
    printf 'pending_boot_id=%s\n' "$(state_get pending_boot_id -)"
}

check_status() {
    if "$1"; then
        printf 'yes'
    else
        printf 'no'
    fi
}

draw_menu() {
    ui_heading 'Strazh — FDE + Proxmox VE + custom-only Secure Boot'
    pipeline_checklist
    echo
    ui_option 1 'Setup Full Disk Encryption' \
        'LUKS2/PBKDF2 · move /boot into the encrypted root filesystem'
    ui_option 2 'Install Proxmox VE' \
        'Install the PVE kernel and complete the Proxmox VE packages'
    ui_option 3 'Setup Secure Boot' \
        'Install sb-guard · prepare custom PK/KEK/db enrollment'
    ui_option 4 'Finalize Secure Boot' \
        'Build, verify and deploy the signed GRUB and shim'
    ui_option 5 'Installation Status' \
        'Show completed stages and the next required action'
    ui_option 6 'Continue Installation Automatically' \
        'Resume pending stages after reboot or interruption'
    echo
    ui_control x 'Exit'
    echo
}

usage() {
    printf 'Usage: %s [--menu|--resume|--status|--fde|--proxmox|--secure-boot|--secure-boot-install-only|--release|--debug|--non-interactive]\n' "$0"
    printf 'On a fresh state, no arguments open the menu; saved states resume automatically.\n'
    printf '%s\n' '--menu: always open the interactive menu.'
    printf '%s\n' '--fde: set up Debian FDE and move /boot into LUKS2.'
    printf '%s\n' '--proxmox: install Proxmox VE and switch to the PVE kernel.'
    printf '%s\n' '--secure-boot: install and activate the custom-only Secure Boot lifecycle.'
    printf '%s\n' '--secure-boot-install-only: install the lifecycle without keys or ESP activation.'
    printf '%s\n' '--release: build, sign, verify and apply the production EFI bundle.'
    printf '%s\n' '--resume/--non-interactive: continue all pending stages after reboot or interruption.'
    printf '%s\n' '--status: show pipeline state without changing the system.'
    printf '%s\n' '--debug: show complete child command output and keep audit logs.'
}

menu() {
    local choice
    [[ -t 0 && -t 1 ]] || die "The menu requires a TTY; use --resume or --status"
    while true; do
        ui_clear
        draw_menu
        read -r -p "${BLUE}?:${RESET} " choice || return 0
        printf '\n'
        # Remove the menu before showing stage progress. This keeps one
        # screen focused on one operation and prevents duplicate checklists.
        ui_clear
        case "$choice" in
            1) with_lock run_fde_stage ;;
            2)
                if fde_ready; then
                    with_lock run_pve_stage
                else
                    ui_step_fail 'Option 2 is unavailable: complete Debian FDE first (option 1).'
                    ui_pause
                fi
                ;;
            3)
                if pve_ready; then
                    with_lock run_secure_boot_stage
                else
                    ui_step_fail 'Option 3 is unavailable: install Proxmox VE first (option 2).'
                    ui_pause
                fi
                ;;
            4)
                if ! pve_ready; then
                    ui_step_fail 'Option 4 is unavailable: complete Proxmox VE first (option 2).'
                    ui_pause
                elif ! sb_guard_ready || ! db_is_enrolled; then
                    ui_step_fail 'Option 4 is unavailable: complete Secure Boot enrollment first (option 3).'
                    ui_pause
                else
                    with_lock run_release_stage
                fi
                ;;
            5)
                with_lock status
                ;;
            6)
                with_lock advance_pipeline
                ;;
            x|X) return 0 ;;
            *) log "Unknown menu option: $choice" ;;
        esac
        printf '\n'
    done
}

main() {
    local mode=menu stage=''
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --menu) mode=menu; MENU_REQUESTED=1 ;;
            --resume) mode=resume ;;
            --status) mode=status ;;
            --fde|--stage1) mode=stage; stage=fde ;;
            --proxmox|--stage2) mode=stage; stage=pve ;;
            --secure-boot|--stage3) mode=stage; stage=secure ;;
            --secure-boot-install-only)
                mode=stage
                stage=secure
                SECURE_BOOT_MODE=install-only
                ;;
            --release|--stage4) mode=stage; stage=release ;;
            --debug) DEBUG_MODE=1 ;;
            --non-interactive) NONINTERACTIVE=1 ;;
            -h|--help)
                usage
                return 0
                ;;
            *) die "Unknown argument: $1" ;;
        esac
        shift
    done
    require_root
    need_cmd awk
    need_cmd findmnt
    need_cmd dpkg-query
    need_cmd stat
    need_cmd flock

    # Status is read-only and must remain useful while a worker holds the
    # pipeline lock.  The state file is updated by atomic rename, so a direct
    # snapshot cannot observe a half-written record.
    if [[ "$mode" == status ]]; then
        status
        return 0
    fi

    # Install the embedded host administration command while the project is
    # present.  It is copied, not symlinked, so removing the clone later does
    # not remove the passphrase-management utility.
    install_host_cli

    # Start every interactive run with a clean screen.  The helper is a
    # no-op for redirected/non-interactive output, so logs remain intact.
    ui_clear

    # Remove only the obsolete installation-resume unit.  The permanent
    # sb-guard maintenance units are intentionally left untouched.
    remove_resume_unit
    acquire_lock
    state_init
    release_lock

    case "$mode" in
        status) with_lock status ;;
        resume) with_lock advance_pipeline ;;
        stage)
            case "$stage" in
                fde) with_lock run_fde_stage ;;
                pve) with_lock run_pve_stage ;;
                secure) with_lock run_secure_boot_stage ;;
                release) with_lock run_release_stage ;;
                *) die "Unknown stage: $stage" ;;
            esac
            ;;
        menu)
            if ((NONINTERACTIVE == 1)); then
                with_lock advance_pipeline
            elif ((MENU_REQUESTED == 0)) && [[ "$(state_get phase init)" != init ]]; then
                # A rerun after reboot or interruption is the normal path.  A
                # saved state is authoritative; continue it without making
                # the operator select option 6 again.  --menu remains the
                # explicit escape hatch for manual stage selection.
                if [[ "$(state_get phase init)" == complete ]]; then
                    with_lock status
                else
                    with_lock advance_pipeline
                fi
            else
                menu
            fi
            ;;
    esac
}

trap 'exit 130' INT TERM
trap 'rc=$?; if ((rc != 0)) && [[ -n "$RUNNING_PHASE" ]]; then record_error "$rc" || true; fi; exit "$rc"' EXIT
main "$@"
