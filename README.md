# Proxmox VE 9: Full Disk Encryption + custom-only Secure Boot

**English**

Strazh prepares Debian 13 (Trixie) and Proxmox VE 9 with full-disk encryption
and a custom-only Secure Boot chain. The firmware trusts only the operator's
own `PK`, `KEK` and `db` certificates. Microsoft, Debian and Proxmox signing
certificates are not added to the firmware DB.

## License

Strazh is released under the GNU General Public License, version 3 or later.
See [LICENSE](LICENSE). This license applies to the original Strazh files;
third-party tools, Debian/Proxmox sources and firmware components retain their
respective licenses.

## Security profile

```text
Full Disk Encryption: LUKS2 + PBKDF2 (GRUB-compatible unlock slot)
Secure Boot chain:    custom PK / KEK / db only
ESP contents:         /EFI/proxmox/shimx64.efi
                      /EFI/proxmox/grubx64.efi
ESP state:            read-only except for a controlled deploy window
```

The production chain provides:

- custom-only firmware DB: only EFI images signed by our `db.crt` are accepted;
- exactly one Authenticode signature on shim, GRUB and kernels;
- Proxmox-patched GRUB built from the source matching the installed package;
- an embedded GRUB stub with the GPG trust root and signature enforcement;
- GPG verification of `grub.cfg`, kernels, initrds and GRUB runtime modules;
- atomic ESP deployment, strict pins and one verified rollback copy;
- one serialized worker for APT events, reconciliation and rollback.

## Important warning

The installer changes disk layout, LUKS slots, UEFI variables and the ESP.
Keep a tested backup, the LUKS credentials and an accessible physical or remote
firmware console. Losing the private Secure Boot keys or the LUKS credentials
can make the system unbootable.

Secure Boot must remain disabled until Strazh has prepared the custom chain and
the public enrollment files have been imported into firmware. Do not reboot
with custom-only EFI files before enrolling `db.crt`.

## Requirements

- Debian 13 (Trixie) netinst, installed in UEFI/GPT mode;
- root access and a mounted FAT32 ESP at `/boot/efi`;
- a Debian installation with encrypted LVM and a root LUKS2 container;
- network access for the initial package and source downloads;
- at least 4 GB free space for the cached build root and compilation.

The installer targets x86_64 UEFI systems with GOP. Legacy BIOS/CSM, non-x86
architectures and firmware without GOP require a separate platform profile.

## Quick start

Install a minimal Debian 13 system first. Keep firmware Secure Boot disabled,
then run the single public entry point as `root`:

```bash
git clone https://github.com/m0nokey/strazh.git /root/strazh
cd /root/strazh
bash ./run.sh
```

The first launch shows the menu. Choose `6` to let Strazh select the next
pending stage automatically, or select one stage explicitly. On every later
launch, the same `bash ./run.sh` command reads the saved state and continues
from the first incomplete stage. Use `bash ./run.sh --menu` only when manual
stage selection is needed.

The installer does not require a separate `strazh` source file. The host
administration utility is embedded in `run.sh`; during installation Strazh
validates it and installs a copy at `/usr/local/sbin/strazh`.

## Installer menu

```text
Strazh — FDE + Proxmox VE + custom-only Secure Boot

1. Setup Full Disk Encryption
   LUKS2/PBKDF2 · move /boot into the encrypted root filesystem
2. Install Proxmox VE
   Install the PVE kernel and complete the Proxmox VE packages
3. Setup Secure Boot
   Install sb-guard · prepare custom PK/KEK/db enrollment
4. Finalize Secure Boot
   Build, verify and deploy the signed GRUB and shim
5. Installation Status
   Show completed stages and the next required action
6. Continue Installation Automatically
   Resume pending stages after reboot or interruption

x. Exit

?:
```

The normal screen shows one line per substep. Full compiler and APT output is
kept in `/var/log/strazh/pipeline/`; use `bash ./run.sh --debug` only when
diagnosing a failure.

## Expected installation flow

### 1. Full Disk Encryption

Strazh detects the root LUKS device, asks for the existing root LUKS
passphrase, creates or verifies a GRUB-compatible LUKS2/PBKDF2 slot, moves
`/boot` into the encrypted root filesystem, configures the keyfile and rebuilds
the initramfs and GRUB. A preflight verifies the layout before the reboot.

