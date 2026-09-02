#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 m0nokey
#
# Optional host-side platform-integrity guard.  It records the board identity
# separately from firmware identity, so a BIOS update can be handled explicitly
# without silently approving a motherboard change.
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

STATE_ROOT="${STRAZH_STATE_ROOT:-/var/lib/sb-guard}"
PLATFORM_ROOT="${STRAZH_PLATFORM_STATE_ROOT:-$STATE_ROOT/platform-guard}"
DMI_ROOT="${STRAZH_DMI_ROOT:-/sys/class/dmi/id}"
DMI_TABLE_ROOT="${STRAZH_DMI_TABLE_ROOT:-/sys/firmware/dmi/tables}"

MODE_FILE="$PLATFORM_ROOT/mode"
BASELINE_BOARD="$PLATFORM_ROOT/baseline.board"
BASELINE_FIRMWARE="$PLATFORM_ROOT/baseline.firmware"
CANDIDATE_BOARD="$PLATFORM_ROOT/candidate.board"
CANDIDATE_FIRMWARE="$PLATFORM_ROOT/candidate.firmware"
CANDIDATE_META="$PLATFORM_ROOT/candidate.meta"
MAINTENANCE_FILE="$PLATFORM_ROOT/maintenance"

FIRMWARE_IMAGE=""

log() { printf '[strazh-platform] %s\n' "$*" >&2; }
die() {
    log "ERROR: $*"
    exit 1
}
need() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

require_root() {
    [[ "$(id -u)" -eq 0 ]] && return 0
    # CI fixtures can use an explicitly redirected private state directory.
    [[ -n "${STRAZH_PLATFORM_STATE_ROOT:-}" ]] || die 'Run this command as root.'
}

ensure_root() {
    require_root
    if [[ "$(id -u)" -eq 0 ]]; then
        install -d -m 0700 -o root -g root "$PLATFORM_ROOT"
    else
        install -d -m 0700 "$PLATFORM_ROOT"
    fi
}

safe_value() {
    local name="$1" path value
    path="$DMI_ROOT/$name"
    [[ -f "$path" && ! -L "$path" && -r "$path" ]] || {
        printf 'unavailable'
        return 0
    }
    value="$(LC_ALL=C tr -d '\r' <"$path" | tr '\n' ' ')"
    value="$(printf '%s' "$value" | LC_ALL=C tr -cd '[:print:]\t ' |
        sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//' | LC_ALL=C tr '[:upper:]' '[:lower:]')"
    [[ -n "$value" ]] && printf '%s' "$value" || printf 'unavailable'
}

file_hash() {
    local path="$1"
    [[ -f "$path" && ! -L "$path" && -r "$path" ]] || {
        printf 'unavailable'
        return 0
    }
    sha256sum "$path" | awk '{print $1}'
}

firmware_image_hash() {
    [[ -n "$FIRMWARE_IMAGE" ]] || {
        printf 'unavailable'
        return 0
    }
    [[ -f "$FIRMWARE_IMAGE" && ! -L "$FIRMWARE_IMAGE" && -r "$FIRMWARE_IMAGE" ]] ||
        die "Firmware image is not a readable regular file: $FIRMWARE_IMAGE"
    file_hash "$FIRMWARE_IMAGE"
}

prompt_firmware_image() {
    [[ -n "$FIRMWARE_IMAGE" ]] || {
        [[ -t 0 && -t 1 ]] || return 0
        printf 'Firmware image path (optional; press Enter to skip): ' >/dev/tty
        IFS= read -r FIRMWARE_IMAGE </dev/tty || die 'Could not read firmware image path.'
        [[ -n "$FIRMWARE_IMAGE" ]] || return 0
    }
    [[ -f "$FIRMWARE_IMAGE" && ! -L "$FIRMWARE_IMAGE" && -r "$FIRMWARE_IMAGE" ]] ||
        die "Firmware image is not a readable regular file: $FIRMWARE_IMAGE"
}

has_platform_id() {
    [[ "$(safe_value product_uuid)" != unavailable ||
        "$(safe_value product_serial)" != unavailable ||
        "$(safe_value board_serial)" != unavailable ]]
}

