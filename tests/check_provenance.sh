#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Check that source and package provenance is pinned in the implementation.
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd -- "$ROOT_DIR"

proxmox_script=lib/sb_proxmox.sh
grub_script=lib/sb_grub_profile_chroot.sh
shim_auto=lib/sb_shim_auto_build.sh
shim_build=lib/sb_shim_build_custom.sh

grep -Fq 'readonly PVE_KEY_URL="https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg"' "$proxmox_script"
grep -Eq 'readonly PVE_KEY_SHA256="[[:xdigit:]]{64}"' "$proxmox_script"
grep -Eq 'readonly PVE_KEY_FINGERPRINT="[[:xdigit:]]{40}"' "$proxmox_script"
grep -Fq 'sha256sum "$downloaded"' "$proxmox_script"
grep -Fq 'grep -Fqx "$PVE_KEY_FINGERPRINT"' "$proxmox_script"
grep -Fq 'Signed-By: $PVE_KEYRING' "$proxmox_script"
grep -Fq 'signed InRelease verified by the pinned Proxmox keyring' "$proxmox_script"
grep -Fq 'gpgv --keyring' tests/build_artifacts.sh
grep -Fq 'https://deb.debian.org/debian' tests/build_artifacts.sh

# The no-subscription download endpoint is intentionally HTTP in Proxmox's
# published configuration. Keep this exception explicit and require HTTPS for
# Debian mirrors and all Proxmox source-control endpoints.
grep -Fq 'PVE_REPO_URI="${PVE_REPO_URI:-http://download.proxmox.com/debian/pve}"' "$proxmox_script"
if rg -n 'http://' run.sh lib \
    | grep -vF 'PVE_REPO_URI="${PVE_REPO_URI:-http://download.proxmox.com/debian/pve}"'; then
    printf '%s\n' 'Unexpected plaintext HTTP endpoint found' >&2
    exit 1
fi

grep -Fq 'https://git.proxmox.com/git/grub2' "$grub_script"
grep -Fq 'https://git.proxmox.com/git/efi-boot-shim.git' "$shim_auto"
grep -Fq 'source_git_commit' "$grub_script"
grep -Fq 'source_tree_sha256' "$grub_script"
grep -Fq 'source_package_version' "$grub_script"
grep -Fq 'source_git_commit' "$shim_auto"
grep -Fq 'source_tree_sha256' "$shim_auto"
grep -Fq 'source_package_version' "$shim_build"
grep -Fq 'source_git_commit' "$shim_build"
grep -Fq 'source_tree_sha256' "$shim_build"

printf '%s\n' 'PROVENANCE_OK (pinned key, signed repository metadata and exact source mapping present)'
