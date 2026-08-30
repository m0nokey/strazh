#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 m0nokey
# Shared cached Debian Trixie build root for a reproducible GRUB profile.
#
# This helper never sees Secure Boot private keys, /boot, /boot/efi, or UEFI
# variables.  It reuses the provisioned base root, turns off networking for the
# actual build, exports only a small profile, and removes the disposable /build
# workspace on every exit.  The base root and its APT cache are retained for
# the next GRUB or shim build.
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

# ==============================================================================
# Configuration
# ==============================================================================
STATE_ROOT="${STATE_ROOT:-/var/lib/sb-guard}"
BUILD_ROOT="${BUILD_ROOT:-$STATE_ROOT/grub-build}"
PROFILE_ROOT="${PROFILE_ROOT:-$BUILD_ROOT/profile}"
BUILD_ROOT_HELPER="${BUILD_ROOT_HELPER:-/usr/local/sbin/sb-build-root}"
BUILD_BASE_ROOT="${BUILD_BASE_ROOT:-$STATE_ROOT/build-root/trixie-amd64}"
BUILD_ROOT_LOCK_FILE="${BUILD_ROOT_LOCK_FILE:-/run/sb-guard-build-root.lock}"
LOCK_FILE="${LOCK_FILE:-/run/sb-grub-profile-build.lock}"
GLOBAL_LOCK_FILE="${GLOBAL_LOCK_FILE:-/run/sb-guard.lock}"
SHIM_LOCK_FILE="${SHIM_LOCK_FILE:-/run/sb-shim-build.lock}"
MIRROR="${MIRROR:-https://deb.debian.org/debian}"
SECURITY_MIRROR="${SECURITY_MIRROR:-https://security.debian.org/debian-security}"
SUITE="${SUITE:-trixie}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 1)}"
MIN_FREE_KB="${MIN_FREE_KB:-3145728}"
KEEP_PREVIOUS="${KEEP_PREVIOUS:-1}"
SOURCE_CACHE_ROOT="${SOURCE_CACHE_ROOT:-$STATE_ROOT/source-cache}"

# Proxmox does not publish a deb-src index for pve-no-subscription.  The
# package's exact source therefore comes from the official Proxmox GRUB Git
# branch, never from an unrelated Debian candidate.  The ref and remote are
# policy constants: an operator cannot redirect an automatic build to an
# arbitrary repository through the environment.
readonly GRUB_SOURCE_REPO="https://git.proxmox.com/git/grub2"
readonly GRUB_SOURCE_REF="proxmox/trixie"
readonly GRUB_HISTORY_URL="https://git.proxmox.com/?p=grub2.git;a=history;f=debian/changelog;hb=proxmox/trixie"

# This is intentionally the same set used by sb-guard's production image.
# Keep only the UEFI GOP video path.  The source itself is still the complete
# Proxmox/Debian GRUB tree; this list only controls what goes into our
# standalone EFI image.
readonly -a GRUB_MODULES=(
    part_gpt diskfilter crypto extcmd test procfs cryptodisk afsplitter luks2 json
    lvm ext2 fshelp gcry_rijndael gcry_sha1 gcry_sha256 gcry_sha512 gcry_rsa
    mpi pbkdf2 pgp configfile search search_fs_file search_fs_uuid search_label
    echo reboot sleep normal boot bufio datetime net priority_queue terminal linux
    mmap relocator memdisk tar archelp font video video_fb gfxterm gettext gzio
    gcry_crc bli efi_gop
)
# The script uses newline/tab as its global IFS.  Join explicitly with spaces
# because this value is embedded in a shell loop inside the build root.
GRUB_MODULE_LIST="$(printf '%s ' "${GRUB_MODULES[@]}")"
readonly GRUB_MODULE_LIST

# ==============================================================================
# Helpers
# ==============================================================================
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '[sb-grub-profile-chroot] %s\n' "$*" >&2; }
need() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }
sha256_file() { sha256sum "$1" | awk '{print $1}'; }

# Strip the shell indentation from generated configuration files while
# keeping their source readable. The helper removes at most the requested
# number of leading spaces and never changes configuration content otherwise.
indent() {
    local arg="${1:-}" mode num
    if [[ "$arg" =~ ^([+-])([0-9]+)$ ]]; then
        mode="${BASH_REMATCH[1]}"
        num="${BASH_REMATCH[2]}"
    else
        mode="$arg"
        num="${2:-0}"
    fi
    case "$mode" in
        +) sed "s/^/$(printf '%*s' "$num" '')/" ;;
        -) sed -E "s/^ {0,$num}//" ;;
        0) awk '{ $1=$1; print }' ;;
        *) return 1 ;;
    esac
}

profile_modules_sha256() {
    # Hash relative paths so the value remains stable when a verified profile
    # is atomically moved from its temporary staging directory.
    (
        cd -- "$1"
        find . -type f -name '*.mod' -print0 |
            sort -z | xargs -0r sha256sum | sha256sum | awk '{print $1}'
    )
}

profile_module_list_sha256() {
    printf '%s\n' "${GRUB_MODULES[@]}" | sha256sum | awk '{print $1}'
}

