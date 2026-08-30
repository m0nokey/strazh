#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Exercise the state and locking primitives without touching /var or /run.
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd -- "$ROOT_DIR"

temp_parent="${RUNNER_TEMP:-}"
if [[ -z "$temp_parent" || ! -w "$temp_parent" ]]; then
    temp_parent=/dev/shm
fi
[[ -d "$temp_parent" && -w "$temp_parent" ]] || temp_parent=/var/tmp
test_root="$(mktemp -d -p "$temp_parent" strazh-logic-ci.XXXXXX)"
cleanup() { rm -rf --one-file-system "$test_root"; }
trap cleanup EXIT

# Source definitions only; remove the final main invocation and its CLI trap.
# The state root is redirected after sourcing, so no test state reaches the
# protected production paths.
# shellcheck source=/dev/null
source <(sed '$d' run.sh)
STATE_ROOT="$test_root/state"
STATE_FILE="$STATE_ROOT/pipeline.state"
# shellcheck disable=SC2034
LOCK_FILE="$test_root/pipeline.lock"
# shellcheck disable=SC2034
RUNNING_PHASE=""
install -d -m 0700 "$STATE_ROOT"

# GitHub's Ubuntu runner has util-linux flock with a timeout option. The
# restricted development shell may expose BusyBox flock instead; adapt only
# this test harness so the same lock assertions can run there too.
if ! (
    exec 9>"$test_root/flock-probe"
    command flock -w 1 9
) 2>/dev/null; then
    flock() {
        if [[ "${1:-}" == -w ]]; then
            shift 2
        fi
        command flock "$@"
    }
fi

cat >"$STATE_FILE" <<'STATE'
schema=1
pipeline=strazh-fde-pve-sb-v1
phase=init
STATE
chmod 0600 "$STATE_FILE"

[[ "$(state_get phase)" == init ]]
state_set phase fde_done
state_set marker "value-without-newline"
[[ "$(state_get phase)" == fde_done ]]
[[ "$(state_get marker)" == value-without-newline ]]
[[ "$(grep -c '^phase=' "$STATE_FILE")" == 1 ]]
[[ "$(stat -c '%a' "$STATE_FILE")" == 600 ]]

# Invalid keys and newline-bearing values must fail closed in a child process.
if (state_set 'bad key' value) 2>/dev/null; then
    printf '%s\n' 'Invalid state key was accepted' >&2
    exit 1
fi
if (state_set valid $'bad\nvalue') 2>/dev/null; then
    printf '%s\n' 'Newline-bearing state value was accepted' >&2
    exit 1
fi

lock_marker="$test_root/lock-marker"
lock_body() {
    printf '%s\n' acquired >"$lock_marker"
}
with_lock lock_body
[[ -s "$lock_marker" ]]

# A failed child must return its original status and release the lock so the
# following operation can acquire it immediately.
set +e
with_lock bash -c 'exit 23'
failed_rc=$?
set -e
[[ "$failed_rc" == 23 ]]
with_lock lock_body

# run_external intentionally closes orchestration descriptors in descendants;
# this prevents grub-probe/vgs descriptor-leak warnings during real upgrades.
fd_check() {
    [[ ! -e /proc/self/fd/9 && ! -e /proc/self/fd/200 ]]
}
exec 9>"$test_root/parent-9"
exec 200>"$test_root/parent-200"
run_external fd_check
exec 9>&- 200>&-

# A pending boot marker is false for the same boot and true for a new boot.
boot_id() { printf '%s\n' "$TEST_BOOT_ID"; }
TEST_BOOT_ID=boot-a
state_set pending_boot_id boot-a
! reboot_seen
TEST_BOOT_ID=boot-b
reboot_seen

printf '%s\n' 'LOGIC_OK (atomic state, fail-safe locks and reboot marker verified)'