write_payload() {
    local kind="$1" output="$2"
    has_platform_id || die "No usable board identifier is exposed under $DMI_ROOT"
    {
        printf 'schema=strazh-platform-v1\n'
        printf 'kind=%s\n' "$kind"
        printf 'board.product_uuid=%s\n' "$(safe_value product_uuid)"
        printf 'board.product_serial=%s\n' "$(safe_value product_serial)"
        printf 'board.vendor=%s\n' "$(safe_value board_vendor)"
        printf 'board.name=%s\n' "$(safe_value board_name)"
        printf 'board.version=%s\n' "$(safe_value board_version)"
        printf 'board.serial=%s\n' "$(safe_value board_serial)"
        printf 'chassis.serial=%s\n' "$(safe_value chassis_serial)"
        if [[ "$kind" == firmware ]]; then
            printf 'bios.vendor=%s\n' "$(safe_value bios_vendor)"
            printf 'bios.version=%s\n' "$(safe_value bios_version)"
            printf 'bios.revision=%s\n' "$(safe_value bios_revision)"
            printf 'bios.date=%s\n' "$(safe_value bios_date)"
            # These hashes cover firmware-exposed DMI bytes, not the SPI flash
            # itself.  A vendor firmware image can be supplied explicitly and
            # is hashed below; Strazh never reads flash through /dev/mem.
            printf 'firmware.dmi_table_sha256=%s\n' "$(file_hash "$DMI_TABLE_ROOT/DMI")"
            printf 'firmware.smbios_entry_sha256=%s\n' "$(file_hash "$DMI_TABLE_ROOT/smbios_entry_point")"
            printf 'firmware.image_sha256=%s\n' "$(firmware_image_hash)"
        fi
    } >"$output"
}

payload_digest() { sha256sum "$1" | awk '{print $1}'; }

payload_identity_digest() {
    # A supplied vendor image is evidence captured at update time, not a file
    # that must remain on the running host.  Keep it in the payload for audit,
    # but exclude that optional line from the live identity comparison.
    sed '/^firmware\.image_sha256=/d' "$1" | sha256sum | awk '{print $1}'
}

write_candidate() {
    local board_tmp firmware_tmp meta_tmp
    board_tmp="$(mktemp "$CANDIDATE_BOARD.XXXXXX")"
    firmware_tmp="$(mktemp "$CANDIDATE_FIRMWARE.XXXXXX")"
    meta_tmp="$(mktemp "$CANDIDATE_META.XXXXXX")"
    trap 'rm -f -- "${board_tmp:-}" "${firmware_tmp:-}" "${meta_tmp:-}"' RETURN
    write_payload board "$board_tmp"
    write_payload firmware "$firmware_tmp"
    {
        printf 'captured_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'board_sha256=%s\n' "$(payload_digest "$board_tmp")"
        printf 'firmware_sha256=%s\n' "$(payload_digest "$firmware_tmp")"
        printf 'firmware_image=%s\n' "${FIRMWARE_IMAGE:-not-supplied}"
    } >"$meta_tmp"
    chmod 0600 "$board_tmp" "$firmware_tmp" "$meta_tmp"
    mv -f -- "$board_tmp" "$CANDIDATE_BOARD"
    mv -f -- "$firmware_tmp" "$CANDIDATE_FIRMWARE"
    mv -f -- "$meta_tmp" "$CANDIDATE_META"
    trap - RETURN
}

read_mode() {
    [[ -s "$MODE_FILE" ]] || {
        printf 'disabled'
        return 0
    }
    case "$(cat "$MODE_FILE")" in
        enabled|disabled|maintenance) cat "$MODE_FILE" ;;
        *) die "Invalid platform guard mode in $MODE_FILE" ;;
    esac
}

write_mode() {
    local mode="$1" tmp
    [[ "$mode" == enabled || "$mode" == disabled || "$mode" == maintenance ]] ||
        die "Invalid platform guard mode: $mode"
    tmp="$(mktemp "$MODE_FILE.XXXXXX")"
    printf '%s\n' "$mode" >"$tmp"
    chmod 0600 "$tmp"
    mv -f -- "$tmp" "$MODE_FILE"
}