profile_manifest_is_valid() {
    [[ -s "$PROFILE_ROOT/manifest.sha256" ]] || return 1
    (
        cd -- "$PROFILE_ROOT"
        sha256sum -c --strict manifest.sha256 >/dev/null 2>&1
    )
}

profile_value() {
    local key="$1"
    [[ -s "$PROFILE_ROOT/profile.env" ]] || return 0
    sed -n "s/^${key}=//p" "$PROFILE_ROOT/profile.env" | sed '/^$/d;1q'
}

profile_is_current() {
    local installed builder modules_source sbat_source sbat_hash sbat_template sbat_template_hash
    local source_remote_value source_ref_value source_commit_value source_tree_value
    local source_cache source_cache_commit source_cache_remote source_cache_version source_cache_tree
    installed="$(installed_grub_version)"
    builder="$PROFILE_ROOT/bin/grub-mkstandalone"
    modules_source="$PROFILE_ROOT/lib/grub/x86_64-efi"
    [[ -s "$PROFILE_ROOT/profile.env" && -x "$builder" && -d "$modules_source" ]] || return 1
    [[ "$(profile_value grub_package_version)" == "$installed" ]] || return 1
    [[ "$(profile_value build_recipe)" == debian-proxmox-patched ]] || return 1
    [[ "$(profile_value sbat_source)" == monolithic/grubx64.efi ]] || return 1
    [[ "$(profile_value sbat_template)" == debian/sbat.proxmox.csv.in ]] || return 1
    [[ "$(profile_value cli_mode)" == interactive ]] || return 1
    [[ "$(profile_value builder_sha256)" == "$(sha256_file "$builder")" ]] || return 1
    [[ "$(profile_value modules_tree_sha256)" == "$(profile_modules_sha256 "$modules_source")" ]] || return 1
    [[ "$(profile_value module_list_sha256)" == "$(profile_module_list_sha256)" ]] || return 1
    profile_manifest_is_valid || return 1
    sbat_source="$(profile_value sbat_source)"
    sbat_hash="$(profile_value sbat_sha256)"
    [[ -n "$sbat_source" && -s "$PROFILE_ROOT/$sbat_source" ]] || return 1
    [[ "$sbat_hash" == "$(sha256_file "$PROFILE_ROOT/$sbat_source")" ]] || return 1
    sbat_template="$(profile_value sbat_template)"
    sbat_template_hash="$(profile_value sbat_template_sha256)"
    [[ -n "$sbat_template" && -s "$PROFILE_ROOT/$sbat_template" ]] || return 1
    [[ "$sbat_template_hash" == "$(sha256_file "$PROFILE_ROOT/$sbat_template")" ]] || return 1

    # New profiles are tied to the exact official Proxmox ref, commit and
    # deterministic source-tree hash that produced them.  The installed
    # package version must be the top changelog version of that tree.
    source_remote_value="$(profile_value source_remote)"
    source_ref_value="$(profile_value source_ref)"
    source_commit_value="$(profile_value source_git_commit)"
    source_tree_value="$(profile_value source_tree_sha256)"
    if [[ "$(profile_value source_package_version)" == "$installed" \
        && "$source_remote_value" == "$GRUB_SOURCE_REPO" \
        && "$source_ref_value" == "$GRUB_SOURCE_REF" \
        && "$source_commit_value" =~ ^[[:xdigit:]]{40}$ \
        && "$source_tree_value" =~ ^[[:xdigit:]]{64}$ ]]; then
        source_cache="$SOURCE_CACHE_ROOT/grub/${installed}-${source_commit_value}"
        [[ -d "$source_cache/.git" && -f "$source_cache/configure.ac" ]] || return 1
        source_cache_commit="$(source_commit "$source_cache")"
        source_cache_remote="$(source_remote "$source_cache")"
        source_cache_version="$(cd -- "$source_cache" && source_version)"
        source_cache_tree="$(source_tree_sha256 "$source_cache")"
        [[ "$source_cache_commit" == "$source_commit_value" ]] || return 1
        [[ "$source_cache_remote" == "$GRUB_SOURCE_REPO" ]] || return 1
        [[ "$source_cache_version" == "$installed" ]] || return 1
        [[ "$source_cache_tree" == "$source_tree_value" ]] || return 1
        return 0
    fi

    return 1
}

source_tree_sha256() {
    tar -C "$1" --exclude=.git --exclude=.gitmodules --sort=name \
        --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner \
        -cf - . | sha256sum | awk '{print $1}'
}

free_kb() { df --output=avail -k "$1" | sed '1d' | tr -d '[:space:]'; }

