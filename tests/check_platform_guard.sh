#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Exercise the optional board/firmware integrity guard with synthetic DMI data.
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd -- "$ROOT_DIR"
temp_parent="${RUNNER_TEMP:-}"
if [[ -z "$temp_parent" || ! -w "$temp_parent" ]]; then temp_parent=/dev/shm; fi
[[ -d "$temp_parent" && -w "$temp_parent" ]] || temp_parent=/var/tmp
test_root="$(mktemp -d -p "$temp_parent" strazh-platform-ci.XXXXXX)"
cleanup() { rm -rf --one-file-system "$test_root"; }
trap cleanup EXIT

dmi_root="$test_root/dmi"
dmi_tables="$test_root/dmi-tables"
state_root="$test_root/platform-state"
image="$test_root/firmware.bin"
install -d -m 0700 "$dmi_root" "$dmi_tables" "$state_root"
printf '%s\n' 'fixture-uuid-001' >"$dmi_root/product_uuid"
printf '%s\n' 'fixture-product-serial' >"$dmi_root/product_serial"
printf '%s\n' 'fixture-board-vendor' >"$dmi_root/board_vendor"
printf '%s\n' 'fixture-board-name' >"$dmi_root/board_name"
printf '%s\n' 'fixture-board-revision-a' >"$dmi_root/board_version"
printf '%s\n' 'fixture-board-serial' >"$dmi_root/board_serial"
printf '%s\n' 'fixture-chassis-serial' >"$dmi_root/chassis_serial"
printf '%s\n' 'fixture-bios-vendor' >"$dmi_root/bios_vendor"
printf '%s\n' 'fixture-bios-version-1' >"$dmi_root/bios_version"
printf '%s\n' 'fixture-bios-revision-1' >"$dmi_root/bios_revision"
printf '%s\n' '2026-01-01' >"$dmi_root/bios_date"
printf '%s\n' 'fixture-dmi-bytes-v1' >"$dmi_tables/DMI"
printf '%s\n' 'fixture-smbios-entry-v1' >"$dmi_tables/smbios_entry_point"
printf '%s\n' 'firmware-image-v1' >"$image"

helper="$ROOT_DIR/lib/strazh_platform_guard.sh"
export STRAZH_PLATFORM_STATE_ROOT="$state_root"
export STRAZH_DMI_ROOT="$dmi_root"
export STRAZH_DMI_TABLE_ROOT="$dmi_tables"

python3 - "$helper" "$image" <<'PY'
import errno
import os
import pty
import sys
import time

helper, image = sys.argv[1:]


def run_pty(args, input_bytes=b"", expected=0):
    pid, fd = pty.fork()
    if pid == 0:
        env = os.environ.copy()
        env["TERM"] = "xterm-256color"
        os.execve("/bin/bash", ["bash", helper, *args], env)
    if input_bytes:
        os.write(fd, input_bytes)
    chunks = []
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        try:
            chunk = os.read(fd, 4096)
            if chunk:
                chunks.append(chunk)
                continue
            break
        except OSError as exc:
            if exc.errno == errno.EIO:
                break
            raise
    _, status = os.waitpid(pid, 0)
    output = b"".join(chunks).decode(errors="replace")
    actual = os.waitstatus_to_exitcode(status)
    if actual != expected:
        raise AssertionError(f"{args}: expected {expected}, got {actual}: {output}")
    return output


assert "mode=disabled" in run_pty(["status"])
assert "Platform-integrity guard enabled." in run_pty(
    ["enable", "--firmware-image", image], b"y\n"
)
assert "mode=enabled" in run_pty(["status"])
assert "OK: board and firmware identity match" in run_pty(
    ["verify", "--firmware-image", image]
)
run_pty(["disable-for-update"], b"y\n")
assert "mode=maintenance" in run_pty(["status"])

with open(os.path.join(os.environ["STRAZH_DMI_ROOT"], "bios_version"), "w") as fh:
    fh.write("fixture-bios-version-2\n")
image2 = image + ".new"
with open(image2, "wb") as fh:
    fh.write(b"firmware-image-v2\n")
run_pty(["capture-after-update", "--firmware-image", image2])
assert "Board digest unchanged" in run_pty(["finalize-update"], b"y\n")
assert "mode=enabled" in run_pty(["status"])
assert "OK: board and firmware identity match" in run_pty(
    ["verify", "--firmware-image", image2]
)

with open(image2, "ab") as fh:
    fh.write(b"tampered\n")
run_pty(["verify", "--firmware-image", image2], expected=1)
with open(os.path.join(os.environ["STRAZH_DMI_ROOT"], "board_serial"), "w") as fh:
    fh.write("different-board\n")
run_pty(["verify"], expected=1)
print("PLATFORM_GUARD_OK")
PY