confirm() {
    local prompt="$1" answer
    [[ -t 0 && -t 1 ]] || die 'This operation requires an interactive TTY.'
    printf '%s [y/n] ' "$prompt" >/dev/tty
    IFS= read -r answer </dev/tty || die 'Could not read confirmation.'
    case "$answer" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

capture_initial() {
    [[ "$(read_mode)" != maintenance ]] || die 'Finish the BIOS update window first.'
    prompt_firmware_image
    write_candidate
    log "Candidate captured; no active policy was changed."
}

enable_guard() {
    local mode
    mode="$(read_mode)"
    [[ "$mode" != maintenance ]] || die 'Guard is in a BIOS-update window; use capture-after-update and finalize.'
    if [[ ! -s "$BASELINE_BOARD" || ! -s "$BASELINE_FIRMWARE" ]]; then
        capture_initial
        confirm 'Enable the optional platform-integrity guard with this baseline?' ||
            die 'Enable cancelled; candidate remains inactive.'
        mv -f -- "$CANDIDATE_BOARD" "$BASELINE_BOARD"
        mv -f -- "$CANDIDATE_FIRMWARE" "$BASELINE_FIRMWARE"
        rm -f -- "$CANDIDATE_META"
    else
        confirm 'Enable the optional platform-integrity guard with the existing baseline?' ||
            die 'Enable cancelled.'
    fi
    chmod 0600 "$BASELINE_BOARD" "$BASELINE_FIRMWARE"
    write_mode enabled
    log 'Platform-integrity guard enabled.'
}

disable_for_update() {
    [[ "$(read_mode)" == enabled ]] || die 'Platform guard is not enabled.'
    [[ -s "$BASELINE_BOARD" && -s "$BASELINE_FIRMWARE" ]] || die 'Active baseline is missing.'
    confirm 'Open a maintenance window for a BIOS or firmware update?' || {
        log 'Maintenance window not opened.'
        return 0
    }
    {
        printf 'started_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'expires_at=%s\n' "$(date -u -d '+24 hours' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf unknown)"
    } >"$MAINTENANCE_FILE"
    chmod 0600 "$MAINTENANCE_FILE"
    write_mode maintenance
    log 'Platform guard disabled for one explicit BIOS/firmware update window.'
}

capture_after_update() {
    [[ "$(read_mode)" == maintenance ]] || die 'Open the BIOS-update maintenance window first.'
    prompt_firmware_image
    write_candidate
    log 'Post-update candidate captured; run finalize-update after review.'
}

finalize_update() {
    local old_board new_board old_firmware new_firmware
    [[ "$(read_mode)" == maintenance ]] || die 'Platform guard is not in maintenance mode.'
    [[ -s "$BASELINE_BOARD" && -s "$BASELINE_FIRMWARE" ]] || die 'Active baseline is missing.'
    [[ -s "$CANDIDATE_BOARD" && -s "$CANDIDATE_FIRMWARE" ]] ||
        die 'No post-update candidate found. Run capture-after-update first.'
    old_board="$(payload_digest "$BASELINE_BOARD")"
    new_board="$(payload_digest "$CANDIDATE_BOARD")"
    old_firmware="$(payload_digest "$BASELINE_FIRMWARE")"
    new_firmware="$(payload_digest "$CANDIDATE_FIRMWARE")"
    [[ "$old_board" == "$new_board" ]] ||
        die 'Board identity changed; refusing automatic approval. Inspect the hardware and create a new policy explicitly.'
    log "Board digest unchanged: $new_board"
    log "Firmware digest transition: $old_firmware -> $new_firmware"
    confirm 'Accept the post-update firmware candidate and re-enable the guard?' ||
        die 'Finalize cancelled; maintenance mode remains active.'
    mv -f -- "$CANDIDATE_BOARD" "$BASELINE_BOARD"
    mv -f -- "$CANDIDATE_FIRMWARE" "$BASELINE_FIRMWARE"
    rm -f -- "$CANDIDATE_META" "$MAINTENANCE_FILE"
    chmod 0600 "$BASELINE_BOARD" "$BASELINE_FIRMWARE"
    write_mode enabled
    log 'Post-update baseline accepted; platform-integrity guard re-enabled.'
}

verify_guard() {
    local mode current_board current_firmware expected_board
    local current_firmware_identity expected_firmware_identity baseline_image current_image rc=0
    mode="$(read_mode)"
    case "$mode" in
        disabled)
            log 'Platform-integrity guard is disabled.'
            return 2
            ;;
        maintenance)
            log 'Platform-integrity guard is paused for an explicit BIOS/firmware update.'
            return 2
            ;;
    esac
    [[ -s "$BASELINE_BOARD" && -s "$BASELINE_FIRMWARE" ]] || die 'Enabled guard has no baseline.'
    current_board="$(mktemp "$PLATFORM_ROOT/.current.board.XXXXXX")"
    current_firmware="$(mktemp "$PLATFORM_ROOT/.current.firmware.XXXXXX")"
    trap 'rm -f -- "${current_board:-}" "${current_firmware:-}"' RETURN
    write_payload board "$current_board"
    write_payload firmware "$current_firmware"
    expected_board="$(payload_digest "$BASELINE_BOARD")"
    expected_firmware_identity="$(payload_identity_digest "$BASELINE_FIRMWARE")"
    [[ "$(payload_digest "$current_board")" == "$expected_board" ]] || {
        log "FAIL: board identity mismatch (expected=$expected_board current=$(payload_digest "$current_board"))"
        rc=1
    }
    current_firmware_identity="$(payload_identity_digest "$current_firmware")"
    [[ "$current_firmware_identity" == "$expected_firmware_identity" ]] || {
        log "FAIL: firmware identity mismatch (expected=$expected_firmware_identity current=$current_firmware_identity)"
        rc=1
    }
    baseline_image="$(awk -F= '$1 == "firmware.image_sha256" { print $2; exit }' "$BASELINE_FIRMWARE")"
    current_image="$(awk -F= '$1 == "firmware.image_sha256" { print $2; exit }' "$current_firmware")"
    if [[ -n "$baseline_image" && "$baseline_image" != unavailable ]]; then
        if [[ -n "$current_image" && "$current_image" != unavailable ]]; then
            [[ "$current_image" == "$baseline_image" ]] || {
                log "FAIL: supplied firmware image digest mismatch (expected=$baseline_image current=$current_image)"
                rc=1
            }
        else
            log 'WARN: baseline includes a firmware image digest; no image was supplied for this live check'
        fi
    fi
    ((rc == 0)) && log "OK: board and firmware identity match (board=$expected_board firmware=$expected_firmware_identity)"
    trap - RETURN
    return "$rc"
}

