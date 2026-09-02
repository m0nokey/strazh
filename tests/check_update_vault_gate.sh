#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Verify the non-interactive APT worker and explicit vault update contract.
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd -- "$ROOT_DIR"

guard='lib/sb_guard_install.sh'
host='lib/strazh_host_cli.sh'
readme='README.md'

# APT must snapshot boot state and queue a reconcile only after a meaningful
# package or /boot change. This keeps ordinary application upgrades independent
# from the private-key vault.
grep -Fq -- 'snapshot_boot_state()' "$guard"
grep -Fq -- "boot package or boot artifact changed" "$guard"
grep -Fq -- '! cmp -s "$package_snapshot" "$after_snapshot"' "$guard"

# The serialized worker must be a no-op with an empty queue and must fail
# closed, with an actionable message, when signing material is locked away.
grep -Fq -- 'if [[ "${#events[@]}" -eq 0 ]]; then' "$guard"
grep -Fq -- "private-key vault is closed; run 'strazh --vault-open' before the update" "$guard"

# Read-only verification must use only public certificates and a temporary
# public-key GPG home; it must not force the private vault open.
grep -Fq -- 'verify_public_keys_present' "$guard"
grep -Fq -- 'GPG_VERIFY_HOME' "$guard"
grep -Fq -- '--import "$GRUB_GPG_KEY_FILE"' "$guard"

# Closing the vault is the synchronization point after apt: it waits for any
# queued or active worker instead of racing it or hiding a failed reconcile.
grep -Fq -- 'wait_for_sb_guard_idle()' "$host"
grep -Fq -- 'Timed out waiting for sb-guard worker; vault remains open' "$host"
grep -Fq -- '--vault-close waits for the queued sb-guard worker to finish.' "$readme"
grep -Fq -- '`apt-get update` never needs the vault' "$readme"

printf '%s\n' 'UPDATE_VAULT_GATE_OK'
