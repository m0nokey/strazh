#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 m0nokey
# Private implementation invoked by the public ../run.sh entry point.
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

# ====== CONFIG ======
PBKDF2_ITER_TIME_MS="${PBKDF2_ITER_TIME_MS:-5000}"
ENABLE_ONE_PROMPT="${ENABLE_ONE_PROMPT:-1}"
KEYFILE_PATH="${KEYFILE_PATH:-/etc/cryptsetup-keys.d/root.key}"
KEEP_OLD_BOOT_DIR="${KEEP_OLD_BOOT_DIR:-1}"

# destructive ops
WIPE_DELETE_OLD_BOOT="${WIPE_DELETE_OLD_BOOT:-1}"   # remove stale plaintext /boot after verified migration
MERGE_ESP="${MERGE_ESP:-0}"                         # expand/recreate ESP to fill freed gap
TRACE="${TRACE:-0}"                                 # TRACE=1 -> set -x
SB_GUARD_EVENT="${SB_GUARD_EVENT:-/usr/local/sbin/sb-guard-event}"
SB_GUARD_LOCK_HELD="${SB_GUARD_LOCK_HELD:-0}"
BOOT_DEVICE_STATE="${BOOT_DEVICE_STATE:-/var/lib/strazh/fde-boot-device}"

# Helpers
# ====== LOGGING ======
log() {
    printf '[%s] %s\n' "$(date +'%F %T')" "$*" >&2
}

die() {
    printf '[%s] ERROR: %s\n' "$(date +'%F %T')" "$*" >&2
    exit 1
}

need_root() {
    [[ "$(id -u)" -eq 0 ]] || die "Run as root."
}

fix_path() {
    export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    hash -r || true
    if ! grep -q 'export PATH=/usr/local/sbin' /root/.profile 2>/dev/null; then
        printf '\nexport PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n' >> /root/.profile
    fi
}

trim() {
    local s="${1-}"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

backup_file() {
    local f="$1"
    local ts
    if [[ -f "$f" ]]; then
        ts="$(date +%Y%m%d-%H%M%S)"
        cp -a "$f" "${f}.bak.${ts}"
        log "Backup: $f -> ${f}.bak.${ts}"
    fi
}

have_cmd() {
    command -v "$1" >/dev/null 2>&1
}

acquire_sb_guard_lock() {
    # FDE migration rewrites /boot and can recreate the ESP.  If sb-guard is
    # already installed, serialize that destructive work with its worker so a
    # path/timer event cannot deploy into a half-migrated tree.
    [[ -x "$SB_GUARD_EVENT" ]] || return 0
    have_cmd flock || die "flock is required before an existing sb-guard installation can be migrated"
    if [[ "$SB_GUARD_LOCK_HELD" != 1 ]]; then
        exec 200>/run/sb-guard.lock
        flock -w 300 200 || die "Timed out waiting for sb-guard lock"
        SB_GUARD_LOCK_HELD=1
        trap 'flock -u 200 >/dev/null 2>&1 || true' EXIT
    fi
}

have_glob() {
    compgen -G "$1" >/dev/null 2>&1
}

apt_install() {
    export DEBIAN_FRONTEND=noninteractive
    log "Installing required packages (if missing)…"
    apt-get update -y >/dev/null
    apt-get install -y \
        cryptsetup initramfs-tools \
        grub-efi-amd64 grub-efi-amd64-bin grub2-common grub-common \
        efibootmgr \
        rsync util-linux gawk grep sed coreutils mount \
        gdisk dosfstools parted >/dev/null
}

# ====== DEVICE HELPERS ======
disk_of_part() {
    local part="$1" pk
    pk="$(lsblk -nro PKNAME "$part" 2>/dev/null | head -n1 || true)"
    pk="$(trim "$pk")"
    [[ -n "$pk" ]] || die "Cannot detect disk for $part"
    echo "/dev/$pk"
}

partnum_of_part() {
    local part="$1" bn n sysf
    bn="$(basename "$part")"
    sysf="/sys/class/block/$bn/partition"
    if [[ -r "$sysf" ]]; then
        n="$(cat "$sysf" 2>/dev/null || true)"
        n="$(trim "$n")"
        [[ -n "$n" ]] && {
            echo "$n"
            return 0
        }
    fi
    n="$(lsblk -nro PARTNUM "$part" 2>/dev/null | head -n1 || true)"
    n="$(trim "$n")"
    [[ -n "$n" ]] || die "Cannot detect PARTNUM for $part"
    echo "$n"
}

reread_pt() {
    local disk="$1" rc=0
    if have_cmd partprobe; then
        partprobe "$disk" >/dev/null 2>&1 || rc=$?
    elif have_cmd blockdev; then
        blockdev --rereadpt "$disk" >/dev/null 2>&1 || rc=$?
    elif have_cmd partx; then
        partx -u "$disk" >/dev/null 2>&1 || rc=$?
    else
        die "No partition-table reread utility is available"
    fi
    udevadm settle >/dev/null 2>&1 || rc=$?
    (( rc == 0 )) || die "Kernel did not accept the updated partition table on $disk"
}

resolve_fstab_spec_to_dev() {
    local spec="$1"
    spec="$(trim "$spec")"
    [[ -n "$spec" ]] || return 1
    if [[ "$spec" =~ ^/dev/ ]]; then
        echo "$spec"
        return 0
    fi
    if [[ "$spec" =~ ^UUID= ]]; then
        blkid -U "${spec#UUID=}" 2>/dev/null || true
        return 0
    fi
    if [[ "$spec" =~ ^PARTUUID= ]]; then
        blkid -t "PARTUUID=${spec#PARTUUID=}" -o device 2>/dev/null || true
        return 0
    fi
    return 1
}

detect_boot_dev() {
    findmnt -nro SOURCE /boot 2>/dev/null || true
}

detect_boot_dev_from_fstab_any() {
    local spec
    spec="$(
        awk '
            $0 ~ /^[[:space:]]*#/ {line=$0; sub(/^[[:space:]]*#[[:space:]]*/, "", line)}
            $0 !~ /^[[:space:]]*#/ {line=$0}
            line ~ /[[:space:]]\/boot[[:space:]]/ && line !~ /\/boot\/efi/ {
                split(line, a, /[[:space:]]+/); print a[1]; exit
            }' /etc/fstab 2>/dev/null || true
    )"
    spec="$(trim "$spec")"
    [[ -n "$spec" ]] || return 1
    resolve_fstab_spec_to_dev "$spec" | head -n1
}

