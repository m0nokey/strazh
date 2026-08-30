# Proxmox VE 9: Full Disk Encryption + custom-only Secure Boot

Strazh prepares Debian 13 (Trixie) and Proxmox VE 9 with full-disk encryption
and a custom-only Secure Boot chain. The firmware trusts only the operator's
own `PK`, `KEK` and `db` certificates. Microsoft, Debian and Proxmox signing
certificates are not added to the firmware DB.

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
- at least 4 GB free space for the cached build root and compilation;
- at least 4 GiB RAM, or 2 GiB RAM plus 2 GiB swap, for the Proxmox package
  transaction.

The installer targets x86_64 UEFI systems with GOP. Legacy BIOS/CSM, non-x86
architectures and firmware without GOP require a separate platform profile.

## Install Debian netinst first

Strazh is not a Debian ISO installer. Start with a clean Debian 13 (Trixie)
netinst installation, then run Strazh on the installed system.

Boot the installer in UEFI mode on a GPT disk. Keep firmware Secure Boot
disabled during installation; the custom certificates are enrolled later.
In Debian Installer use these exact screens and choices:

1. `Configure the network` → `Hostname`: enter the hostname for this server.
2. In `Set up users and passwords`:
   - at `Root password:`, enter the password for the `root` account;
   - at `Re-enter password to verify:`, enter the same root password;
   - at `Create a normal user account now?`, choose `No`.
3. Under `Partition disks`, choose `Guided - use entire disk and set up encrypted LVM`.
4. Select the target system disk.
5. Choose `All files in one partition (recommended for new users)`.
6. When prompted for the encryption passphrase, enter it and confirm it.
7. Choose `Finish partitioning and write changes to disk`, then confirm
   `Write the changes to disks?` with `Yes`.
8. In `Software selection`, select only:

   ```text
   [x] SSH server
   [x] standard system utilities
   [ ] every other task
   ```

9. When prompted `Install the GRUB boot loader`, choose `Yes`.
10. At `Device for boot loader installation`, choose the target system disk so
    GRUB is installed to that disk's UEFI System Partition.

This is a root-only base installation: `Create a normal user account now?` is
answered `No`, so no ordinary login user is created. Add one later with
`adduser` only if the host needs a separate day-to-day account.

`All files in one partition` creates one root LV inside the encrypted LVM;
swap is created as a separate LV. Separate `/home`, `/var` and `/tmp`
partitions are not required. Keeping one root filesystem makes it possible for
Stage 1 to move `/boot` into the encrypted root.

After the first Debian boot, verify that networking works, that you have a root
shell, and that the FAT32 ESP is mounted at `/boot/efi`. Debian Installer may
leave `/boot` as a separate plaintext partition; this is expected before Stage
1. Strazh copies it into the encrypted root, verifies the new layout and only
then removes the old partition.

## Quick start

Install a minimal Debian 13 system first. Keep firmware Secure Boot disabled,
then run the single public entry point as `root`:

With Git:

```bash
git clone https://github.com/m0nokey/strazh.git /root/strazh \
&& cd /root/strazh \
&& bash ./run.sh
```

Without Git:

```bash
install -d -m 0700 /root/strazh \
&& curl -fsSL https://github.com/m0nokey/strazh/archive/refs/heads/main.tar.gz | tar -xz --strip-components=1 -C /root/strazh \
&& cd /root/strazh \
&& bash ./run.sh
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
the initramfs and GRUB. Before the stage is marked ready, Strazh asks for the
human passphrase again and tests it with `cryptsetup --test-passphrase` (no
mapper is created), then verifies the keyfile unlock as well. A preflight
verifies the layout before the reboot.

The old plaintext `/boot` partition is wiped and removed only after the copied
tree, mounts, initramfs and GRUB checks succeed. The screen ends with:

```text
REBOOT REQUIRED
FDE is complete; reboot is required before Proxmox VE installation.
Reboot now? [y/n]
```

Answer `y` to reboot or `n` to stop safely. The state is already saved.
The reboot is required even when both unlock tests pass: it verifies the real
firmware → GRUB → LUKS → initramfs path before Proxmox packages are installed.

#### Verifying the encrypted boot layout

After the FDE stage, `/boot` must no longer be a separate partition. The root
filesystem, `/boot`, all kernels, initrds, GRUB configuration and GRUB runtime
modules are on the LUKS-backed root LV. Linux kernel modules under
`/lib/modules/<version>/` are on the same encrypted root filesystem.

For example, a completed layout looks like this:

```text
NAME                    FSTYPE      MOUNTPOINTS
sda
├─sda1                  vfat        /boot/efi
└─sda3                  crypto_LUKS
  └─sda3_crypt          LVM2_member
    ├─debian--vg-root   ext4        /
    └─debian--vg-swap_1 swap        [SWAP]
