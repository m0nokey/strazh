#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Verify the non-negotiable GRUB/shim artifact contract without building it.
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd -- "$ROOT_DIR"

grub=lib/sb_grub_profile_chroot.sh
shim=lib/sb_shim_build_custom.sh
guard=lib/sb_guard_install.sh

for pattern in \
    'debian/sbat.proxmox.csv.in' \
    'source_tree_sha256' \
    'fsck --strict' \
    'grub-mkstandalone' \
    'GRUB_MODULES' \
    'objcopy --dump-section .sbat'; do
    grep -Fq -- "$pattern" "$grub" || {
        printf 'Missing GRUB contract: %s\n' "$pattern" >&2
        exit 1
    }
done

for pattern in \
    'sbattach --remove' \
    'sbsign --key' \
    'sbverify --cert' \
    'objcopy --dump-section .vendor_cert' \
    'cmp -s "$vendor_der" "$embedded_der"' \
    'Expected exactly one Authenticode signature'; do
    grep -Fq -- "$pattern" "$shim" || {
        printf 'Missing shim contract: %s\n' "$pattern" >&2
        exit 1
    }
done

grep -Fq 'set check_signatures=enforce' "$guard"
grep -Fq 'Embedded GRUB signature enforcement missing' "$guard"
grep -Fq 'verify_grub_sbat_section' "$guard"
grep -Fq 'verify_shim_vendor_cert' "$guard"
grep -Fq 'manifest.sha256' "$guard"

printf '%s\n' 'ARTIFACT_CONTRACT_OK (GRUB, shim, SBAT, GPG and single-signature checks present)'