# robust ESP detection: by mount, by PARTTYPE, by vfat+EFI dir probe
detect_esp_dev() {
    local dev

    dev="$(findmnt -nro SOURCE /boot/efi 2>/dev/null || true)"
    dev="$(trim "$dev")"
    if [[ -n "$dev" && -b "$dev" ]]; then
        echo "$dev"
        return 0
    fi

    dev="$(
        lsblk -nrpo NAME,PARTTYPE,TYPE | awk '
            $3=="part" && tolower($2)=="c12a7328-f81f-11d2-ba4b-00a0c93ec93b" {print $1; exit}'
    )"
    dev="$(trim "$dev")"
    if [[ -n "$dev" && -b "$dev" ]]; then
        echo "$dev"
        return 0
    fi

    while read -r dev; do
        [[ -b "$dev" ]] || continue
        local fstype
        fstype="$(blkid -s TYPE -o value "$dev" 2>/dev/null || true)"
        fstype="$(trim "$fstype")"
        [[ "$fstype" == "vfat" ]] || continue

        local mnt="/run/esp-probe.$$.$RANDOM"
        mkdir -p "$mnt"
        if mount -t vfat -o ro,umask=0077 "$dev" "$mnt" >/dev/null 2>&1; then
            if [[ -d "$mnt/EFI" ]]; then
                umount "$mnt" >/dev/null 2>&1 || true
                rmdir "$mnt" >/dev/null 2>&1 || true
                echo "$dev"
                return 0
            fi
            umount "$mnt" >/dev/null 2>&1 || true
        fi
        rmdir "$mnt" >/dev/null 2>&1 || true
    done < <(lsblk -nrpo NAME,TYPE | awk '$2=="part"{print $1}')

    return 1
}

detect_root_src() {
    findmnt -nro SOURCE / 2>/dev/null || true
}

detect_root_crypt_mapper() {
    local root_src
    root_src="$(trim "$(detect_root_src)")"
    [[ -n "$root_src" ]] || return 1
    lsblk -r -n -s -p -o NAME,TYPE "$root_src" | awk '$2=="crypt"{print $1; exit}'
}

detect_root_luks_dev() {
    local crypt_mapper crypt_name dev
    crypt_mapper="$(trim "$(detect_root_crypt_mapper)")"
    [[ -n "$crypt_mapper" ]] || return 1

    crypt_name="$(basename "$crypt_mapper")"
    dev="$(cryptsetup status "$crypt_name" 2>/dev/null | awk -F': *' '/device:/{print $2; exit}' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    dev="$(trim "$dev")"
    [[ -n "$dev" && -b "$dev" ]] || return 1
    cryptsetup isLuks "$dev" >/dev/null 2>&1 || return 1
    echo "$dev"
}

