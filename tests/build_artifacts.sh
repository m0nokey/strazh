#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build and verify disposable GRUB/shim artifacts in Debian Trixie.
#
# This script is intentionally run only in a privileged, disposable CI
# container. It never uses production keys and never mounts or writes an ESP.
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

[[ "$(id -u)" -eq 0 ]] || {
    printf '%s\n' 'Artifact build must run as root inside the CI container' >&2
    exit 1
}

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd -- "$ROOT_DIR"
export DEBIAN_FRONTEND=noninteractive
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-946684800}"

# The minimal Debian image has no CA bundle before its first package
# transaction. Bootstrap only ca-certificates over the image's official Debian
# HTTP mirror, then switch every subsequent operation to HTTPS. The production
# helpers reject plaintext Debian mirrors; this is the narrow bootstrap
# exception needed to establish TLS trust in a blank container.
if [[ -f /etc/apt/sources.list.d/debian.sources ]]; then
    sed -i \
        -e 's|https://deb.debian.org/debian|http://deb.debian.org/debian|g' \
        -e 's|https://security.debian.org/debian-security|http://security.debian.org/debian-security|g' \
        /etc/apt/sources.list.d/debian.sources
fi

apt-get update
apt-get install -y --no-install-recommends ca-certificates

if [[ -f /etc/apt/sources.list.d/debian.sources ]]; then
    sed -i \
        -e 's|http://deb.debian.org/debian|https://deb.debian.org/debian|g' \
        -e 's|http://security.debian.org/debian-security|https://security.debian.org/debian-security|g' \
        /etc/apt/sources.list.d/debian.sources
fi

apt-get update
apt-get install -y --no-install-recommends \
    curl gnupg gpgv git dpkg-dev mmdebstrap \
    binutils openssl sbsigntool util-linux xz-utils

