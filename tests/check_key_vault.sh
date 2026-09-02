#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
vault="$ROOT_DIR/lib/strazh_key_vault.sh"

bash -n "$vault"
grep -Fq -- 'cryptsetup open --type plain --cipher' "$vault"
grep -Fq -- 'nodev,nosuid,noexec,noatime' "$vault"
grep -Fq -- 'cryptsetup close' "$vault"
if grep -nE '(^|[[:space:]])sudo([[:space:]]|$)|log.*PASSPHRASE|/var/log.*PASSPHRASE' "$vault"; then
    printf '%s\n' 'Unsafe sudo or passphrase logging found in key vault helper' >&2
    exit 1
fi
printf '%s\n' 'KEY_VAULT_STATIC_OK'