# ====== ESP MOUNT/VERIFY ======
ensure_esp_mounted() {
    local esp_dev="$1"
    mkdir -p /boot/efi
    if ! findmnt -n /boot/efi >/dev/null 2>&1; then
        log "Mounting ESP $esp_dev -> /boot/efi"
        mount -t vfat "$esp_dev" /boot/efi
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    local fstype
    fstype="$(trim "$(findmnt -nro FSTYPE /boot/efi 2>/dev/null || true)")"
    [[ "$fstype" == "vfat" ]] || die "/boot/efi mounted but not vfat (got: ${fstype:-empty})"
    [[ -d /boot/efi/EFI ]] || die "ESP mounted but /boot/efi/EFI missing"
}

update_fstab_esp_uuid() {
    local esp_dev="$1" uuid opts newline

    uuid="$(trim "$(blkid -s UUID -o value "$esp_dev" 2>/dev/null || true)")"
    [[ -n "$uuid" ]] || die "Cannot read UUID for $esp_dev"

    opts="ro,nodev,nosuid,noexec,fmask=0177,dmask=0077,noatime,errors=remount-ro"
    newline="UUID=${uuid}  /boot/efi  vfat  ${opts}  0  1"

    backup_file /etc/fstab

    sed -i -E '\@^[[:space:]]*#?[[:space:]]*[^[:space:]]+[[:space:]]+/boot/efi([[:space:]]+|$)@d' /etc/fstab
    printf '%s\n' "$newline" >> /etc/fstab

    systemctl daemon-reload >/dev/null 2>&1 || true
}

# ====== GRUB/CRYPTSETUP ======
ensure_grub_cryptodisk() {
    backup_file /etc/default/grub
    if grep -q '^GRUB_ENABLE_CRYPTODISK=' /etc/default/grub 2>/dev/null; then
        sed -i -E 's/^GRUB_ENABLE_CRYPTODISK=.*/GRUB_ENABLE_CRYPTODISK=y/' /etc/default/grub
    else
        echo 'GRUB_ENABLE_CRYPTODISK=y' >> /etc/default/grub
    fi
}

prompt_luks_pass_once() {
    local prompt="${1:-Enter existing LUKS passphrase: }"
    local was_xtrace=0
    if [[ "${-}" == *x* ]]; then
        was_xtrace=1
        set +x
    fi

    if [[ -w /dev/tty ]]; then
        printf '%s' "$prompt" >/dev/tty
    else
        printf '%s' "$prompt" >&2
    fi
    if [[ -r /dev/tty ]]; then
        IFS= read -r -s luks_pass </dev/tty
    else
        IFS= read -r -s luks_pass
    fi
    if [[ -w /dev/tty ]]; then
        printf '\n' >/dev/tty
    else
        printf '\n' >&2
    fi
    [[ -n "${luks_pass:-}" ]] || die "Empty passphrase."

    if (( was_xtrace )); then
        set -x
    fi
}

ensure_pbkdf2_slot_for_grub_once() {
    local luks_dev="$1" ver
    ver="$(cryptsetup luksDump "$luks_dev" 2>/dev/null | awk -F: '/^Version:/{print $2; exit}' | sed -E 's/^[[:space:]]+//; s/[^0-9].*$//')"
    ver="$(trim "$ver")"
    [[ -n "$ver" ]] || die "cryptsetup luksDump failed on $luks_dev"

    if [[ "$ver" != "2" ]]; then
        log "LUKS version $ver; PBKDF2 implied."
        return 0
    fi

    if cryptsetup luksDump "$luks_dev" | grep -qE 'PBKDF:[[:space:]]*pbkdf2'; then
        log "PBKDF2 already present on root LUKS2."
        return 0
    fi

    cryptsetup luksConvertKey --help >/dev/null 2>&1 || die "cryptsetup luksConvertKey not available"
    log "Converting/adding PBKDF2 for GRUB (iter-time=${PBKDF2_ITER_TIME_MS}ms)…"

    local was_xtrace=0
    if [[ "${-}" == *x* ]]; then
        was_xtrace=1
        set +x
    fi

    printf '%s' "$luks_pass" | cryptsetup -q luksConvertKey "$luks_dev" --pbkdf pbkdf2 --iter-time "$PBKDF2_ITER_TIME_MS" -d -

    if (( was_xtrace )); then
        set -x
    fi

    cryptsetup luksDump "$luks_dev" | grep -qE 'PBKDF:[[:space:]]*pbkdf2' || die "PBKDF2 conversion failed (no pbkdf2 found afterwards)."
}

