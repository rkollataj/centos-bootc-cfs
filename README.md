# Minimal CentOS Stream 10 bootc — sealed, signed composefs UKI

A minimal [bootc](https://bootc.dev) base image on CentOS Stream 10 using the
experimental **composefs** backend, booted from a **sealed, Secure
Boot-signed UKI** (Unified Kernel Image).

- **Sealed:** the composefs digest of the root filesystem is computed at
  build time, baked into the UKI kernel command line (`composefs=<sha512>`),
  and enforced at boot. If the root fs doesn't match, it won't boot.
- **Signed:** the UKI is signed for Secure Boot with a local key/cert pair,
  generated on first build and gitignored (never committed). See **Secure
  Boot signing**.
- **Transient `/etc`:** `/etc` is a tmpfs overlay
  (`/usr/lib/composefs/setup-root-conf.toml`, `[etc] transient = true`), so
  runtime changes are discarded on reboot. SSH host keys and `machine-id`
  regenerate every boot as a result. Remove `setup-root-conf.toml` for a
  normal persistent `/etc`.
- **Stateless `/var`, persistent `/var/log`:** `/var` is a fresh tmpfs every
  boot (`systemd.volatile=state`). `/var/log` is bind-mounted from the
  writable root partition via a `systemd.mount-extra=` karg, and journald
  uses `Storage=persistent` with `SystemMaxUse=1G`. See **Persistent logs**.
- **Qt demo app:** a fullscreen digital clock (`qtdemo/`), rendered via Qt's
  `eglfs` QPA platform plugin (EGL + DRM/KMS) — no Wayland, no X11, no
  compositor. See **Qt demo app**.

## Prerequisites

### To build the image

- **Podman** (or Docker with buildx).
- **OpenSSL** and **Python 3** on the host — used by `gen-secureboot-keys.sh`
  to generate local Secure Boot keys.
- **Network access at build time** (COPR + EPEL + gpg key fetches).

```sh
sudo apt install podman python3 openssl
```

### To run it as a local VM (`bcvk`)

- **[`bcvk`](https://github.com/bootc-dev/bcvk)** — install a prebuilt binary
  from its [releases page](https://github.com/bootc-dev/bcvk/releases) or via
  `cargo install`.
- **QEMU + libvirt stack**, plus **`python3-virt-firmware`** (provides
  `virt-fw-vars`, which `bcvk --secure-boot-keys` uses to enroll the local
  keys into the VM's firmware):
  ```sh
  sudo apt install qemu-system-x86 qemu-utils libvirt-daemon-system \
      libvirt-clients virtiofsd ovmf dnsmasq-base swtpm virt-viewer \
      python3-virt-firmware
  ```
  (`swtpm` only needed for TPM-measured boot; `virt-viewer` only needed to
  view the Qt demo's graphical output.)
- **Group membership** for `/dev/kvm` and VM management without `sudo`:
  ```sh
  sudo usermod -aG libvirt,kvm $USER
  ```
  Log out and back in for this to take effect (on WSL2: `wsl.exe --shutdown`
  from Windows, then reopen the terminal).
- Rootless `/dev/kvm` access may additionally need `crun` or a udev rule —
  see the note under **Run as a local VM**.

### To install to bare metal / a disk

Just Podman, run privileged with access to `/dev` — see **Install to bare
metal / a disk**. No `bcvk`/libvirt/QEMU needed.

## Build

```sh
./build.sh
```

Runs `gen-secureboot-keys.sh` (generates local Secure Boot keys if missing),
`podman build` with those keys as secrets (also works with Docker/buildx),
then `fix-uki-digest.sh`, which corrects the UKI's embedded composefs digest
and re-signs it (see **Requirements / caveats** and **Secure Boot signing**).
Pass a tag as `./build.sh your/tag:here`. Re-running is safe — both steps
no-op once keys exist / the digest already matches.

## How it works

Mirrors bootc's own maintained sealed-UKI recipe (`seal-uki` / `finalize-uki`,
vendored here from bootc's `contrib/packaging`) rather than the prose docs'
split-then-copy pattern, which produces a build-time vs install-time digest
mismatch. The measured rootfs keeps its kernel in `/usr/lib/modules`; it is
only split out into a throwaway stage to feed `--kernel-dir`.

1. **rootfs** *(measured tree)* — upgrades bootc, swaps `bootupd` →
   `systemd-boot-unsigned`, adds `systemd-ukify`, ships an `rw` kernel arg
   (required — a UKI's cmdline is sealed at build time, so `bootc install`
   can't add `rw` itself as it does for BLS boots), ships
   `setup-root-conf.toml` (transient `/etc`), and regenerates the initramfs
   with the `bootc` (51bootc) dracut module (installs
   `bootc-root-setup.service`, which mounts `/etc` and `/var` at boot).
2. **kernel** — `bootc container split-kernel-and-rootfs` into
   `/kernel/<kver>/`; only that directory is consumed. Never shipped.
3. **sealed-uki** — `seal-uki` runs `bootc container ukify` against the
   measured rootfs, embedding the composefs digest and signing the UKI
   (`--seal-state sealed`) with the `secureboot_key`/`secureboot_cert`
   build secrets.
4. **final** — `FROM rootfs` + `finalize-uki` copies the UKI to
   `/boot/EFI/Linux/` (`/boot` is excluded from the digest). Then
   `bootc container lint`.

## Requirements / caveats

- **Recent bootc.** `container ukify` / `split-kernel-and-rootfs` are
  experimental; the stream10 base image's bootc is too old for them, so the
  build upgrades bootc from the `rhcontainerbot/bootc` COPR. The newer bootc
  also ships in the final image (needed for `bootc upgrade`).
- **Install target needs an fsverity-capable root fs** (ext4 or btrfs) — the
  build is strictly sealed, no `--allow-missing-verity`.
- **`sbsign`, not `ukify`'s built-in `systemd-sbsign`.** `systemd-sbsign`'s
  `verify()` unconditionally raises `NotImplementedError` in this systemd
  version, and `ukify`'s `make_uki()` always calls it — so it can't be used
  to build at all here. `sbsigntools` isn't packaged for CentOS Stream 10
  itself, so the `rootfs` stage pulls it from EPEL 10 (removing
  `epel-release` again afterward, so EPEL isn't enabled in the shipped
  image).
- **Digest mismatch bug, fixed by `fix-uki-digest.sh`.** `bootc container
  ukify` computes its digest via a directory walk of the extracted rootfs;
  `bootc install` verifies against the raw storage/layer-ingest digest. These
  can disagree on some directories' mtimes/modes due to
  `containers/storage`'s overlay extraction — unrelated to image content.
  Zeroing directory mtimes (the `find`/`touch` step at the end of the
  `rootfs` stage — any extra `RUN` you add that creates directories must end
  with the same command) is necessary but not sufficient. Upstream:
  [bootc#2194](https://github.com/bootc-dev/bootc/issues/2194),
  [composefs-rs#132](https://github.com/composefs/composefs-rs/issues/132).
  `--allow-missing-verity` does **not** work around this — the digest-match
  check in `bootc install` is unconditional. `fix-uki-digest.sh` instead
  re-computes the digest via `bootc container compute-composefs-digest-from-storage`
  (the same view `bootc install` uses), patches that value into the built
  UKI, strips the now-invalid signature (via `pefile` — patching content
  invalidates it, and `sbsign` on an already-signed file appends a second
  signature rather than replacing it, which OVMF doesn't reliably accept),
  and re-signs cleanly. `diagnose-digest.sh` compares both digest views for
  debugging.

## Secure Boot signing

`./gen-secureboot-keys.sh` generates a local PK/KEK/db key and cert set
(`secureboot-keys/`, gitignored, never committed) — three independent
self-signed certs, not a real PKI chain; fine for local QEMU/OVMF trust,
not for any real Secure Boot deployment. It's a no-op if
`secureboot-keys/db.key` already exists.

- `db.key`/`db.crt` sign the UKI: `build.sh` passes them to `podman build
  --secret` as `secureboot_key`/`secureboot_cert`, which `seal-uki
  --seal-state sealed` uses.
- `PK.crt`/`KEK.crt`/`db.crt`/`GUID.txt` are enrolled into a VM's firmware
  by `bcvk libvirt run --secure-boot-keys secureboot-keys` (see **Run as a
  local VM**), so that VM's Secure Boot trusts the signed UKI.

Verify the signature directly, independent of booting (`sbverify` only
exists inside the image, so run it via `podman`):

```sh
cid=$(podman create localhost/centos-bootc-composefs:stream10)
podman cp "$cid:/boot/EFI/Linux/$(podman run --rm localhost/centos-bootc-composefs:stream10 sh -c 'ls /boot/EFI/Linux')" /tmp/uki.efi
podman rm -f "$cid"
podman run --rm -v /tmp/uki.efi:/uki.efi:ro -v "$(pwd)/secureboot-keys/db.crt":/db.crt:ro \
  localhost/centos-bootc-composefs:stream10 sbverify --cert /db.crt /uki.efi
```

## Run as a local VM (bcvk)

`--filesystem ext4` is required (fsverity; `xfs`, the default, doesn't
support it). `--secure-boot-keys secureboot-keys` is required so `bcvk`
enrolls the local Secure Boot keys into the VM's firmware (`bcvk`'s default
firmware, `uefi-secure`, otherwise only trusts Microsoft's keys, and this
UKI isn't signed by those — see **Secure Boot signing**).

```sh
bcvk libvirt run --name cfs-test --memory 4096 --cpus 2 \
  --filesystem ext4 --secure-boot-keys secureboot-keys \
  localhost/centos-bootc-composefs:stream10

# re-create (replaces an existing VM of the same name):
bcvk libvirt run --name cfs-test --memory 4096 --cpus 2 \
  --filesystem ext4 --secure-boot-keys secureboot-keys --replace \
  localhost/centos-bootc-composefs:stream10

# manage it afterwards:
virsh --connect qemu:///system list
virsh --connect qemu:///system console cfs-test
virsh --connect qemu:///system destroy cfs-test
virsh --connect qemu:///system undefine --nvram cfs-test   # remove

# shell access (key-based, no setup needed):
bcvk libvirt ssh cfs-test
```

> **`system` vs `session`:** `bcvk`/`virsh` use whichever libvirt connection
> their default-URI probe finds first — `qemu:///system` if the system
> `libvirtd` is active and you're in the `libvirt` group, `qemu:///session`
> otherwise. Pass `--connect` explicitly to force one.

> **Rootless `/dev/kvm` access may need `crun` or a udev rule.** `bcvk` uses
> `--group-add=keep-groups`, honored only by the `crun` OCI runtime. If
> `/dev/kvm` is group-restricted (`ls -l /dev/kvm` shows mode `0660`) and
> `runc` is podman's runtime, either install `crun` and set it as default in
> `~/.config/containers/containers.conf` (`[engine] runtime = "crun"`), or
> make `/dev/kvm` world-accessible:
> ```sh
> echo 'KERNEL=="kvm", GROUP="kvm", MODE="0666"' | \
>     sudo tee /etc/udev/rules.d/65-kvm-world.rules
> sudo udevadm control --reload-rules
> sudo udevadm trigger --name-match=kvm
> ```

> **Secure Boot enforcement may not work in nested virtualization** (e.g.
> WSL2, Codespaces, Azure VMs): OVMF's Secure Boot firmware depends on
> emulated SMM, which is unreliable in nested KVM
> ([bcvk#145](https://github.com/bootc-dev/bcvk/issues/145)). Symptoms range
> from a hard KVM crash to a valid signature being rejected
> (`Access Denied -- rejected probably by Secure Boot`) despite correct
> enrollment. This is independent of this image's signing, which can be
> verified without booting — see **Secure Boot signing**.

`bcvk ephemeral run` boots the container directly over virtiofs, skipping
`bootc install`/UKI/composefs entirely, and attaches no GPU/display device —
useful for a quick shell (`bcvk ephemeral ssh`), not for the sealed boot
chain or the Qt demo's display.

## Qt demo app (eglfs/DRM-KMS, no Wayland/X11)

`qtdemo/` is a small Qt Widgets app (digital clock) built from source in the
Containerfile against `qt6-qtbase-gui`/`qt6-qtbase-devel`; the build
toolchain is removed in the same layer, so only the Qt6 runtime, a font, and
the compiled binary ship. It renders via the `eglfs` QPA platform plugin
(EGL against `/dev/dri/card*`) rather than `linuxfb`, because this kernel
does not expose a `/dev/fb0` device node — only DRM/KMS. On the virtio-gpu
device these VMs get, EGL falls back to Mesa's LLVMpipe software rasterizer.

It runs as `qt-demo.service`, enabled via a symlink under
`/usr/lib/systemd/system/multi-user.target.wants/` (not `systemctl enable`,
which targets `/etc/systemd/system` and wouldn't survive transient `/etc`).
It starts once a `/dev/dri/card*` device exists
(`ConditionPathExistsGlob=`), and conflicts with `getty@tty1` so the two
don't share the console.

Viewing it requires a graphical QEMU display — the serial console
(`console=ttyS0`, `virsh console`) only carries text:

```sh
bcvk libvirt run --name qt-demo --memory 4096 --cpus 2 \
  --filesystem ext4 --secure-boot-keys secureboot-keys --graphical-console \
  --replace localhost/centos-bootc-composefs:stream10

virt-viewer --connect qemu:///system qt-demo
```

If Secure Boot enforcement fails in your environment (see the nested-virt
note above), `--firmware uefi-insecure` in place of `--secure-boot-keys`
boots the same signed image with enforcement off — fine for viewing the
demo.

Swap `qtdemo/main.cpp` for your own Qt Widgets app and rebuild.

## Install to bare metal / a disk

Build with `./build.sh` first — `bootc install` here hits the same
digest-mismatch bug described above if the UKI wasn't corrected.

```sh
podman run --rm --privileged --pid=host \
  -v /var/lib/containers:/var/lib/containers \
  -v /dev:/dev --security-opt label=type:unconfined_t \
  localhost/centos-bootc-composefs:stream10 \
  bootc install to-disk --filesystem ext4 /dev/sdX
```

`bootc` selects the composefs backend automatically because the image
contains a UKI. `--filesystem ext4` still applies. The UKI is signed with
this repo's own local key (`secureboot-keys/db.crt`), which real hardware
doesn't trust by default — either disable Secure Boot in firmware settings,
or enroll `secureboot-keys/db.crt` into the machine's own MokManager/db.

## Persistent logs (`/var` stateless, `/var/log` persistent)

`/var/log` is bind-mounted from the writable root partition
(`/dev/vda3`, mounted at `/sysroot`):

```
systemd.mount-extra=/sysroot/state/os/default/var/log:/var/log:none:bind,nofail
```

That source is bootc's on-disk `/var` (shared across deployments, seeded at
install); it stays populated while the live `/var` is tmpfs.

```sh
findmnt /var/log            # bind mount backed by /dev/vda3
echo hi | systemd-cat ; reboot
journalctl -b -1 | tail     # previous boot's logs survived
touch /var/foo               # does NOT survive — /var is tmpfs
```

Logs share the root partition with the composefs store; `SystemMaxUse` caps
them. For hardware-level isolation, put `/var/log` on a dedicated
partition/disk and change `kargs.d/55-varlog-mount.toml` to mount it by
label, e.g. `systemd.mount-extra=LABEL=varlog:/var/log:ext4:nofail`.

## Updating an installed system

Each image version carries its own freshly sealed UKI — `ukify` never runs on
the installed machine. `bootc upgrade` pulls the new image, creates a new
composefs deployment, extracts its UKI into the ESP, and writes a BLS entry.
The previous deployment stays for rollback.

```sh
bootc status
bootc upgrade
bootc upgrade --apply
bootc switch quay.io/you/img:tag
bootc rollback
```

1. **Install from a registry ref, not `localhost/...`** — `bootc upgrade`
   pulls the recorded ref. Build → `podman push` → install from that ref (or
   `bootc switch` to repoint an existing install).
2. **Rebuild with `./build.sh` on every change**, not plain `podman build` —
   the UKI must carry the correct composefs digest for the new rootfs.
