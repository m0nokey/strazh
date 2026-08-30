#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 m0nokey
# Private implementation invoked by the public ../run.sh entry point.
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

# ==============================================================================
# Configuration
# ==============================================================================
STAGE_FILE="/var/lib/pve-install.stage"
PVE_KEYRING="/etc/apt/keyrings/proxmox-release-trixie.gpg"
PVE_SOURCES="/etc/apt/sources.list.d/pve-no-subscription.sources"
PVE_ENTERPRISE="/etc/apt/sources.list.d/pve-enterprise.sources"
PVE_REPO_URI="${PVE_REPO_URI:-http://download.proxmox.com/debian/pve}"
DEBIAN_SOURCES="/etc/apt/sources.list.d/debian.sources"
SB_GUARD_EVENT="/usr/local/sbin/sb-guard-event"
SB_GUARD_TRANSACTION=0
SB_GUARD_LOCK_FILE="/run/sb-guard.lock"
SB_GUARD_LOCK_HELD=0

# ==============================================================================
# Helpers
# ==============================================================================
log() {
    printf '%s\n' "$*" >&2
}

die() {
    log "ERROR: $*"
    exit 1
}

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

require_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        die "Run as root (sudo -i)."
    fi
}

require_debian_trixie() {
    local id version_codename
    id=""
    version_codename=""
    if [[ -r /etc/os-release ]]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        id="${ID:-}"
        version_codename="${VERSION_CODENAME:-}"
    fi
    if [[ "$id" != "debian" || "$version_codename" != "trixie" ]]; then
        die "Expected Debian 13 (trixie). Found: ID=${id:-?} CODENAME=${version_codename:-?}"
    fi
}

# ==============================================================================
# Package transaction guard
# ==============================================================================
sb_guard_transaction_begin() {
    if [[ -x "$SB_GUARD_EVENT" ]]; then
        exec 200>"$SB_GUARD_LOCK_FILE"
        flock -w 300 200 || die "Timed out waiting for sb-guard transaction lock"
        SB_GUARD_LOCK_HELD=1
        "$SB_GUARD_EVENT" --package-begin || true
        SB_GUARD_TRANSACTION=1
        log "sb-guard lock and package inhibitor held for the complete Proxmox package stage."
    fi
}

sb_guard_transaction_end() {
    if [[ "$SB_GUARD_TRANSACTION" -eq 1 ]]; then
        SB_GUARD_TRANSACTION=0
        "$SB_GUARD_EVENT" --package-end || true
        if [[ "$SB_GUARD_LOCK_HELD" -eq 1 ]]; then
            # The process exit closes the descriptor even if the unlock ioctl
            # is rejected; never hide the package-stage result behind cleanup.
            flock -u 200 >/dev/null 2>&1 || true
            SB_GUARD_LOCK_HELD=0
        fi
        log "Queued one sb-guard reconcile after the Proxmox package stage."
    fi
}

cleanup() {
    local rc=$?
    sb_guard_transaction_end
    return "$rc"
}

apt_run() {
    DEBIAN_FRONTEND=noninteractive \
    DEBIAN_PRIORITY=critical \
    APT_LISTCHANGES_FRONTEND=none \
    apt-get \
        -o DPkg::Post-Invoke::= \
        -o DPkg::Post-Invoke-Success::= \
        -o APT::Update::Post-Invoke::= \
        -o APT::Update::Post-Invoke-Success::= \
        "$@"
}

split_words() {
    local line old_ifs
    line="$1"
    old_ifs="$IFS"
    IFS=' '
    read -r -a words <<< "$line"
    IFS="$old_ifs"
}