The old plaintext `/boot` partition is wiped and removed only after the copied
tree, mounts, initramfs and GRUB checks succeed. The screen ends with:

```text
REBOOT REQUIRED
FDE is complete; reboot is required before Proxmox VE installation.
Reboot now? [y/n]
```

Answer `y` to reboot or `n` to stop safely. The state is already saved.

### 2. Proxmox VE

After reboot into Debian, run the same command again:

```bash
cd /root/strazh
bash ./run.sh
```

The state machine installs the Proxmox kernel and required packages while
Secure Boot is still disabled. It verifies the new kernel and initramfs, asks
for a reboot, and then completes the Proxmox package stage after booting the
`*-pve` kernel.

### 3. Secure Boot preparation

Strazh installs the prerequisites and lifecycle, creates or reuses the cached
Debian Trixie build root, resolves the exact Proxmox GRUB source commit for the
installed package, and builds the matching GRUB profile. It then creates or
reuses the local PK/KEK/db keys and the GPG trust root, builds a custom shim,
signs the EFI images and performs strict PE, SBAT, module and GPG checks.

On a clean host this stage normally takes **5–15 minutes**. The first run
downloads the build root and dependencies; later releases reuse that cache.
Private keys never enter the chroot or the ESP.

The stage prepares this public enrollment bundle and pauses:

```text
/boot/efi/EFI/SB/KeyTool.efi
/boot/efi/EFI/SB/ENROLL/PK.auth
/boot/efi/EFI/SB/ENROLL/KEK.auth
/boot/efi/EFI/SB/ENROLL/db.auth
```

Fallback `.cer` and `.der` certificate files are also exported for firmware
that does not accept the `.auth` files directly.

### 4. Firmware enrollment

Reboot into the UEFI firmware UI, launch:

```text
\EFI\SB\KeyTool.efi
```

Enroll `PK.auth`, `KEK.auth` and `db.auth` in that order, or use the public
fallback certificate files when required by the firmware. Enable custom Secure
Boot, boot Debian, and run `bash ./run.sh` again. Strazh checks the firmware DB
before continuing; it does not assume enrollment from a marker file.

### 5. Final production release

After `db.crt` is detected in firmware, the saved state continues the release:
the verified GRUB and shim bytes are atomically copied to
`/EFI/proxmox/`, the old Debian EFI tree is retired, NVRAM is reconciled,
the ESP is returned to read-only mode, and the complete verification is run.
The final result must be:

```text
RESULT: OK (full)
```

The exact verified release bundle is kept at:

```text
/var/lib/sb-guard/release/shimx64.efi
/var/lib/sb-guard/release/grubx64.efi
```

## Reboots and recovery

The installer asks before every required reboot and prints what has completed,
what remains and what to do after the reboot. No temporary systemd resume unit
is required: state is stored in `/var/lib/strazh/pipeline.state`, and rerunning
`bash ./run.sh` resumes safely after a reboot, interruption or SSH disconnect.

The permanent `sb-guard.service`, `sb-guard.path` and `sb-guard.timer` are not
resume helpers. They protect later APT/kernel/shim updates after Secure Boot
enrollment and remain installed as the host security lifecycle.

Useful installer modes:

```bash
bash ./run.sh --fde
bash ./run.sh --proxmox
bash ./run.sh --secure-boot
bash ./run.sh --secure-boot-install-only
bash ./run.sh --release
bash ./run.sh --resume
bash ./run.sh --status
bash ./run.sh --debug
```

## Host administration utility

After installation, use the embedded and exported `strazh` command. It remains
available even if `/root/strazh` is later removed:

```bash
strazh
strazh --status
strazh --change-fde-passphrase
strazh --verify
strazh --reconcile
strazh --restore
```

The interactive host menu contains only administrative operations:

```text
Strazh — host administration

1. Show System Status
   Display the saved Strazh pipeline state
2. Change FDE Passphrase
   Replace the human LUKS unlock phrase with confirmation and verification
3. Verify Secure Boot
   Run strict ESP, signature, SBAT and GPG verification
4. Reconcile Boot Files
   Build, verify and atomically deploy the approved boot set
5. Restore Last Known-good Boot Set
   Restore the verified rollback copy after a failed update

x. Exit

?:
```