move_boot_into_root() (
    local boot_dev="$1" esp_dev="" esp_detached=0 rc stage_stale

    # On Debian's usual GPT layout the ESP is mounted below /boot.  A parent
    # mount cannot be detached while that child exists.  Keep the ESP
    # temporarily detached only for the move and always restore it, including
    # when rsync, umount or a rename fails halfway through.
    restore_esp_mount() {
        rc="$1"
        if (( esp_detached == 1 )) && ! findmnt -n /boot/efi >/dev/null 2>&1; then
            mkdir -p /boot/efi
            mount -t vfat "$esp_dev" /boot/efi >/dev/null 2>&1 ||
                log "ERROR: could not restore ESP mount after /boot migration"
        fi
        exit "$rc"
    }
    # Called indirectly by EXIT; ShellCheck cannot infer trap callback usage.
    # shellcheck disable=SC2329
    trap 'restore_esp_mount "$?"' EXIT

    if ! findmnt -n /boot >/dev/null 2>&1; then
        log "/boot is already not a mountpoint. Skipping move."
        return 0
    fi

    [[ -n "$boot_dev" ]] || die "Expected separate /boot mount, but cannot detect its source."

    log "Copying /boot ($boot_dev) -> /boot.inroot…"
    if [[ -e /boot.inroot ]]; then
        [[ -d /boot.inroot ]] || die "Refusing to reuse non-directory /boot.inroot"
        if [[ -n "$(find /boot.inroot -mindepth 1 -print -quit 2>/dev/null)" ]]; then
            # A failed rsync/unmount can leave the private staging directory
            # behind.  Preserve that exact failed attempt for diagnosis, then
            # start a clean copy; never delete an operator-created directory.
            stage_stale="/boot.inroot.stale.$(date +%Y%m%d-%H%M%S).$$"
            mv -- /boot.inroot "$stage_stale" ||
                die "Could not quarantine stale /boot.inroot: $stage_stale"
            chmod 0700 "$stage_stale"
            log "Quarantined stale /boot.inroot at $stage_stale"
        fi
    else
        mkdir -p /boot.inroot
    fi
    rsync -aHAX --delete --one-file-system /boot/ /boot.inroot/
    install -o root -g root -m 0600 /dev/null /boot.inroot/.strazh-copy-complete

    if findmnt -n /boot/efi >/dev/null 2>&1; then
        esp_dev="$(findmnt -nro SOURCE /boot/efi 2>/dev/null || true)"
        [[ -b "$esp_dev" ]] || die "Could not resolve the mounted ESP device"
        umount /boot/efi || die "Could not unmount nested ESP before /boot move"
        esp_detached=1
    fi

    log "Unmounting /boot…"
    umount /boot || die "Could not unmount /boot cleanly; refusing to continue"

    local ts
    ts="$(date +%Y%m%d-%H%M%S)"
    if [[ "$KEEP_OLD_BOOT_DIR" == "1" ]]; then
        mv /boot "/boot.plain.old.${ts}" || die "Could not preserve old plaintext /boot"
    else
        rmdir /boot || die "Refusing to remove a non-empty underlying /boot directory"
    fi
    mv /boot.inroot /boot
    rm -f -- /boot/.strazh-copy-complete

    findmnt -n /boot >/dev/null 2>&1 && die "/boot still a mountpoint; expected directory inside /"
    log "/boot is now inside / (encrypted)."
)

disable_boot_mount_in_fstab() {
    backup_file /etc/fstab
    if grep -qE '^[^#].+[[:space:]]/boot[[:space:]]' /etc/fstab; then
        sed -i -E 's|^([^#].*[[:space:]]/boot[[:space:]].*)|#\1|' /etc/fstab
        systemctl daemon-reload >/dev/null 2>&1 || true
        log "Commented active /boot entry in /etc/fstab."
    fi
}

ensure_fallback_loader() {
    local efi_dir="/boot/efi" src=""
    if [[ -f "$efi_dir/EFI/debian/grubx64.efi" ]]; then
        src="$efi_dir/EFI/debian/grubx64.efi"
    elif [[ -f "$efi_dir/EFI/debian/shimx64.efi" ]]; then
        src="$efi_dir/EFI/debian/shimx64.efi"
    fi
    [[ -n "$src" ]] || die "Cannot find grubx64.efi or shimx64.efi in $efi_dir/EFI/debian"
    mkdir -p "$efi_dir/EFI/BOOT"
    cp -f "$src" "$efi_dir/EFI/BOOT/BOOTX64.EFI"
}