```

The only unencrypted filesystem is the ESP required by UEFI. It contains
public, custom-signed bootloaders only:

```text
/boot/efi/EFI/proxmox/
├── grubx64.efi
└── shimx64.efi
```

Verify the mount ownership and encrypted payload with:

```bash
lsblk -o NAME,FSTYPE,MOUNTPOINTS
findmnt -T /boot -o SOURCE,FSTYPE,TARGET,OPTIONS
findmnt -T /lib/modules -o SOURCE,FSTYPE,TARGET,OPTIONS
findmnt -T /boot/efi -o SOURCE,FSTYPE,TARGET,OPTIONS
ls -l /boot/vmlinuz-* /boot/initrd.img-*
find /lib/modules -type f -name '*.ko*' -print | head
cryptsetup luksDump /dev/sda3
```

`/boot` and `/lib/modules` must resolve to the mapped root LV, while
`/boot/efi` resolves to the small FAT32 ESP. `luksDump` must report LUKS2 and
the GRUB-compatible PBKDF2 keyslot. This is full disk encryption for the
operating-system payload: the ESP remains plaintext by UEFI design, and its
integrity is enforced by the custom-only Secure Boot signatures.

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

The Proxmox APT bootstrap keyring is downloaded only from the official HTTPS
endpoint. Before it is installed, Strazh requires both the pinned SHA-256
(`136673be77aba35dcce385b28737689ad64fd785a797e57897589aed08db6e45`) and the
published Trixie release-key fingerprint
(`24B30F06ECC1836A4E5EFECBA7BCD1420BFE778E`). A mismatch stops the installation
before APT can use the key. Updating the key requires an explicit source change
and review.

There is no Proxmox-published signed manifest that maps package versions to Git
commits. Strazh therefore uses the strongest available binding: the installed
package version is matched to the official GitWeb changelog entry, the exact
40-character commit is fetched from the pinned Proxmox HTTPS repository, and
the source tree, Debian patch series, builder, SBAT template and module closure
are hashed into the profile. `profile.env` and its relative-path
`manifest.sha256` are revalidated, and the cached source tree is rehashed before
an existing profile is reused. Shim state applies the same commit, remote/ref
and source-tree checks. These hashes attest to the exact bytes Strazh built;
they are not presented as an upstream Proxmox signature.

During the Proxmox package stage only, the installer temporarily remounts the
ESP read-write so Debian/Proxmox package post-install hooks can update their
transitional loader. The EXIT cleanup always restores the hardened read-only
mount, including after an interrupted or failed package command.

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

## Operational hardening and incident response

Strazh protects the boot chain, but platform and out-of-band management
security must be configured by the operator.

Before production:

- update UEFI/BIOS, BMC/IPMI, RAID, NIC and other device firmware to the
  latest vendor-supported security releases;
- verify vendor signatures or hashes and keep recovery copies;
- set a unique UEFI administrator password;
- disable unused USB, Thunderbolt, external boot and PXE features;
- enable DMA protection/IOMMU where supported;
- place BMC/IPMI on a dedicated management VLAN or VPN;
- restrict BMC access with firewall ACLs and disable public exposure;
- replace default BMC credentials and install a trusted BMC TLS certificate;
- disable unused BMC services, virtual media and IPMI-over-LAN when not
  needed.

BMC/IPMI certificates are a separate trust domain. They are not the Strazh
Secure Boot `PK`, `KEK` or `db` certificates and must not be reused.

During an incident, isolate the BMC network first, preserve BMC and UEFI logs,
and keep a tested physical or remote recovery console available. BMC/IPMI may
remain available while the host operating system is powered off because the
management controller can use standby power; disabling host ports does not
disable the BMC management path. See the [DMTF Redfish
specification](https://www.dmtf.org/sites/default/files/standards/documents/DSP0268_2019.3.pdf)
and [NIST SP 800-147B](https://nvlpubs.nist.gov/nistpubs/specialpublications/nist.sp.800-147b.pdf)
for the out-of-band management model.

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

## License

Strazh is released under the GNU General Public License, version 3 or later.
See [LICENSE](LICENSE). This license applies to the original Strazh files;
third-party tools, Debian/Proxmox sources and firmware components retain their
respective licenses.