Status and error screens wait for `Enter` or `Space` before returning to the
menu. Unknown keys are ignored.

### Changing the FDE passphrase

`strazh --change-fde-passphrase` verifies the current passphrase, requests the
new passphrase twice, asks for explicit confirmation and calls
`cryptsetup luksChangeKey`. It replaces one matching human keyslot; it does not
add a new slot. The old passphrase is removed from that slot, while the root
keyfile slot remains untouched and is tested afterward. If the old phrase is
present in another slot, Strazh reports it instead of deleting that slot.

## Build and update model

Production GRUB is never built with an unpatched upstream `configure && make`.
The resolver obtains the Proxmox source commit whose `debian/changelog` matches
the installed `grub-efi-amd64-bin` version, applies the Debian quilt patch
stack, and builds the x86_64 EFI image in the shared cached Trixie root. Shim is
built from the matching Proxmox source using the installed `shim-unsigned`
version and hash as the input signal. Signing happens outside the chroot; the
private `db.key` is never copied into it.

The shared build root is reusable:

```bash
/usr/local/sbin/sb-build-root --status
/usr/local/sbin/sb-build-root --purge
```

Only temporary `/build` workspaces are removed after a build. The verified
source cache and APT cache remain for the next release.

After an APT update, the lightweight hook records an event. A single worker
waits for `dpkg`, rebuilds only when the installed package version or hash
changes, verifies the new artifacts, saves one rollback copy, and performs an
atomic ESP deployment. Pins are updated only after the final full verification.

Manual maintenance commands:

```bash
/usr/local/sbin/sb-guard-svc --verify
/usr/local/sbin/sb-guard-svc --fix-all
/usr/local/sbin/sb-guard-rollback --verify
/usr/local/sbin/sb-guard-rollback --restore
```

## Installed components

The public project contains one entry point and private implementation files:

```text
run.sh                         # menu, state machine and embedded host utility
lib/fde_debian_net_install.sh  # Debian FDE implementation
lib/sb_proxmox.sh              # Proxmox package/kernel stage
lib/sb_guard_install.sh        # sb-guard lifecycle installer
lib/sb_build_root.sh            # cached Trixie build root
lib/sb_grub_profile_chroot.sh   # source-matched GRUB builder
lib/sb_shim_auto_build.sh       # package-version shim resolver
lib/sb_shim_build_custom.sh     # custom shim build orchestration
lib/sb_shim_source_chroot.sh    # isolated shim source builder
README.md                       # English documentation
```

The installer exports the host and Secure Boot commands under
`/usr/local/sbin/`, including `strazh`, `sb-guard`, `sb-guard-svc`,
`sb-guard-worker`, `sb-guard-event`, `sb-guard-rollback`, `sb-install`, the
shim builders and the shared build-root helper. Private keys are generated
only on the target host under `/var/lib/sb-guard/keys` and are excluded from
Git.

## Boot and threat model

```text
UEFI custom PK/KEK/db
  -> custom-signed shim
  -> custom-signed GRUB
  -> embedded GPG trust root and enforced grub.cfg signatures
  -> LUKS2/PBKDF2 unlock
  -> signed kernel and GPG-verified initramfs
  -> Linux userspace
```

The design protects against replacement of shim, GRUB, kernels, initrds and
GRUB runtime files on disk or the ESP, and against ordinary APT-triggered
deployment races. Secure Boot does not protect a compromised running root,
firmware vulnerabilities, physical replacement of the machine's firmware, or
disclosure of the LUKS passphrase/private signing keys.

The ESP contains public boot artifacts only and is normally mounted
`ro,nosuid,nodev,noexec,noatime`. `/boot` is inside the encrypted root after
the FDE stage. The firmware DB contains only the custom certificates selected
by the operator; automatic `dbx` revocation updates are intentionally outside
the pipeline.

## Verification checklist

```bash
strazh --status
strazh --verify
findmnt -no SOURCE,FSTYPE,OPTIONS /boot/efi
lsblk -o NAME,FSTYPE,MOUNTPOINTS
systemctl status sb-guard.path sb-guard.timer
```

The expected final state is `phase=complete`, all pipeline stages complete,
`secure_boot=enabled`, and `RESULT: OK (full)` from the strict verifier.
