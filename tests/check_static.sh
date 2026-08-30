#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Static repository checks used by the GitHub Actions quality job.
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd -- "$ROOT_DIR"

mapfile -t SHELL_FILES < <(find . -maxdepth 2 -type f -name '*.sh' -print | sort)
[[ "${#SHELL_FILES[@]}" -gt 0 ]] || {
    printf '%s\n' 'No shell files found' >&2
    exit 1
}

for file in "${SHELL_FILES[@]}"; do
    bash -n "$file"
done

command -v shfmt >/dev/null 2>&1 || {
    printf '%s\n' 'shfmt is required by the CI image' >&2
    exit 1
}
shfmt -d -i 4 -ci -bn tests/*.sh >/dev/null

command -v shfmt >/dev/null 2>&1 || {
    printf '%s\n' 'shfmt is required by the CI image' >&2
    exit 1
}
shfmt -d -i 4 -ci -bn tests/*.sh >/dev/null

if command -v shellcheck >/dev/null 2>&1; then
    # Warnings are treated as errors here: generated scripts are installed as
    # root and must not enter the project with an unreviewed ShellCheck issue.
    shellcheck -S warning "${SHELL_FILES[@]}"
else
    printf '%s\n' 'shellcheck is required by the CI image' >&2
    exit 1
fi

git diff --check

# Do not allow private trust material, test passwords or generated EFI/build
# output into the repository. The .gitignore policy is checked separately so
# an accidental file cannot be hidden from this gate.
if git grep -nE -- '-----BEGIN ([A-Z0-9 -]+ )?PRIVATE KEY-----|lol[0-9]{3}' >/dev/null 2>&1; then
    printf '%s\n' 'Private key material or test credentials found in tracked files' >&2
    exit 1
fi

# Repository paths cannot contain newlines in this project, so a regular
# newline-delimited check works on both GNU and BusyBox grep.
if git ls-files | grep -Eq '(^|/)(\.git/|\.DS_Store|.*\.(key|pem|crt|cer|der|auth|esl|gpg|efi|sig|state|deb|dsc|changes|buildinfo|log|bak|tmp))$'; then
    printf '%s\n' 'Generated or private material is tracked by Git' >&2
    exit 1
fi

[[ -s run.sh ]] || {
    printf '%s\n' 'run.sh is missing' >&2
    exit 1
}
[[ -s lib/strazh_host_cli.sh ]] || {
    printf '%s\n' 'lib/strazh_host_cli.sh is missing' >&2
    exit 1
}

# All source files must use LF endings.  This catches a class of failures that
# otherwise appears only after a shell script is copied to a target host.
if grep -Il $'\r' -- run.sh lib/*.sh >/dev/null 2>&1; then
    printf '%s\n' 'CRLF line endings found in shell source' >&2
    exit 1
fi

printf 'STATIC_OK (%s shell files)\n' "${#SHELL_FILES[@]}"