status_guard() {
    local mode board_current firmware_current
    mode="$(read_mode)"
    printf 'mode=%s\n' "$mode"
    [[ -s "$BASELINE_BOARD" ]] && printf 'board_baseline=%s\n' "$(payload_digest "$BASELINE_BOARD")" || printf 'board_baseline=not-captured\n'
    [[ -s "$BASELINE_FIRMWARE" ]] && printf 'firmware_baseline=%s\n' "$(payload_identity_digest "$BASELINE_FIRMWARE")" || printf 'firmware_baseline=not-captured\n'
    if has_platform_id; then
        board_current="$(mktemp "$PLATFORM_ROOT/.status.board.XXXXXX")"
        firmware_current="$(mktemp "$PLATFORM_ROOT/.status.firmware.XXXXXX")"
        trap 'rm -f -- "${board_current:-}" "${firmware_current:-}"' RETURN
        write_payload board "$board_current"
        write_payload firmware "$firmware_current"
        printf 'board_current=%s\n' "$(payload_digest "$board_current")"
        printf 'firmware_current=%s\n' "$(payload_identity_digest "$firmware_current")"
        trap - RETURN
    else
        printf 'board_current=unavailable\nfirmware_current=unavailable\n'
    fi
    [[ -s "$MAINTENANCE_FILE" ]] && printf 'maintenance_file=present\n' || printf 'maintenance_file=none\n'
}

usage() {
    cat <<'USAGE'
Usage: strazh-platform-guard <status|enable|capture|verify|disable-for-update|capture-after-update|finalize-update>

Optional host-side board/BIOS integrity monitor. A firmware image may be
hashed explicitly with --firmware-image PATH; Strazh never reads SPI flash.
USAGE
}

main() {
    local command="${1:-status}"
    shift || true
    while (( $# > 0 )); do
        case "$1" in
            --firmware-image)
                [[ $# -ge 2 ]] || die '--firmware-image requires a path'
                FIRMWARE_IMAGE="$2"
                shift 2
                ;;
            -h|--help)
                usage
                return 0
                ;;
            *) die "Unknown argument: $1" ;;
        esac
    done
    need awk
    need cat
    need date
    need install
    need mktemp
    need mv
    need rm
    need sha256sum
    need sed
    need tr
    ensure_root
    case "$command" in
        status) status_guard ;;
        enable) enable_guard ;;
        capture) capture_initial ;;
        verify) verify_guard ;;
        disable-for-update) disable_for_update ;;
        capture-after-update) capture_after_update ;;
        finalize-update) finalize_update ;;
        *) die "Unknown command: $command" ;;
    esac
}

trap 'exit 130' INT TERM
main "$@"