cleanup_stale_build_artifacts() {
    local stale mountpoint
    [[ -d "$BUILD_ROOT" ]] || return 0
    # Only remove our own disposable top-level directories.  The verified
    # source-cache, current profile and one previous profile are persistent
    # state and are intentionally not touched here.
    while IFS= read -r -d '' stale; do
        # mmdebstrap can leave bind mounts (including dev/shm) behind when a
        # build is interrupted.  Enumerate only mounts rooted below this
        # disposable chroot and unmount deepest paths first; never walk
        # outside BUILD_ROOT.
        while IFS= read -r mountpoint; do
            [[ "$mountpoint" == "$stale"/* ]] || continue
            umount -l -- "$mountpoint" >/dev/null 2>&1 || true
        done < <(findmnt -R -n -o TARGET "$stale" 2>/dev/null | sort -r)
        rm -rf --one-file-system -- "$stale" ||
            log "WARN: stale disposable tree could not be fully removed: $stale"
    done < <(find "$BUILD_ROOT" -mindepth 1 -maxdepth 1 -type d \( \
        -name '.chroot.*' -o -name '.testchroot.*' -o -name '.profile.*' \
        -o -name '.export.*' -o -name '.source.*' \
    \) -print0)
    # GitWeb resolver history is a regular file and therefore needs a
    # separate cleanup pass.  It must not survive an interrupted fetch/build.
    find "$BUILD_ROOT" -mindepth 1 -maxdepth 1 -type f -name '.history.*' \
        -delete 2>/dev/null || true
}

source_version() {
    dpkg-parsechangelog -S Version 2>/dev/null | sed '/^$/d;1q' || true
}

installed_grub_version() {
    dpkg-query -W -f='${Version}\n' grub-efi-amd64-bin 2>/dev/null | sed '/^$/d;1q'
}

source_commit() { git -C "$1" rev-parse HEAD 2>/dev/null || true; }
source_remote() { git -C "$1" config --get remote.origin.url 2>/dev/null || true; }

validate_paths() {
    [[ "$STATE_ROOT" == /var/lib/sb-guard ]] ||
        die "STATE_ROOT must remain /var/lib/sb-guard for destructive cleanup"
    [[ "$BUILD_ROOT" == "$STATE_ROOT/"* && "$PROFILE_ROOT" == "$BUILD_ROOT/"* ]] ||
        die "BUILD_ROOT and PROFILE_ROOT must remain below STATE_ROOT"
    [[ "$SOURCE_CACHE_ROOT" == "$BUILD_ROOT/"* ]] ||
        [[ "$SOURCE_CACHE_ROOT" == "$STATE_ROOT/"* ]] ||
        die "SOURCE_CACHE_ROOT must remain below STATE_ROOT"
    [[ "$BUILD_BASE_ROOT" == "$STATE_ROOT/build-root/"* ]] ||
        die "BUILD_BASE_ROOT must remain below the shared build-root"
    [[ "$MIRROR" == https://* && "$SECURITY_MIRROR" == https://* ]] ||
        die "Only HTTPS Debian mirrors are allowed"
}

prepare_proxmox_source() {
    local installed history work tree target_commit commit remote version cache_dir cache_tmp
    local advertised branch line
    installed="$(installed_grub_version)"
    [[ -n "$installed" ]] || die "grub-efi-amd64-bin is not installed"
    branch="refs/heads/$GRUB_SOURCE_REF"

    # GitWeb history maps the installed Debian package version to the exact
    # Proxmox commit which introduced it.  This avoids cloning a moving branch
    # and never mixes source from a later package release.
    history="$(mktemp -p "$BUILD_ROOT" .history.XXXXXX)"
    trap 'rm -f -- "${history:-}"' RETURN
    log "Resolving Proxmox GRUB commit for installed version $installed"
    curl -4 -fsSL --retry 5 --connect-timeout 15 --max-time 90 \
        -A 'sb-guard-source-resolver/1' "$GRUB_HISTORY_URL" -o "$history"
    # The GitWeb page title contains the same subject but points at the
    # branch name (not a commit).  Select the actual history-row link so the
    # extracted h= value is always a 40-hex object id.
    line="$(grep -F 'class="list subject"' "$history" | grep -m1 -F "bump version to $installed" || true)"
    target_commit="$(sed -n 's/.*a=commit;h=\([[:xdigit:]]\{40\}\).*/\1/p' <<<"$line" | sed '/^$/d;1q')"
    [[ "$target_commit" =~ ^[[:xdigit:]]{40}$ ]] ||
        die "No official Proxmox GRUB commit maps to installed version: $installed"
    advertised="$(git ls-remote "$GRUB_SOURCE_REPO" "$branch" 2>/dev/null \
        | awk 'NF >= 2 { print $1; exit }')"
    [[ "$advertised" =~ ^[[:xdigit:]]{40}$ ]] ||
        die "Cannot resolve official Proxmox GRUB source ref: $GRUB_SOURCE_REF"

    cache_dir="$SOURCE_CACHE_ROOT/grub/${installed}-${target_commit}"
    if [[ -d "$cache_dir" ]]; then
        check_source "$cache_dir"
        [[ "$(source_commit "$cache_dir")" == "$target_commit" ]] ||
            die "Cached GRUB source commit mismatch: $cache_dir"
        printf '%s\n' "$cache_dir"
        return 0
    fi

    work="$(mktemp -d -p "$BUILD_ROOT" .source.XXXXXX)"
    trap 'rm -rf --one-file-system "${work:-}"; rm -f -- "${history:-}"' RETURN
    tree="$work/tree"
    log "Fetching only exact Proxmox GRUB commit $target_commit"
    git init -q "$tree"
    git -C "$tree" remote add origin "$GRUB_SOURCE_REPO"
    git -C "$tree" -c http.version=HTTP/1.1 fetch --depth=1 origin "$target_commit" >&2
    git -C "$tree" checkout --detach --quiet FETCH_HEAD
    remote="$(source_remote "$tree")"
    [[ "$remote" == "$GRUB_SOURCE_REPO" || "$remote" == "$GRUB_SOURCE_REPO.git" ]] ||
        die "Fetched source remote is not the approved Proxmox repository: $remote"
    git -C "$tree" fsck --strict --no-progress >&2
    commit="$(source_commit "$tree")"
    [[ "$commit" == "$target_commit" ]] || die "Fetched commit mismatch"
    version="$(cd "$tree" && source_version)"
    [[ "$version" == "$installed" ]] ||
        die "Proxmox source/package version mismatch (source=${version:-empty} installed=$installed)"
    [[ -f "$tree/debian/sbat.proxmox.csv.in" ]] ||
        die "Proxmox source has no Proxmox SBAT template: $tree"

    # The exact branch head is recorded for audit.  The target commit must be
    # present in the official history response; the shallow fetch itself is
    # from the pinned HTTPS repository and is verified with git fsck.
    [[ "$advertised" =~ ^[[:xdigit:]]{40}$ ]] || die "Invalid advertised branch head"
    install -d -m 0700 -o root -g root "$SOURCE_CACHE_ROOT/grub"
    cache_tmp="$SOURCE_CACHE_ROOT/grub/.${installed}-${target_commit}.new"
    rm -rf --one-file-system "$cache_tmp"
    mv -- "$tree" "$cache_tmp"
    mv -- "$cache_tmp" "$cache_dir"
    rm -rf --one-file-system "$work"
    trap - RETURN
    rm -f -- "$history"
    printf '%s\n' "$cache_dir"
}

check_source() {
    local source="$1" installed version commit
    [[ -d "$source" && -f "$source/configure.ac" ]] ||
        die "GRUB source must contain configure.ac: $source"
    [[ -d "$source/.git" ]] || die "Source must be an exact git checkout: $source"
    installed="$(installed_grub_version)"
    [[ -n "$installed" ]] || die "grub-efi-amd64-bin is not installed"
    version="$(cd "$source" && source_version)"
    [[ -n "$version" && "$version" == "$installed" ]] ||
        die "GRUB source version mismatch (source=${version:-empty} installed=${installed:-empty})"
    commit="$(source_commit "$source")"
    [[ "$commit" =~ ^[[:xdigit:]]{40}$ ]] || die "Cannot record exact source commit"

    local remote
    remote="$(source_remote "$source")"
    [[ -n "$remote" ]] ||
        die "Source checkout has no origin remote"
    case "$remote" in
        https://git.proxmox.com/git/grub2|https://git.proxmox.com/git/grub2.git|\
        https://git.proxmox.com/git/grub2/*|https://git.proxmox.com/git/grub.git|\
        https://git.proxmox.com/git/grub.git/*|\
        https://salsa.debian.org/grub-team/grub.git|https://git.savannah.gnu.org/git/grub.git)
            ;;
        *) die "Source remote is not an approved GRUB repository: $remote" ;;
    esac
    log "Source version=$version commit=$commit"
    log "Source remote=$remote"
}

write_chroot_sources() {
    local root="$1"
    cat <<EOF | indent -4 | install -D -m 0644 /dev/stdin \
        "$root/etc/apt/sources.list.d/sb-grub-build.sources"
    Types: deb deb-src
    URIs: $MIRROR
    Suites: $SUITE $SUITE-updates
    Components: main
    Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

    Types: deb deb-src
    URIs: $SECURITY_MIRROR
    Suites: $SUITE-security
    Components: main
    Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
}

configure_chroot_dns() {
    local root="$1"
    rm -f -- "$root/etc/resolv.conf"
    cat <<EOF | indent -4 | install -m 0644 /dev/stdin "$root/etc/resolv.conf"
    nameserver 1.1.1.1
    nameserver 9.9.9.9
    options timeout:2 attempts:3
EOF
}

create_chroot() {
    local root="$1"
    [[ "$root" == "$BUILD_BASE_ROOT" ]] ||
        die "GRUB build must use the shared Trixie build root"
    [[ -x "$BUILD_ROOT_HELPER" ]] ||
        die "Missing shared build-root helper: $BUILD_ROOT_HELPER"
    "$BUILD_ROOT_HELPER" --ensure
    [[ -x "$root/bin/bash" && -s "$root/.sb-guard-build-root" ]] ||
        die "Shared build root is incomplete: $root"
    "$BUILD_ROOT_HELPER" --clean
}

copy_source_into_chroot() {
    local source="$1" root="$2"
    # Symlinks remain confined by chroot and the whole tree is deleted later.
    # Do not copy .git history: commit/remote were recorded before the copy.
    rm -rf -- "$root/build/source"
    install -d -m 0700 -o root -g root "$root/build/source"
    tar -C "$source" --exclude=.git --exclude=.gitmodules -cf - . |
        tar -C "$root/build/source" -xf -
    chown -R root:root "$root/build/source" "$root/build/out" "$root/build/home"
}

run_build_no_network() {
    local root="$1" export_dir="$2" source_deb_version="$3" upstream_version="$4"
    need unshare
    need chroot
    # There is no network interface during compilation.  The source and
    # dependencies were copied/installed before entering this namespace.
    # A network namespace is sufficient for the no-network build.  We do not
    # create a mount namespace: the parent must inspect the verified output
    # after chroot exits.  Copy it only after the command completed
    # successfully; no signing key or host path is visible in the chroot.
    install -d -m 0700 "$export_dir"
    [[ "$source_deb_version" =~ ^[0-9A-Za-z.+:~_-]+$ ]] ||
        die "Unsafe source package version for SBAT generation: $source_deb_version"
    [[ "$upstream_version" =~ ^[0-9A-Za-z.+:~_-]+$ ]] ||
        die "Unsafe upstream version for SBAT generation: $upstream_version"
    GRUB_DEB_VERSION="$source_deb_version" GRUB_UPSTREAM_VERSION="$upstream_version" \
    unshare --net --fork -- chroot "$root" /bin/bash -Eeuo pipefail -c '
        # Keep generated-tool output deterministic and avoid inheriting a host
        # locale that is not installed in the minimal Trixie root.  The GRUB
        # source emits harmless Python 3 escape-sequence warnings; suppress
        # only that known warning class while retaining every build error.
        export HOME=/build/home TMPDIR=/build/tmp
        export LANG=C.UTF-8 LANGUAGE=C.UTF-8 LC_ALL=C.UTF-8
        export PYTHONWARNINGS=ignore::SyntaxWarning
        export GRUB_LIBDIR=/build/root/usr/lib/grub
        export LD_LIBRARY_PATH=/build/root/usr/lib:${LD_LIBRARY_PATH:-}
        mkdir -p /build/tmp /build/root /build/out/bin /build/out/lib/grub/x86_64-efi /build/out/monolithic
        chown -R nobody:nogroup /build/source /build/tmp /build/root /build/out /build/home
        cd /build/source
        [[ -x ./configure || -x ./bootstrap || -x ./autogen.sh ]] ||
            { echo "source has no configure/bootstrap entrypoint" >&2; exit 1; }
        # Apply the complete Debian 3.0 (quilt) patch stack before generating
        # configure files.  The source cache is a clean Proxmox checkout, so
        # dpkg-source is the same patch application step used by
        # dpkg-buildpackage.  The disposable copy is deleted after the build.
        command -v dpkg-source >/dev/null 2>&1 || {
            echo "missing dpkg-source in the Trixie build root" >&2
            exit 1
        }
        dpkg-source --before-build /build/source
        patch_count="$(grep -Ec "^[^#[:space:]]" debian/patches/series || true)"
        (( patch_count >= 100 )) || {
            echo "unexpectedly short Proxmox patch series: $patch_count" >&2
            exit 1
        }
        # The Debian rules add this generated dependency file when building
        # from the source package.  Reproduce that exact input for a focused
        # EFI build rather than silently falling back to upstream defaults.
        if [[ ! -f grub-core/extra_deps.lst ]]; then
            printf "%s\\n" "depends bli part_gpt" > grub-core/extra_deps.lst
        fi
        [[ "$(cat grub-core/extra_deps.lst)" == "depends bli part_gpt" ]] || {
            echo "unexpected grub-core/extra_deps.lst contents" >&2
            exit 1
        }
        # Match the Debian autoreconf setup, including the small GRUB extras and
        # the minilzo sources supplied by liblzo2-dev.
        rm -rf -- debian/grub-extras-enabled
        mkdir -p debian/grub-extras-enabled
        for extra in 915resolution ntldr-img; do
            [[ -d "debian/grub-extras/$extra" ]] &&
                cp -a -- "debian/grub-extras/$extra" debian/grub-extras-enabled/
        done
        if [[ -x /usr/bin/dh_autoreconf && -x ./autogen.sh ]]; then
            env -u DH_OPTIONS GRUB_CONTRIB=/build/source/debian/grub-extras-enabled \
                PYTHON=python3 dh_autoreconf -- ./autogen.sh
        elif [[ -x ./bootstrap ]]; then
            ./bootstrap
        elif [[ -x ./autogen.sh ]]; then
            ./autogen.sh
        fi
        mkdir -p grub-core/lib/minilzo
        cp -a /usr/share/lzo/minilzo/*.c /usr/share/lzo/minilzo/*.h \
            grub-core/lib/minilzo/
        [[ -x ./configure ]] || { echo "bootstrap did not create configure" >&2; exit 1; }
        # Keep Debian hardening and package identity while building only the
        # amd64 EFI target needed by sb-guard.  This is deliberately not a
        # naked upstream configure invocation.
        export DEB_BUILD_MAINT_OPTIONS=optimize=-lto
        export HOST_CPPFLAGS="$(dpkg-buildflags --get CPPFLAGS)"
        export HOST_CFLAGS="-Wall -Wno-error=unused-result $(dpkg-buildflags --get CFLAGS | sed "s/-O3\\b/-O2/")"
        export HOST_LDFLAGS="$(dpkg-buildflags --get LDFLAGS)"
        export TARGET_CPPFLAGS=-Wno-unused-but-set-variable
        export TARGET_LDFLAGS=-no-pie
        export CPPFLAGS= CFLAGS= LDFLAGS=
        ./configure \
            PACKAGE_VERSION="${GRUB_DEB_VERSION}" \
            PACKAGE_STRING="GRUB ${GRUB_DEB_VERSION}" \
            CC=gcc TARGET_CC=gcc \
            --prefix=/usr --libdir=/usr/lib --libexecdir=/usr/lib \
            --enable-grub-mkfont --disable-grub-emu-usb --enable-grub-themes \
            --with-dejavufont=/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf \
            --with-platform=efi --target=amd64-pe --program-prefix="" \
            --disable-werror
        make -j"'"$JOBS"'"
        echo "SB-BUILD: make completed; installing helper and modules"
        if make install DESTDIR=/build/root; then
            install_rc=0
        else
            install_rc=$?
        fi
        echo "SB-BUILD: make install rc=$install_rc"
        (( install_rc == 0 )) || exit "$install_rc"
        builder="$(find /build/root/usr/bin -maxdepth 1 -type f -name grub-mkstandalone -perm -u+x -print -quit)"
        module_dir="$(find /build/root/usr/lib/grub -mindepth 1 -maxdepth 1 -type d -name x86_64-efi -print -quit)"
        echo "SB-BUILD: checking builder=$builder module_dir=$module_dir"
        [[ -n "$builder" && -x "$builder" && -n "$module_dir" && -d "$module_dir" ]] ||
            { echo "missing GRUB builder or module tree" >&2; exit 1; }
        chmod 0755 "$module_dir"
        for module in '"$GRUB_MODULE_LIST"'; do
            [[ -f "$module_dir/$module.mod" ]] ||
                { echo "GRUB module closure missing: $module_dir/$module.mod" >&2; exit 1; }
        done
        install -m 0755 "$builder" /build/out/bin/grub-mkstandalone
        cp -a -- "$module_dir/." /build/out/lib/grub/x86_64-efi/
        sed -e "s/@DEB_VERSION@/${GRUB_DEB_VERSION}/g" \
            -e "s/@UPSTREAM_VERSION@/${GRUB_UPSTREAM_VERSION}/g" \
            /build/source/debian/sbat.proxmox.csv.in > /build/tmp/sbat.proxmox.csv
        echo "SB-BUILD: creating monolithic EFI"
        "$builder" --directory="$module_dir" --format=x86_64-efi \
            --output=/build/out/monolithic/grubx64.efi --compress=xz \
            --install-modules="'"$GRUB_MODULE_LIST"'" --modules="'"$GRUB_MODULE_LIST"'" \
            --sbat=/build/tmp/sbat.proxmox.csv
        /build/root/usr/bin/grub-file --is-x86_64-efi /build/out/monolithic/grubx64.efi
        objcopy --dump-section .sbat=/build/out/monolithic/grub.sbat \
            /build/out/monolithic/grubx64.efi
        [[ -s /build/out/monolithic/grub.sbat ]] ||
            { echo "missing SBAT section" >&2; exit 1; }
        # Keep the octal escapes literal for the inner shell.  The surrounding
        # command is single-quoted, so using double quotes here avoids the
        # outer parser turning them into ordinary text characters.
        tr -d "\\000\\015" </build/out/monolithic/grub.sbat |
            awk -F, "\$1 != \"\" && \$2 ~ /^[0-9]+$/ { found=1 } END { exit !found }" ||
            { echo "malformed SBAT generation field" >&2; exit 1; }
        [[ -x /build/out/bin/grub-mkstandalone &&
            -s /build/out/monolithic/grubx64.efi ]] ||
            { echo "build output export is incomplete" >&2; exit 1; }
        rm -rf -- /build/tmp
    '
    [[ -f "$root/build/out/bin/grub-mkstandalone" &&
        -s "$root/build/out/monolithic/grubx64.efi" ]] ||
        die "GRUB chroot completed without a complete exported result"
    cp -a -- "$root/build/out/." "$export_dir/"
    [[ -f "$export_dir/bin/grub-mkstandalone" &&
        -s "$export_dir/monolithic/grubx64.efi" ]] ||
        die "GRUB result copy out of chroot is incomplete"
}

publish_profile() {
    local outdir="$1" source="$2" tmp="$3"
    local version commit remote source_ref_value source_tree_sha patch_series_sha builder_sha modules_sha module_list_sha sbat_sha sbat_template_sha
    version="$(cd "$source" && source_version)"
    commit="$(source_commit "$source")"
    remote="$(source_remote "$source")"
    source_ref_value="$GRUB_SOURCE_REF"
    source_tree_sha="$(source_tree_sha256 "$source")"
    patch_series_sha="$(sha256_file "$source/debian/patches/series")"

    install -d -m 0700 "$tmp/bin" "$tmp/lib/grub/x86_64-efi" "$tmp/monolithic" "$tmp/debian"
    install -m 0755 "$outdir/bin/grub-mkstandalone" "$tmp/bin/grub-mkstandalone"
    cp -a -- "$outdir/lib/grub/x86_64-efi/." "$tmp/lib/grub/x86_64-efi/"
    install -m 0600 "$outdir/monolithic/grubx64.efi" "$tmp/monolithic/grubx64.efi"
    install -m 0600 "$source/debian/sbat.proxmox.csv.in" "$tmp/debian/sbat.proxmox.csv.in"

    builder_sha="$(sha256_file "$tmp/bin/grub-mkstandalone")"
    modules_sha="$(profile_modules_sha256 "$tmp/lib/grub/x86_64-efi")"
    module_list_sha="$(profile_module_list_sha256)"
    sbat_sha="$(sha256_file "$tmp/monolithic/grubx64.efi")"
    sbat_template_sha="$(sha256_file "$tmp/debian/sbat.proxmox.csv.in")"
    {
        printf 'grub_package_version=%s\n' "$version"
        printf 'source_git_commit=%s\n' "$commit"
        printf 'source_remote=%s\n' "$remote"
        printf 'source_ref=%s\n' "$source_ref_value"
        printf 'source_tree_sha256=%s\n' "$source_tree_sha"
        printf 'source_package_version=%s\n' "$version"
        printf 'source_transport=proxmox-git\n'
        printf 'build_recipe=debian-proxmox-patched\n'
        printf 'patch_series_sha256=%s\n' "$patch_series_sha"
        printf 'builder_sha256=%s\n' "$builder_sha"
        printf 'modules_tree_sha256=%s\n' "$modules_sha"
        printf 'module_list_sha256=%s\n' "$module_list_sha"
        printf 'sbat_sha256=%s\n' "$sbat_sha"
        printf 'sbat_source=monolithic/grubx64.efi\n'
        printf 'sbat_template=debian/sbat.proxmox.csv.in\n'
        printf 'sbat_template_sha256=%s\n' "$sbat_template_sha"
        printf 'cli_mode=interactive\n'
        printf 'build_jobs=%s\n' "$JOBS"
        printf 'built_at=%s\n' "$(date -Is)"
    } >"$tmp/profile.env"
    chmod 0600 "$tmp/profile.env"
    # Keep paths relative to the profile root. This makes the manifest
    # self-checking after the temporary profile is atomically renamed to its
    # final location, and prevents an old absolute staging path from becoming
    # unverifiable metadata.
    (
        cd -- "$tmp"
        sha256sum bin/grub-mkstandalone monolithic/grubx64.efi \
            profile.env debian/sbat.proxmox.csv.in
    ) >"$tmp/manifest.sha256"
    chmod 0600 "$tmp/manifest.sha256"
    (cd -- "$tmp" && sha256sum -c --strict manifest.sha256 >/dev/null) ||
        die "GRUB profile manifest self-check failed"

    # Publish atomically. Keep at most one previous profile for recovery;
    # failed builds leave the current profile untouched.  Move the current
    # profile aside first, but restore it if publishing the new tree fails.
    install -d -m 0700 "$BUILD_ROOT"
    local old_current="$BUILD_ROOT/profile.current.old"
    rm -rf -- "$old_current"
    if [[ -e "$PROFILE_ROOT" ]]; then
        mv -- "$PROFILE_ROOT" "$old_current" || die "Unable to stage current GRUB profile"
    fi
    if ! mv -- "$tmp" "$PROFILE_ROOT"; then
        [[ -e "$old_current" ]] && mv -- "$old_current" "$PROFILE_ROOT" || true
        die "Unable to publish GRUB profile"
    fi
    if [[ -e "$old_current" && "$KEEP_PREVIOUS" == 1 ]]; then
        rm -rf -- "$BUILD_ROOT/profile.previous"
        mv -- "$old_current" "$BUILD_ROOT/profile.previous" ||
            die "New GRUB profile published but previous profile could not be retained"
    else
        rm -rf -- "$old_current"
    fi
    log "Published profile: $PROFILE_ROOT"
}

usage() {
    cat <<'EOF'
Usage:
  sb-grub-profile-chroot --build SOURCE_DIR
  sb-grub-profile-chroot --build-auto
  sb-grub-profile-chroot --ensure-auto
  sb-grub-profile-chroot --purge
  sb-grub-profile-chroot --status

--build-auto resolves the installed Proxmox GRUB version from the approved
source ref and requires an exact changelog/version match.  A shared cached
Trixie base is reused, while the /build workspace is disposable and
network-disabled during compilation.  The command never signs or deploys ESP
files and never copies Secure Boot keys.
EOF
}

build_profile() {
    local source="$1" root="" tmp="" export_dir="" source_tmp=""
    local source_deb_version="" source_upstream_version=""
    [[ "$(id -u)" -eq 0 ]] || die "Run as root"
    validate_paths
    for cmd in awk chown cp date df env find findmnt git grep install mktemp mv rm sed sha256sum sort tar umount curl; do need "$cmd"; done
    [[ -x "$BUILD_ROOT_HELPER" ]] || die "Missing shared build-root helper: $BUILD_ROOT_HELPER"

    install -d -m 0700 -o root -g root "$BUILD_ROOT"
    if [[ "${SB_GUARD_LOCK_HELD:-0}" != 1 ]]; then
        exec 7>"$GLOBAL_LOCK_FILE"
        flock -w 300 7 || die "Timed out waiting for global sb-guard lock"
        export SB_GUARD_LOCK_HELD=1
    fi
    exec 9>"$LOCK_FILE"
    flock -w 1800 9 || die "Timed out waiting for GRUB profile build lock"
    exec 8>"$BUILD_ROOT_LOCK_FILE"
    flock -w 1800 8 || die "Timed out waiting for shared build-root lock"
    export SB_BUILD_ROOT_LOCK_HELD=1
    cleanup() {
        local rc=$?
        if [[ -x "$BUILD_ROOT_HELPER" && -d "$BUILD_BASE_ROOT" ]]; then
            "$BUILD_ROOT_HELPER" --clean >/dev/null 2>&1 || true
        fi
        [[ -z "${tmp:-}" || ! -e "${tmp:-}" ]] || rm -rf --one-file-system "$tmp" 2>/dev/null || true
        [[ -z "${export_dir:-}" || ! -e "${export_dir:-}" ]] || rm -rf --one-file-system "$export_dir" 2>/dev/null || true
        cleanup_stale_build_artifacts 2>/dev/null || true
        return "$rc"
    }
    trap cleanup EXIT
    trap 'exit 130' INT TERM

    # Recover from a previous interrupted build before creating a new one.
    cleanup_stale_build_artifacts

    if [[ "$source" == --auto ]]; then
        source_tmp="$(prepare_proxmox_source)"
        source="$source_tmp"
    else
        [[ "$source" = /* ]] || source="$(cd -- "$source" && pwd -P)"
        [[ -d "$source" ]] || die "Source directory does not exist: $source"
    fi
    check_source "$source"
    root="$BUILD_BASE_ROOT"
    tmp="$(mktemp -d -p "$BUILD_ROOT" .profile.XXXXXX)"
    export_dir="$(mktemp -d -p "$BUILD_ROOT" .export.XXXXXX)"

    log "Using shared cached Debian $SUITE build root"
    create_chroot "$root"
    copy_source_into_chroot "$source" "$root"
    log "Building with an empty network namespace"
    source_deb_version="$(cd "$source" && source_version)"
    source_upstream_version="${source_deb_version%%-*}"
    run_build_no_network "$root" "$export_dir" "$source_deb_version" "$source_upstream_version"
    [[ -x "$export_dir/bin/grub-mkstandalone" &&
        -s "$export_dir/monolithic/grubx64.efi" ]] || {
        log "Build output missing after chroot; retained tree for diagnosis: $root"
        find "$root/build" -maxdepth 5 -type f -printf '%p\n' 2>/dev/null | sort >&2 || true
        die "GRUB build did not export its verified output"
    }
    publish_profile "$export_dir" "$source" "$tmp"
    trap - EXIT INT TERM
    cleanup
}

purge_profiles() {
    [[ "$(id -u)" -eq 0 ]] || die "Run as root"
    if [[ "${SB_GUARD_LOCK_HELD:-0}" != 1 ]]; then
        exec 7>"$GLOBAL_LOCK_FILE"
        flock -w 300 7 || die "Timed out waiting for global sb-guard lock"
        export SB_GUARD_LOCK_HELD=1
    fi
    exec 9>"$LOCK_FILE"
    flock -w 1800 9 || die "Timed out waiting for GRUB profile build lock"
    exec 8>"$BUILD_ROOT_LOCK_FILE"
    flock -w 1800 8 || die "Timed out waiting for shared build-root lock"
    exec 6>"$SHIM_LOCK_FILE"
    flock -w 1800 6 || die "Timed out waiting for shim build lock"
    cleanup_stale_build_artifacts
    rm -rf -- "$BUILD_ROOT/.chroot."* "$BUILD_ROOT/.testchroot."* "$BUILD_ROOT/.profile."* \
        "$BUILD_ROOT/.export."* \
        "$BUILD_ROOT/.source."* "$BUILD_ROOT/profile.previous" "$PROFILE_ROOT" \
        "$SOURCE_CACHE_ROOT"
    log "Removed generated roots and profiles under $BUILD_ROOT"
}

status() {
    if [[ -s "$PROFILE_ROOT/profile.env" ]]; then
        printf 'profile=%s\n' "$PROFILE_ROOT"
        sed -n '1,20p' "$PROFILE_ROOT/profile.env"
    else
        printf 'profile=absent\n'
    fi
}

main() {
    local action="" source=""
    while (( $# > 0 )); do
        case "$1" in
            --build) [[ $# -ge 2 ]] || die "--build requires SOURCE_DIR"; action=build; source="$2"; shift 2 ;;
            --build-auto) action=build-auto; shift ;;
            --ensure-auto) action=ensure-auto; shift ;;
            --purge) action=purge; shift ;;
            --status) action=status; shift ;;
            -h|--help) usage; exit 0 ;;
            *) die "Unknown argument: $1" ;;
        esac
    done
    validate_paths
    case "$action" in
        build) build_profile "$source" ;;
        build-auto) build_profile --auto ;;
        ensure-auto)
            if profile_is_current; then
                log "Existing reproducible GRUB profile matches installed package"
            else
                build_profile --auto
            fi
            ;;
        purge) purge_profiles ;;
        status) status ;;
        *) usage >&2; exit 2 ;;
    esac
}

main "$@"
