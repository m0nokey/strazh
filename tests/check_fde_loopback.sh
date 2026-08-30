#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Validate the two-slot FDE design on a disposable regular-file container.
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

[[ "$(id -u)" -eq 0 ]] || {
    printf '%s\n' 'This test must run as root (the CI job uses sudo).' >&2
    exit 1
}
for command_name in cryptsetup dd mktemp rm stat truncate; do
    command -v "$command_name" >/dev/null 2>&1 || {
        printf 'Missing command: %s\n' "$command_name" >&2
        exit 1
    }
done

temp_parent="${RUNNER_TEMP:-}"
if [[ -z "$temp_parent" || ! -w "$temp_parent" ]]; then
    temp_parent=/dev/shm
fi
[[ -d "$temp_parent" && -w "$temp_parent" ]] || temp_parent=/var/tmp
test_dir="$(mktemp -d -p "$temp_parent" strazh-fde-ci.XXXXXX)"
image="$test_dir/root.luks"
keyfile="$test_dir/root.key"
cleanup() {
    rm -f -- "$image" "$keyfile"
    rmdir -- "$test_dir" 2>/dev/null || true
}
trap cleanup EXIT

# Generate a long one-run-only passphrase. It is deliberately never printed or
# placed in the repository; this test must not train operators to reuse a
# short sample credential.
human_pass="Strazh-CI-LUKS2-PBKDF2-${RANDOM}-${RANDOM}-$(date +%s%N)-DoNotReuse"
truncate -s 128M "$image"

printf '%s' "$human_pass" \
    | cryptsetup luksFormat --batch-mode --type luks2 --pbkdf pbkdf2 \
        --iter-time 1000 "$image" -
head -c 64 /dev/urandom >"$keyfile"
chmod 0400 "$keyfile"

# Add a random keyfile slot with a bounded Argon2id cost. The old human slot is
# explicitly used as the authorization key; this is the same separation used
# by the production FDE stage.
printf '%s' "$human_pass" \
    | cryptsetup luksAddKey "$image" "$keyfile" --key-file - --batch-mode \
        --pbkdf argon2id --iter-time 1000 --pbkdf-memory 32768 --pbkdf-parallel 1

printf '%s' "$human_pass" \
    | cryptsetup open --test-passphrase "$image" --key-file - --key-slot 0
cryptsetup open --test-passphrase "$image" --key-file "$keyfile" --key-slot 1

dump="$(cryptsetup luksDump "$image")"
grep -qE '^[[:space:]]*Version:[[:space:]]+2$' <<<"$dump"
grep -qE '^[[:space:]]*PBKDF:[[:space:]]+pbkdf2$' <<<"$dump"
grep -qE '^[[:space:]]*PBKDF:[[:space:]]+argon2id$' <<<"$dump"
[[ "$(stat -c '%a %s' "$keyfile")" == '400 64' ]]

printf '%s\n' 'FDE_LOOPBACK_OK (human PBKDF2 slot + random keyfile slot verified)'
