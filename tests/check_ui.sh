#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Exercise the terminal UI without invoking an installation stage.
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd -- "$ROOT_DIR"

python3 - "$ROOT_DIR/run.sh" "$ROOT_DIR/lib/strazh_host_cli.sh" <<'PY'
import errno
import os
import pty
import re
import subprocess
import sys
import time

run_sh, host_cli = sys.argv[1:]


def run_pty(script, args, input_bytes=b""):
    pid, fd = pty.fork()
    if pid == 0:
        env = os.environ.copy()
        env["TERM"] = "xterm-256color"
        os.execve("/bin/bash", ["bash", "-c", script, "ui-test", *args], env)

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
    output = b"".join(chunks)
    if os.waitstatus_to_exitcode(status) != 0:
        raise AssertionError(
            f"PTY command failed with status {status}: {output.decode(errors='replace')}"
        )
    return output


pipeline_script = r'''
source <(sed '$d' "$1")
state_get() { [[ "$1" == phase ]] && printf 'init\n'; }
fde_ready() { return 1; }
pve_ready() { return 1; }
secure_boot_artifacts_ready() { return 1; }
db_is_enrolled() { return 1; }
firmware_secure_boot_state() { printf 'disabled\n'; }
draw_menu
'''

colored = run_pty(pipeline_script, [run_sh])
text = colored.decode("utf-8", errors="replace")
plain_text = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", text).replace("\r", "")
for expected in (
    "Strazh — FDE + Proxmox VE + custom-only Secure Boot",
    "1. Setup Full Disk Encryption",
    "2. Install Proxmox VE",
    "3. Setup Secure Boot",
    "4. Finalize Secure Boot",
    "5. Installation Status",
    "6. Continue Installation Automatically",
    "x. Exit",
):
    assert expected in plain_text, expected
assert "\x1b[38;5;117m" in text  # blue labels
assert "\x1b[97m" in text  # white titles
assert "\x1b[3;38;5;245m" in text  # muted italic descriptions
assert "\x1b[38;5;245m" in text  # gray rules/status
assert "\x1b[0m" in text
assert not re.search(r"[\u0400-\u04ff]", plain_text)
assert any(line.startswith("   ") for line in plain_text.splitlines())

clear_script = r'''
source <(sed '$d' "$1")
ui_clear
'''
assert run_pty(clear_script, [run_sh]) == b"\x1b[H\x1b[2J\x1b[3J"

# The same renderer must stay machine-readable when stdout is redirected.
plain_script = pipeline_script
plain = subprocess.run(
    ["bash", "-c", plain_script, "ui-test", run_sh],
    check=True,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=False,
).stdout
assert b"\x1b[" not in plain

# Exercise the installed host utility's real menu and its Enter/Space return
# path.  No administrative operation is selected and no host state is changed.
host_menu_script = r'''
source <(sed '$d' "$1")
show_status() { :; }
menu
'''
host_text = run_pty(host_menu_script, [host_cli], b"1\n x\n")
host_decoded = host_text.decode("utf-8", errors="replace")
host_plain = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", host_decoded).replace("\r", "")
assert "Strazh — host administration" in host_plain
assert host_plain.count("Strazh — host administration") >= 2
assert "Press Enter or Space to return to the menu." in host_plain

# y/n validation rejects an invalid answer and accepts a later valid one.
confirm_script = r'''
source <(sed '$d' "$1")
ui_confirm 'Test confirmation'
'''
confirm_text = run_pty(confirm_script, [host_cli], b"maybe\nY\n").decode(
    "utf-8", errors="replace"
)
confirm_plain = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", confirm_text).replace("\r", "")
assert "Please answer y or n." in confirm_plain

print("UI_OK")
PY
