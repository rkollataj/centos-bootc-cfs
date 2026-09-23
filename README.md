# Minimal CentOS Stream 10 bootc — sealed composefs UKI (unsigned)

A minimal [bootc](https://bootc.dev) base image on CentOS Stream 10 using the
experimental **composefs** backend, booted from a **sealed UKI** (Unified
Kernel Image). Image signing is skipped, so no keys are required.

- **Sealed:** the composefs digest of the root filesystem is computed at
  build time, baked into the UKI kernel command line (`composefs=<sha512>`),
  and enforced at boot. If the root fs doesn't match, it won't boot.
- **Unsigned:** the UKI carries no Secure Boot signature. The root-fs
  fsverity seal is still enforced independently of that. See
  [docs](https://bootc.dev/bootc/experimental-composefs.html#using-without-secure-boot).
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
- **Python 3** on the host — used by `fix-uki-digest.sh`.
- **Network access at build time** (COPR + gpg key fetch).

```sh
sudo apt install podman python3
```

### To run it as a local VM (`bcvk`)

- **[`bcvk`](https://github.com/bootc-dev/bcvk)** — install a prebuilt binary
  from its [releases page](https://github.com/bootc-dev/bcvk/releases) or via
  `cargo install`.
- **QEMU + libvirt stack**:
  ```sh
  sudo apt install qemu-system-x86 qemu-utils libvirt-daemon-system \
      libvirt-clients virtiofsd ovmf dnsmasq-base swtpm virt-viewer
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

Runs `podman build` (also works with Docker/buildx) and then
`fix-uki-digest.sh`, which corrects the UKI's embedded composefs digest (see
**Requirements / caveats**). Pass a tag as `./build.sh your/tag:here`.
Re-running is safe — the fix step no-ops once the digest already matches.

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
   measured rootfs, embedding the composefs digest, unsigned
   (`--seal-state unsealed`).
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
- **Secure Boot** stays disabled (unsigned). To sign, change `sealed-uki` to
  `--seal-state sealed` and mount `secureboot_key`/`secureboot_cert` secrets
  via `podman build --secret`.
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
  (the same view `bootc install` uses) and binary-patches that value into the
  built UKI (`composefs=<sha512-hex>` is a fixed-length string, so the patch
  doesn't change file size). `diagnose-digest.sh` compares both digest views
  for debugging.

## Run as a local VM (bcvk)

`--filesystem ext4` is required (fsverity; `xfs`, the default, doesn't
support it). `--firmware uefi-insecure` is required because the UKI is
unsigned and `bcvk`'s default firmware has Secure Boot enabled (without it:
`Access Denied -- rejected probably by Secure Boot`, stuck at the boot
manager).

```sh
bcvk libvirt run --name cfs-test --memory 4096 --cpus 2 \
  --filesystem ext4 --firmware uefi-insecure \
  localhost/centos-bootc-composefs:stream10

# re-create (replaces an existing VM of the same name):
bcvk libvirt run --name cfs-test --memory 4096 --cpus 2 \
  --filesystem ext4 --firmware uefi-insecure --replace \
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
  --filesystem ext4 --firmware uefi-insecure --graphical-console --replace \
  localhost/centos-bootc-composefs:stream10

virt-viewer --connect qemu:///system qt-demo
```

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
contains a UKI. `--filesystem ext4` still applies. Real hardware needs
Secure Boot disabled in firmware settings (the UKI is unsigned).

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