ensure_uefi_boot_entry() {
    local esp_dev="$1"
    local disk partnum loader
    disk="$(disk_of_part "$esp_dev")"
    partnum="$(partnum_of_part "$esp_dev")"

    if [[ -f /boot/efi/EFI/debian/grubx64.efi ]]; then
        loader='\EFI\debian\grubx64.efi'
    elif [[ -f /boot/efi/EFI/debian/shimx64.efi ]]; then
        loader='\EFI\debian\shimx64.efi'
    else
        return 0
    fi

    if efibootmgr -v | grep -qiE "File\\(${loader//\\/\\\\}\\)"; then
        return 0
    fi
    efibootmgr -c -d "$disk" -p "$partnum" -L debian -l "$loader" >/dev/null 2>&1 ||
        die "efibootmgr could not create the Debian UEFI entry"
    efibootmgr -v | grep -qiE "File\\(${loader//\\/\\\\}\\)" ||
        die "efibootmgr did not report the expected Debian loader entry"
    sync
}

rebuild_and_install_grub() {
    log "update-initramfs…"
    update-initramfs -u -k all

    log "update-grub…"
    update-grub

    log "grub-install (UEFI)…"
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=debian --recheck
    update-grub
}

ensure_keyfile_slot_once() {
    local luks_dev="$1" luks_uuid
    luks_uuid="$(trim "$(cryptsetup luksUUID "$luks_dev" 2>/dev/null || true)")"
    [[ -n "$luks_uuid" ]] || die "Cannot get LUKS UUID for $luks_dev"

    install -d -m 0700 "$(dirname "$KEYFILE_PATH")"
    if [[ ! -f "$KEYFILE_PATH" ]]; then
        dd if=/dev/urandom of="$KEYFILE_PATH" bs=1 count=64 status=none
    fi
    chmod 0400 "$KEYFILE_PATH"

    if cryptsetup open --test-passphrase "$luks_dev" --key-file "$KEYFILE_PATH" >/dev/null 2>&1; then
        log "Keyfile already valid; skipping luksAddKey."
    else
        log "Adding keyfile slot without extra prompt…"
        local was_xtrace=0
        if [[ "${-}" == *x* ]]; then
            was_xtrace=1
            set +x
        fi
        printf '%s' "$luks_pass" | cryptsetup luksAddKey "$luks_dev" "$KEYFILE_PATH" --key-file - --batch-mode
        if (( was_xtrace )); then
            set -x
        fi
    fi

    backup_file /etc/crypttab
    if grep -qE "^[^#]+[[:space:]]+UUID=${luks_uuid}[[:space:]]+none[[:space:]]" /etc/crypttab; then
        sed -i -E "s|^(.*[[:space:]]UUID=${luks_uuid}[[:space:]]+)none([[:space:]].*)$|\\1${KEYFILE_PATH}\\2|" /etc/crypttab
        log "Updated /etc/crypttab to use keyfile for UUID=${luks_uuid}."
    fi

    mkdir -p /etc/cryptsetup-initramfs
    printf 'KEYFILE_PATTERN="%s"\n' "$(dirname "$KEYFILE_PATH")/*.key" > /etc/cryptsetup-initramfs/conf-hook
    grep -q '^UMASK=0077' /etc/initramfs-tools/initramfs.conf || echo 'UMASK=0077' >> /etc/initramfs-tools/initramfs.conf

    log "update-initramfs…"
    update-initramfs -u -k all
}

test_human_passphrase_once() {
    local luks_dev="$1" success_message="${2:-Human LUKS passphrase unlock test passed}" was_xtrace=0

    [[ -n "${luks_pass:-}" ]] || die "The LUKS passphrase is unavailable for the unlock test."

    # cryptsetup --test-passphrase validates the supplied key without creating
    # a second mapper or touching encrypted data.  Disable xtrace while the
    # secret is passed through stdin so it can never appear in diagnostics.
    if [[ "${-}" == *x* ]]; then
        was_xtrace=1
        set +x
    fi
    if ! printf '%s' "$luks_pass" |
        cryptsetup open --test-passphrase "$luks_dev" --key-file - --batch-mode >/dev/null 2>&1; then
        (( was_xtrace )) && set -x
        die "The LUKS passphrase failed the unlock test; stopping before the next migration step."
    fi
    (( was_xtrace )) && set -x
    log "$success_message (no mapping created)."
}