# Reuse the exact key URL, digest and fingerprint enforced by the production
# installer instead of duplicating those values in this test.
key_url="$(sed -n 's/^readonly PVE_KEY_URL="\(.*\)"$/\1/p' lib/sb_proxmox.sh)"
key_sha="$(sed -n 's/^readonly PVE_KEY_SHA256="\(.*\)"$/\1/p' lib/sb_proxmox.sh)"
key_fingerprint="$(sed -n 's/^readonly PVE_KEY_FINGERPRINT="\(.*\)"$/\1/p' lib/sb_proxmox.sh)"
repo_uri="$(sed -n 's/^PVE_REPO_URI="${PVE_REPO_URI:-\(.*\)}"$/\1/p' lib/sb_proxmox.sh)"
[[ "$key_url" == https://* && "$key_sha" =~ ^[[:xdigit:]]{64}$ ]] || exit 1
[[ "$key_fingerprint" =~ ^[[:xdigit:]]{40}$ ]] || exit 1
[[ "$repo_uri" == http://download.proxmox.com/debian/pve ]] || exit 1

test_root="$(mktemp -d -p /tmp strazh-artifacts.XXXXXX)"
cleanup() { rm -rf --one-file-system "$test_root"; }
trap cleanup EXIT
install -d -m 0700 /etc/apt/keyrings /var/lib/sb-guard/keys

curl -4 -fsSL --proto '=https' --tlsv1.3 --retry 5 \
    --connect-timeout 15 --max-time 90 "$key_url" -o "$test_root/proxmox-key.gpg"
[[ "$(sha256sum "$test_root/proxmox-key.gpg" | awk '{print $1}')" == "$key_sha" ]]
install -d -m 0700 "$test_root/gnupg"
fingerprints="$(gpg --batch --no-options --homedir "$test_root/gnupg" \
    --with-colons --import-options show-only --import "$test_root/proxmox-key.gpg" \
    2>/dev/null | awk -F: '$1 == "fpr" { print toupper($10) }')"
grep -Fqx "$key_fingerprint" <<<"$fingerprints"
gpg --batch --no-options --yes --dearmor \
    --output /etc/apt/keyrings/proxmox-release-trixie.gpg "$test_root/proxmox-key.gpg"

cat >/etc/apt/sources.list.d/proxmox-ci.sources <<EOF
Types: deb
URIs: $repo_uri
Suites: trixie
Components: pve-no-subscription
Architectures: amd64
Signed-By: /etc/apt/keyrings/proxmox-release-trixie.gpg
EOF
# Verify the repository's clearsigned InRelease explicitly as well as through
# APT. The download endpoint is the documented HTTP no-subscription exception;
# authenticity comes from the pinned keyring, not from an unverified archive.
curl -4 -fsSL --retry 5 --connect-timeout 15 --max-time 90 \
    "$repo_uri/dists/trixie/InRelease" -o "$test_root/proxmox-InRelease"
gpgv --keyring /etc/apt/keyrings/proxmox-release-trixie.gpg \
    "$test_root/proxmox-InRelease" >/dev/null
apt-get update
apt-get install -y --no-install-recommends grub-efi-amd64-bin shim-unsigned

# Install the implementation helpers exactly where Stage 03 installs them.
install -m 0750 lib/sb_build_root.sh /usr/local/sbin/sb-build-root
install -m 0750 lib/sb_grub_profile_chroot.sh /usr/local/sbin/sb-grub-profile-chroot
install -m 0750 lib/sb_shim_source_chroot.sh /usr/local/sbin/sb-shim-source-chroot
install -m 0750 lib/sb_shim_build_custom.sh /usr/local/sbin/sb-shim-build-custom
install -m 0750 lib/sb_shim_auto_build.sh /usr/local/sbin/sb-shim-auto-build

# CI-only signing material. The private key stays in the disposable container
# and is removed by cleanup; it is never an input to the build root.
openssl req -new -x509 -newkey rsa:2048 -nodes -days 1 \
    -subj '/CN=sb-guard db CI' \
    -keyout /var/lib/sb-guard/keys/db.key \
    -out /var/lib/sb-guard/keys/db.crt >/dev/null 2>&1
chmod 0400 /var/lib/sb-guard/keys/db.key

printf '%s\n' 'Building GRUB profile (first reproducibility pass)...'
SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
    /usr/local/sbin/sb-grub-profile-chroot --build-auto
cp -a /var/lib/sb-guard/grub-build/profile/monolithic/grubx64.efi \
    "$test_root/grub-one.efi"

# Removing only the published profile forces a second build while retaining
# the verified immutable source cache. The build-root helper will reuse its
# dependency root and still clean the disposable /build workspace.
rm -rf --one-file-system /var/lib/sb-guard/grub-build/profile
printf '%s\n' 'Building GRUB profile (second reproducibility pass)...'
SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
    /usr/local/sbin/sb-grub-profile-chroot --build-auto
cmp -s "$test_root/grub-one.efi" \
    /var/lib/sb-guard/grub-build/profile/monolithic/grubx64.efi

# Recreate the production embedded-stub operation with the isolated profile:
# the public GPG key and signed config are grafted into GRUB before PE signing.
export GNUPGHOME="$test_root/gnupg-sign"
install -d -m 0700 "$GNUPGHOME"
gpg --batch --passphrase '' --quick-gen-key \
    'Strazh CI GPG <ci@example.invalid>' rsa2048 sign 1d >/dev/null
gpg_id="$(gpg --batch --with-colons --list-secret-keys \
    | awk -F: '$1 == "sec" { print $5; exit }')"
[[ "$gpg_id" =~ ^[[:xdigit:]]{16,40}$ ]]
gpg --batch --export "$gpg_id" >"$test_root/sb-guard.gpg"
cat >"$test_root/grub-early.cfg" <<'EOF'
set check_signatures=enforce
export check_signatures
EOF
gpg --batch --yes --pinentry-mode loopback --passphrase '' \
    --local-user "$gpg_id" --digest-algo SHA512 \
    --detach-sign --output "$test_root/grub-early.cfg.sig" "$test_root/grub-early.cfg"
gpg --batch --verify "$test_root/grub-early.cfg.sig" "$test_root/grub-early.cfg" \
    >/dev/null 2>&1
objcopy --dump-section .sbat="$test_root/profile.sbat" \
    /var/lib/sb-guard/grub-build/profile/monolithic/grubx64.efi \
    "$test_root/profile-copy.efi" >/dev/null
profile_modules=/var/lib/sb-guard/grub-build/profile/lib/grub/x86_64-efi
embedded_modules='part_gpt cryptodisk luks2 lvm ext2 gcry_rijndael gcry_sha256 gcry_rsa pgp configfile search linux normal efi_gop'
/var/lib/sb-guard/grub-build/profile/bin/grub-mkstandalone \
    --directory="$profile_modules" --format=x86_64-efi \
    --output="$test_root/grub-embedded.unsigned.efi" --compress=xz \
    --install-modules="$embedded_modules" --modules="$embedded_modules" \
    --pubkey="$test_root/sb-guard.gpg" --sbat="$test_root/profile.sbat" \
    "boot/grub/grub.cfg=$test_root/grub-early.cfg" \
    "boot/grub/grub.cfg.sig=$test_root/grub-early.cfg.sig" >/dev/null
grep -aFq 'check_signatures=enforce' "$test_root/grub-embedded.unsigned.efi"
sbsign --key /var/lib/sb-guard/keys/db.key \
    --cert /var/lib/sb-guard/keys/db.crt \
    --output "$test_root/grub-embedded.signed.efi" \
    "$test_root/grub-embedded.unsigned.efi" >/dev/null
sbverify --cert /var/lib/sb-guard/keys/db.crt \
    "$test_root/grub-embedded.signed.efi" >/dev/null
[[ "$(sbverify --list "$test_root/grub-embedded.signed.efi" 2>/dev/null \
    | grep -cE '^signature[[:space:]]+[0-9]+$' || true)" == 1 ]]

# Sign a copy of the deterministic unsigned GRUB and require exactly one CI
# signature from our ephemeral db certificate.
sbsign --key /var/lib/sb-guard/keys/db.key \
    --cert /var/lib/sb-guard/keys/db.crt \
    --output "$test_root/grub-signed.efi" \
    /var/lib/sb-guard/grub-build/profile/monolithic/grubx64.efi >/dev/null
sbverify --cert /var/lib/sb-guard/keys/db.crt "$test_root/grub-signed.efi" >/dev/null
[[ "$(sbverify --list "$test_root/grub-signed.efi" 2>/dev/null \
    | grep -cE '^signature[[:space:]]+[0-9]+$' || true)" == 1 ]]
objcopy --dump-section .sbat="$test_root/grub.sbat" "$test_root/grub-signed.efi" \
    "$test_root/grub-copy.efi" >/dev/null
[[ -s "$test_root/grub.sbat" ]]

printf '%s\n' 'Building custom shim from the exact installed Proxmox source...'
SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
    /usr/local/sbin/sb-shim-auto-build --force
shim_source="$(find /var/lib/sb-guard/source-cache/shim -mindepth 1 -maxdepth 1 \
    -type d -name '*-*' -print -quit)"
[[ -n "$shim_source" && -d "$shim_source/.git" ]]
SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
    /usr/local/sbin/sb-shim-source-chroot "$shim_source" \
    /var/lib/sb-guard/keys/db.crt "$test_root/shim-one.unsigned.efi"
SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
    /usr/local/sbin/sb-shim-source-chroot "$shim_source" \
    /var/lib/sb-guard/keys/db.crt "$test_root/shim-two.unsigned.efi"
cmp -s "$test_root/shim-one.unsigned.efi" "$test_root/shim-two.unsigned.efi"
custom_shim=/var/lib/sb-guard/custom-shim/shimx64.efi
sbverify --cert /var/lib/sb-guard/keys/db.crt "$custom_shim" >/dev/null
[[ "$(sbverify --list "$custom_shim" 2>/dev/null \
    | grep -cE '^signature[[:space:]]+[0-9]+$' || true)" == 1 ]]

printf '%s\n' 'ARTIFACT_BUILD_OK (GRUB/shim source builds, signatures, SBAT and reproducibility verified)'