word_after() {
    local needle i
    needle="$1"
    for ((i=0; i<${#words[@]}; i++)); do
        if [[ "${words[$i]}" == "$needle" ]]; then
            if (( i + 1 < ${#words[@]} )); then
                printf '%s' "${words[$((i+1))]}"
                return 0
            fi
        fi
    done
    return 1
}

default_dev4() {
    local line dev
    line="$(ip -o -4 route show default 2>/dev/null | head -n 1 || true)"
    [[ -n "$line" ]] || return 0
    split_words "$line"
    dev="$(word_after dev || true)"
    [[ -n "$dev" ]] && printf '%s' "$dev"
}

default_dev6() {
    local line dev
    line="$(ip -o -6 route show default 2>/dev/null | head -n 1 || true)"
    [[ -n "$line" ]] || return 0
    split_words "$line"
    dev="$(word_after dev || true)"
    [[ -n "$dev" ]] && printf '%s' "$dev"
}

ipv4_on_dev() {
    local dev line addr
    dev="$1"
    line="$(ip -o -4 addr show dev "$dev" scope global 2>/dev/null | head -n 1 || true)"
    [[ -n "$line" ]] || return 0
    split_words "$line"
    addr="${words[3]:-}"
    addr="${addr%%/*}"
    [[ -n "$addr" ]] && printf '%s' "$addr"
}

first_global_ipv4() {
    local line addr
    line="$(ip -o -4 addr show scope global 2>/dev/null | head -n 1 || true)"
    [[ -n "$line" ]] || return 0
    split_words "$line"
    addr="${words[3]:-}"
    addr="${addr%%/*}"
    [[ -n "$addr" ]] && printf '%s' "$addr"
}

ipv6_on_dev() {
    local dev line addr
    dev="$1"
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        if [[ "$line" != *" temporary "* && "$line" != *" deprecated "* ]]; then
            split_words "$line"
            addr="${words[3]:-}"
            addr="${addr%%/*}"
            if [[ -n "$addr" ]]; then
                printf '%s' "$addr"
                return 0
            fi
        fi
    done < <(ip -o -6 addr show dev "$dev" scope global 2>/dev/null || true)

    line="$(ip -o -6 addr show dev "$dev" scope global 2>/dev/null | head -n 1 || true)"
    [[ -n "$line" ]] || return 0
    split_words "$line"
    addr="${words[3]:-}"
    addr="${addr%%/*}"
    [[ -n "$addr" ]] && printf '%s' "$addr"
}

first_global_ipv6() {
    local line addr
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        if [[ "$line" != *" temporary "* && "$line" != *" deprecated "* ]]; then
            split_words "$line"
            addr="${words[3]:-}"
            addr="${addr%%/*}"
            if [[ -n "$addr" ]]; then
                printf '%s' "$addr"
                return 0
            fi
        fi
    done < <(ip -o -6 addr show scope global 2>/dev/null || true)

    line="$(ip -o -6 addr show scope global 2>/dev/null | head -n 1 || true)"
    [[ -n "$line" ]] || return 0
    split_words "$line"
    addr="${words[3]:-}"
    addr="${addr%%/*}"
    [[ -n "$addr" ]] && printf '%s' "$addr"
}

get_primary_ips() {
    local dev4 dev6 ip4 ip6
    dev4="$(default_dev4 || true)"
    dev6="$(default_dev6 || true)"

    ip4=""
    ip6=""

    if [[ -n "$dev4" ]]; then
        ip4="$(ipv4_on_dev "$dev4" || true)"
    fi
    if [[ -z "$ip4" ]]; then
        ip4="$(first_global_ipv4 || true)"
    fi

    if [[ -n "$dev6" ]]; then
        ip6="$(ipv6_on_dev "$dev6" || true)"
    fi
    if [[ -z "$ip6" ]]; then
        ip6="$(first_global_ipv6 || true)"
    fi

    if [[ "${ip4:-}" == 127.* ]]; then
        ip4=""
    fi
    if [[ "${ip6:-}" == "::1" || "${ip6:-}" == fe80:* ]]; then
        ip6=""
    fi

    printf '%s\n%s\n' "$ip4" "$ip6"
}

# ==============================================================================
# Host and network configuration
# ==============================================================================
wait_for_network_address() {
    local wait_sec="${STRAZH_NETWORK_WAIT_SEC:-120}" elapsed=0
    local -a addresses=()
    [[ "$wait_sec" =~ ^[0-9]+$ ]] || wait_sec=120

    # network-online.target can be reached before DHCP/SLAAC has installed a
    # usable address.  Give the resumed pipeline a bounded grace period rather
    # than failing eight state-machine passes or launching a restart storm.
    while ((elapsed < wait_sec)); do
        mapfile -t addresses < <(get_primary_ips)
        if [[ -n "${addresses[0]:-}" || -n "${addresses[1]:-}" ]]; then
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    return 1
}

ensure_hosts() {
    local fqdn short ip4 ip6 tmp line drop i
    local -a primary_ips=()
    fqdn="$(hostname -f 2>/dev/null || true)"
    short="$(hostname -s 2>/dev/null || hostname)"
    if [[ -z "$fqdn" || "$fqdn" == "(none)" ]]; then
        fqdn="$short"
    fi

    wait_for_network_address ||
        die "No non-loopback global IP found after ${STRAZH_NETWORK_WAIT_SEC:-120}s (IPv4/IPv6). Fix networking first."
    mapfile -t primary_ips < <(get_primary_ips)
    ip4="${primary_ips[0]:-}"
    ip6="${primary_ips[1]:-}"

    tmp="$(mktemp)"
    while IFS= read -r line; do
        if [[ -z "$line" || "$line" == \#* ]]; then
            printf '%s\n' "$line" >> "$tmp"
            continue
        fi
        drop="no"
        split_words "$line"
        for ((i=1; i<${#words[@]}; i++)); do
            if [[ "${words[$i]}" == "$fqdn" || "${words[$i]}" == "$short" ]]; then
                drop="yes"
                break
            fi
        done
        if [[ "$drop" == "no" ]]; then
            printf '%s\n' "$line" >> "$tmp"
        fi
    done < /etc/hosts

    if ! grep -qE '^[[:space:]]*127\.0\.0\.1[[:space:]]+localhost([[:space:]]|$)' "$tmp"; then
        printf '%s\n' "127.0.0.1 localhost" >> "$tmp"
    fi
    if ! grep -qE '^[[:space:]]*::1[[:space:]]+localhost([[:space:]]|$)' "$tmp"; then
        printf '%s\n' "::1 localhost ip6-localhost ip6-loopback" >> "$tmp"
    fi

    if [[ -n "$ip4" ]]; then
        printf '%s\n' "$ip4 $fqdn $short" >> "$tmp"
    fi
    if [[ -n "$ip6" ]]; then
        printf '%s\n' "$ip6 $fqdn $short" >> "$tmp"
    fi

    cat "$tmp" > /etc/hosts
    rm -f "$tmp"

    log "Updated /etc/hosts for hostname resolution."
}

disable_pve_enterprise_repo() {
    if [[ -f "$PVE_ENTERPRISE" ]]; then
        mv -f "$PVE_ENTERPRISE" "${PVE_ENTERPRISE}.disabled"
        log "Disabled Proxmox enterprise repository."
    fi
}

ensure_debian_sources_https() {
    log "Configuring Debian APT sources (deb822, HTTPS, main + non-free-firmware)..."
    rm -f /etc/apt/sources.list
    find /etc/apt/sources.list.d -maxdepth 1 -type f -name '*.list' -print0 | xargs -0r rm -f

    cat <<'EOF' | indent -4 | install -o root -g root -m 0644 /dev/stdin "$DEBIAN_SOURCES"
    Types: deb deb-src
    URIs: https://deb.debian.org/debian/
    Suites: trixie trixie-updates
    Components: main non-free-firmware
    Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

    Types: deb deb-src
    URIs: https://security.debian.org/debian-security/
    Suites: trixie-security
    Components: main non-free-firmware
    Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF

    log "Debian sources written to $DEBIAN_SOURCES"
}

# ==============================================================================
# Package prerequisites
# ==============================================================================
install_prereqs() {
    local saved_pve=""

    log "Installing prerequisites..."
    # A previous interrupted run may have left a PVE source with a stale
    # transport URL.  Keep that source out of the bootstrap update so a
    # failed endpoint cannot make APT silently reuse an old PVE index while
    # curl/CA tooling is being installed.  setup_pve_repo() writes the
    # canonical source again immediately afterwards.
    if [[ -f "$PVE_SOURCES" ]]; then
        saved_pve="${PVE_SOURCES}.bootstrap-disabled.$$"
        mv -f -- "$PVE_SOURCES" "$saved_pve"
    fi
    if ! apt_run update || ! apt_run install -y curl ca-certificates gnupg debconf-utils; then
        if [[ -n "$saved_pve" && -f "$saved_pve" ]]; then
            mv -f -- "$saved_pve" "$PVE_SOURCES"
        fi
        return 1
    fi
    [[ -z "$saved_pve" ]] || rm -f -- "$saved_pve"
}

# ==============================================================================
# Proxmox APT repository
# ==============================================================================
setup_pve_repo() {
    log "Configuring Proxmox APT repository (deb822)..."
    install -d -m 0755 /etc/apt/keyrings

    curl -fsSL --proto '=https' --tlsv1.3 \
        "https://enterprise.proxmox.com/debian/proxmox-release-trixie.gpg" \
        | gpg --batch --yes --dearmor \
        | install -o root -g root -m 0644 /dev/stdin "$PVE_KEYRING"

    # The official no-subscription endpoint currently serves a certificate for
    # enterprise.proxmox.com on its download hostname.  Keep transport HTTP
    # rather than weakening TLS hostname verification; APT still requires the
    # signed InRelease verified by the pinned Proxmox keyring.
    cat <<EOF | indent -4 | install -o root -g root -m 0644 /dev/stdin "$PVE_SOURCES"
    Types: deb
    URIs: $PVE_REPO_URI
    Suites: trixie
    Components: pve-no-subscription
    Architectures: amd64
    Signed-By: $PVE_KEYRING
EOF
}

# ==============================================================================
# Kernel cleanup and stage transitions
# ==============================================================================
boot_kver() {
    local base
    base="${1##*/}"
    base="${base%.sig}"
    case "$base" in
        vmlinuz-*) printf '%s' "${base#vmlinuz-}" ;;
        initrd.img-*) printf '%s' "${base#initrd.img-}" ;;
        System.map-*) printf '%s' "${base#System.map-}" ;;
        config-*) printf '%s' "${base#config-}" ;;
        *) printf '%s' "" ;;
    esac
}

cleanup_boot_non_pve() {
    local file kver removed
    removed=0

    shopt -s nullglob
    for file in /boot/vmlinuz-* /boot/initrd.img-* /boot/System.map-* /boot/config-*; do
        [[ -f "$file" ]] || continue
        kver="$(boot_kver "$file")"
        [[ -n "$kver" ]] || continue
        if [[ "$kver" != *-pve* ]]; then
            rm -f -- "$file"
            removed=$((removed + 1))
        fi
    done
    shopt -u nullglob

    log "Removed $removed non-PVE kernel files from /boot."
}

# ==============================================================================
# Two-pass Proxmox installation
# ==============================================================================
install_kernel_stage1() {
    log "Updating system..."
    apt_run update
    apt_run full-upgrade -y

    log "Installing Proxmox kernel..."
    apt_run install -y proxmox-default-kernel

    printf '%s\n' "stage2" | install -o root -g root -m 0600 /dev/stdin "$STAGE_FILE"

    log "Rebooting (kernel switch required)..."
    log "After reboot, continue with: bash ./run.sh --proxmox"
}

dpkg_package_needs_purge() {
    local package="$1" package_state
    package_state="$(dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null || true)"
    [[ "$package_state" == installed || "$package_state" == config-files ]]
}

purge_one_debian_package() {
    local package="$1"

    # dpkg-query can report a package left in the local status database even
    # when the matching repository entry has disappeared (for example an old
    # linux-image-* -unsigned variant). Never ask APT to purge such a name.
    dpkg_package_needs_purge "$package" || return 0
    apt_run purge -y "$package" || true
    # A package may be installed locally but absent from every configured APT
    # index, or APT may leave only config-files behind. dpkg can still remove
    # both states without downloading anything.
    if dpkg_package_needs_purge "$package"; then
        dpkg --purge -- "$package" || true
    fi
    dpkg_package_needs_purge "$package" && {
        log "ERROR: Debian kernel package remains after purge: $package"
        return 1
    }
    return 0
}

purge_debian_kernels() {
    local package package_state purge_failed=0

    purge_one_debian_package linux-image-amd64 || purge_failed=1

    # Use the package database status, not repository availability. This
    # avoids trying to purge stale names such as linux-image-...-unsigned that
    # are present only as obsolete metadata and are not installed.
    while IFS=$'\t' read -r package package_state; do
        [[ -n "$package" ]] || continue
        [[ "$package_state" == installed || "$package_state" == config-files ]] ||
            continue
        [[ "$package" == *pve* ]] && continue
        purge_one_debian_package "$package" || purge_failed=1
    done < <(
        dpkg-query -W -f='${binary:Package}\t${db:Status-Status}\n' \
            'linux-image-[0-9]*' 2>/dev/null || true
    )

    (( purge_failed == 0 )) ||
        die "Could not purge every installed Debian kernel; refusing to delete remaining /boot files"

    cleanup_boot_non_pve
    update-grub
}

install_pve_stage2() {
    log "Installing Proxmox VE packages..."
    apt_run update
    apt_run install -y proxmox-ve postfix open-iscsi chrony ifupdown2
    apt_run purge -y os-prober || true

    log "Removing Debian kernels..."
    purge_debian_kernels

    apt_run autoremove -y --purge

    # The Proxmox package may recreate its enterprise source during install.
    # Quarantine it after the transaction as well, so the following Secure
    # Boot stage cannot fail on an unauthenticated enterprise endpoint.
    disable_pve_enterprise_repo

    rm -f -- "$STAGE_FILE" || die "Could not remove completed Proxmox stage marker"

    log "Done."
    log "Web UI: https://$(hostname -f 2>/dev/null || hostname):8006/"
    log "Next pipeline stage: bash ./run.sh --secure-boot"
}

# ==============================================================================
# Main
# ==============================================================================
main() {
    require_root
    require_debian_trixie
    trap cleanup EXIT
    sb_guard_transaction_begin

    log "Starting Proxmox VE install on Debian 13 (trixie)..."
    ensure_hosts
    ensure_debian_sources_https
    disable_pve_enterprise_repo
    install_prereqs
    setup_pve_repo

    if [[ -f "$STAGE_FILE" ]] && [[ "$(cat "$STAGE_FILE" 2>/dev/null || true)" == "stage2" ]]; then
        install_pve_stage2
    else
        install_kernel_stage1
    fi
}

main "$@"