verify_human_passphrase_once() {
    local luks_dev="$1"

    prompt_luks_pass_once "Enter root LUKS passphrase again (final unlock test): "
    test_human_passphrase_once "$luks_dev" \
        "Final human LUKS passphrase unlock test passed"
}

# ====== DESTRUCTIVE: WIPE/DELETE OLD BOOT PARTITION ======
wipe_partition_noise_plain() {
    local part="$1" wipe_bytes
    local name="deadwipe-$$-$RANDOM"
    [[ -b "$part" ]] || die "Not a block device: $part"
    findmnt -n -S "$part" >/dev/null 2>&1 && die "$part is mounted"
    have_cmd blockdev || die "blockdev not found"
    wipe_bytes="$(blockdev --getsize64 "$part" 2>/dev/null || true)"
    [[ "$wipe_bytes" =~ ^[1-9][0-9]*$ ]] || die "Could not determine exact size of $part"

    log "Wiping signatures on $part…"
    wipefs -a "$part" >/dev/null 2>&1 || die "Initial wipefs failed on $part"

    log "Overwriting $part with noise via dm-crypt plain…"
    cryptsetup open --type plain \
        --cipher aes-xts-plain64 --key-size 512 \
        --key-file /dev/urandom \
        "$part" "$name"

    # count_bytes writes the exact device length, including a final partial
    # block; a rounded block count would falsely return ENOSPC on partitions
    # whose size is not a multiple of 16 MiB.
    dd if=/dev/zero of="/dev/mapper/$name" bs=16M \
        iflag=fullblock,count_bytes count="$wipe_bytes" \
        status=progress oflag=direct conv=fsync || {
        cryptsetup close "$name" >/dev/null 2>&1 || true
        die "Plain overwrite failed on $part; refusing to delete its GPT entry"
    }

    cryptsetup close "$name" >/dev/null 2>&1 ||
        die "Could not close temporary wipe mapping $name"

    log "Wiping signatures again on $part…"
    wipefs -a "$part" >/dev/null 2>&1 ||
        die "Final wipefs failed on $part; refusing to delete its GPT entry"
}

delete_partition_gpt() {
    local disk="$1" num="$2"
    have_cmd sgdisk || die "sgdisk not found"
    log "Deleting partition entry #$num from GPT on $disk…"
    sgdisk --delete="$num" "$disk" >/dev/null
    sgdisk -e "$disk" >/dev/null 2>&1 || die "Could not relocate the GPT backup header"
    reread_pt "$disk"
}

wipe_delete_old_boot_partition() {
    local boot_part="$1" esp_dev="$2" root_part="$3"
    boot_part="$(trim "$boot_part")"
    esp_dev="$(trim "$esp_dev")"
    root_part="$(trim "$root_part")"

    if [[ -z "$boot_part" ]]; then
        log "No old /boot partition detected; skipping wipe/delete."
        return 0
    fi
    [[ -b "$boot_part" ]] || {
        log "Old /boot partition node not present ($boot_part); skipping."
        return 0
    }
    [[ "$boot_part" != "$esp_dev" ]] || die "Refusing: /boot partition equals ESP device ($boot_part)"
    [[ "$boot_part" != "$root_part" ]] || die "Refusing: /boot partition equals root LUKS device ($boot_part)"

    local disk num
    disk="$(disk_of_part "$boot_part")"
    num="$(partnum_of_part "$boot_part")"

    log "Old /boot partition: $boot_part (disk=$disk partnum=$num)"
    wipe_partition_noise_plain "$boot_part"
    delete_partition_gpt "$disk" "$num"
}

# ====== ESP EXPAND/RECREATE (MOST RELIABLE) ======
esp_backup_dir() {
    echo "/root/esp-backup.$(date +%Y%m%d-%H%M%S)"
}

get_part_sectors_parted() {
    local disk="$1"
    local num="$2"

    parted -m -s "$disk" unit s print \
        | awk -F: -v n="$num" '
            $1==n {
                s=$2; e=$3;
                gsub(/s$/,"",s);
                gsub(/s$/,"",e);
                print s " " e;
                exit
            }'
}

merge_esp_to_gap_recreate_fs() {
    local esp_dev="$1"
    local root_part="$2"

    esp_dev="$(trim "$esp_dev")"
    root_part="$(trim "$root_part")"

    [[ -n "$esp_dev" && -n "$root_part" ]] || die "merge_esp_to_gap: missing devices"
    [[ -b "$esp_dev" ]] || die "ESP device not present: $esp_dev"

    have_cmd parted || die "parted not found"
    have_cmd sgdisk  || die "sgdisk not found"
    have_cmd mkfs.vfat || die "mkfs.vfat not found"
    have_cmd fsck.vfat || die "fsck.vfat not found"

    local disk esp_num root_num root_disk
    disk="$(disk_of_part "$esp_dev")"
    esp_num="$(partnum_of_part "$esp_dev")"
    root_num="$(partnum_of_part "$root_part")"
    root_disk="$(disk_of_part "$root_part")"
    [[ "$disk" == "$root_disk" ]] || die "ESP disk ($disk) != root disk ($root_disk)"

    local line esp_s esp_e root_s

    line="$(trim "$(get_part_sectors_parted "$disk" "$esp_num" || true)")"
    [[ -n "$line" ]] || die "Cannot read ESP boundaries via parted"
    IFS=' ' read -r esp_s esp_e _ <<< "$line"
    IFS=$'\n\t'

    line="$(trim "$(get_part_sectors_parted "$disk" "$root_num" || true)")"
    [[ -n "$line" ]] || die "Cannot read root boundaries via parted"
    IFS=' ' read -r root_s _ <<< "$line"
    IFS=$'\n\t'

    esp_s="$(trim "${esp_s:-}")"
    esp_e="$(trim "${esp_e:-}")"
    root_s="$(trim "${root_s:-}")"

    [[ "$esp_s" =~ ^[0-9]+$ && "$esp_e" =~ ^[0-9]+$ && "$root_s" =~ ^[0-9]+$ ]] \
        || die "Cannot read sector boundaries via parted -m (esp_s=$esp_s esp_e=$esp_e root_s=$root_s)"

    if (( root_s <= esp_e + 1 )); then
        log "No gap after ESP; skipping ESP merge."
        return 0
    fi

    local new_end=$((root_s - 1))
    log "Expanding ESP to fill gap: disk=$disk esp_partnum=$esp_num old_last=$esp_e new_last=$new_end"

    local bad
    bad="$(
        parted -m -s "$disk" unit s print | awk -F: -v esp="$esp_num" -v root="$root_num" -v lo="$((esp_e+1))" -v hi="$new_end" '
            $1 ~ /^[0-9]+$/ {
                n=$1; s=$2; e=$3;
                gsub(/s$/,"",s); gsub(/s$/,"",e);
                if (n!=esp && n!=root && s+0 <= hi && e+0 >= lo) { print n; exit }
            }'
    )"
    bad="$(trim "$bad")"
    [[ -z "$bad" ]] || die "Cannot merge ESP: partition #$bad occupies gap"

    local bdir
    bdir="$(esp_backup_dir)"
    mkdir -p "$bdir"

    ensure_esp_mounted "$esp_dev"
    log "Backing up ESP -> $bdir"
    rsync -aHAX /boot/efi/ "$bdir"/
    sync

    umount /boot/efi >/dev/null 2>&1 || die "Could not unmount ESP before resize"
    systemctl daemon-reload >/dev/null 2>&1 || true

    sgdisk -e "$disk" >/dev/null 2>&1 || die "Could not relocate the GPT backup header before ESP resize"

    parted -s "$disk" unit s resizepart "$esp_num" "${new_end}s" >/dev/null
    reread_pt "$disk"

    log "Recreating ESP filesystem on $esp_dev"
    mkfs.vfat -F32 "$esp_dev" >/dev/null
    fsck.vfat -a "$esp_dev" >/dev/null 2>&1 || die "ESP filesystem check failed after recreation"

    mkdir -p /boot/efi
    mount -t vfat "$esp_dev" /boot/efi

    log "Restoring ESP from backup"
    rsync -aHAX "$bdir"/ /boot/efi/
    sync

    update_fstab_esp_uuid "$esp_dev"
    ensure_fallback_loader
    sync

    [[ -d /boot/efi/EFI ]] || die "ESP restore failed: /boot/efi/EFI missing"
}

# ====== CHECKS ======
self_check() {
    log "Self-check…"
    if findmnt -n /boot >/dev/null 2>&1; then
        die "/boot is still a mountpoint (expected directory inside /)"
    fi
    findmnt -n /boot/efi >/dev/null 2>&1 || die "/boot/efi not mounted"
    [[ -d /boot/efi/EFI ]] || die "ESP mounted but /boot/efi/EFI missing"
    [[ -f /boot/efi/EFI/debian/grubx64.efi || -f /boot/efi/EFI/debian/shimx64.efi ]] || die "Missing /boot/efi/EFI/debian loader"
    [[ -f /boot/efi/EFI/BOOT/BOOTX64.EFI ]] || die "Missing /boot/efi/EFI/BOOT/BOOTX64.EFI"
    have_glob "/boot/vmlinuz-*" || die "No /boot/vmlinuz-* found"
    have_glob "/boot/initrd.img-*" || die "No /boot/initrd.img-* found"
}

# ====== MAIN ======
main() {
    need_root
    fix_path
    acquire_sb_guard_lock
    apt_install

    if [[ "$TRACE" == "1" ]]; then
        set -x
    fi

    local boot_dev boot_dev_fstab esp_dev root_src crypt_mapper root_luks

    boot_dev="$(trim "$(detect_boot_dev)")"
    if [[ -z "$boot_dev" ]]; then
        boot_dev_fstab="$(trim "$(detect_boot_dev_from_fstab_any || true)")"
        [[ -n "$boot_dev_fstab" ]] && boot_dev="$boot_dev_fstab"
    fi
    if [[ -z "$boot_dev" && -f "$BOOT_DEVICE_STATE" ]]; then
        boot_dev="$(trim "$(<"$BOOT_DEVICE_STATE")")"
        [[ -b "$boot_dev" ]] || die "Saved old /boot device is no longer a block device: $boot_dev"
        log "Resuming with saved old /boot device: $boot_dev"
    fi

    esp_dev="$(trim "$(detect_esp_dev || true)")"
    [[ -n "$esp_dev" ]] || die "Cannot detect ESP device."

    root_src="$(trim "$(detect_root_src)")"
    crypt_mapper="$(trim "$(detect_root_crypt_mapper || true)")"
    root_luks="$(trim "$(detect_root_luks_dev || true)")"
    [[ -n "$crypt_mapper" ]] || die "Cannot detect crypt mapper backing /."
    [[ -n "$root_luks" ]] || die "Cannot detect underlying LUKS device backing /."

    log "Detected:"
    log "  root_src:     $root_src"
    log "  crypt_mapper: $crypt_mapper"
    log "  root_luks:    $root_luks"
    log "  /boot dev:    ${boot_dev:-<none>}"
    log "  ESP dev:      $esp_dev"

    if [[ -n "$boot_dev" ]]; then
        install -d -m 0700 -o root -g root "$(dirname "$BOOT_DEVICE_STATE")"
        printf '%s\n' "$boot_dev" |
            install -o root -g root -m 0600 /dev/stdin "$BOOT_DEVICE_STATE"
    fi

    ensure_esp_mounted "$esp_dev"
    ensure_grub_cryptodisk

    prompt_luks_pass_once "Enter EXISTING root LUKS passphrase (for adding slots): "
    test_human_passphrase_once "$root_luks" \
        "Initial human LUKS passphrase unlock test passed before destructive changes"
    ensure_pbkdf2_slot_for_grub_once "$root_luks"

    move_boot_into_root "${boot_dev:-}"
    disable_boot_mount_in_fstab

    if [[ "$WIPE_DELETE_OLD_BOOT" == "1" ]]; then
        wipe_delete_old_boot_partition "${boot_dev:-}" "$esp_dev" "$root_luks"
        rm -f -- "$BOOT_DEVICE_STATE"
    else
        log "WARNING: WIPE_DELETE_OLD_BOOT=0 leaves a stale plaintext /boot partition."
    fi

    if [[ "$MERGE_ESP" == "1" ]]; then
        merge_esp_to_gap_recreate_fs "$esp_dev" "$root_luks"
    else
        log "MERGE_ESP=0; not resizing/recreating ESP."
    fi

    ensure_esp_mounted "$esp_dev"
    update_fstab_esp_uuid "$esp_dev"

    rebuild_and_install_grub
    ensure_fallback_loader
    ensure_uefi_boot_entry "$esp_dev"

    if [[ "$ENABLE_ONE_PROMPT" == "1" ]]; then
        ensure_keyfile_slot_once "$root_luks"
    fi

    verify_human_passphrase_once "$root_luks"
    unset -v luks_pass
    self_check

    log "DONE. Reboot now."
    if [[ "$ENABLE_ONE_PROMPT" == "1" ]]; then
        log "Expected: one prompt in GRUB only."
    else
        log "Expected: GRUB prompt + initramfs prompt."
    fi
}

main "$@"

# Recovery/debug examples:
# TRACE=1 WIPE_DELETE_OLD_BOOT=1 MERGE_ESP=0 bash ./run.sh --fde
# WIPE_DELETE_OLD_BOOT=0 bash ./run.sh --fde  # intentionally keep plaintext /boot
