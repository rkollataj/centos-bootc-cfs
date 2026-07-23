# Minimal CentOS Stream 10 bootc — sealed composefs UKI (unsigned)

A minimal [bootc](https://bootc.dev) base image on CentOS Stream 10 using the
experimental **composefs** backend, booted from a **sealed UKI** (Unified Kernel
Image). Image signing is skipped, so no keys are required.

- **Sealed:** the composefs digest of the root filesystem is computed at build
  time, baked into the UKI kernel command line (`composefs=<sha512>`), and
  *enforced at boot*. If the root fs doesn't match, it won't boot.
- **Unsigned:** the UKI itself carries no Secure Boot signature. That only
  removes firmware verification of the UKI; the root-fs fsverity seal is still
  enforced. See [docs](https://bootc.dev/bootc/experimental-composefs.html#using-without-secure-boot).
- **Transient `/etc`:** the seal only covers the read-only base image, not the
  writable `/etc`/`/var`. This image sets `/etc` to a **tmpfs overlay**
  (`/usr/lib/composefs/setup-root-conf.toml`, `[etc] transient = true`), so any
  runtime change to `/etc` is discarded on reboot — the writable overlay can't
  accumulate persistent tampering; `/etc` always resets to the sealed baseline.
  Consequence: files normally generated on first boot (SSH host keys,
  `machine-id`) regenerate every boot, so SSH clients will see the host key
  change between reboots. Remove the `setup-root-conf.toml` line to get a
  normal persistent `/etc`.
- **Stateless `/var`, persistent `/var/log` (reset-proof):** `/var` is a fresh
  **tmpfs** every boot (`systemd.volatile=state`), so a power loss can't corrupt
  persistent state — there is none. Logs still persist: `/var/log` is
  **bind-mounted from a directory on the writable root partition** via a
  `systemd.mount-extra=` karg (not `/etc/fstab`, which transient `/etc`
  discards). journald uses `Storage=persistent` with `SystemMaxUse=1G`. No extra
  partition or disk needed. See **Persistent logs** below.

## Build

```sh
podman build -f Containerfile -t localhost/centos-bootc-composefs:stream10 .
```

With Docker/buildx the same file works (it uses `RUN` heredocs and bind mounts).

## How it works

This mirrors bootc's own maintained sealed-UKI recipe (its repo-root
`Dockerfile` + `contrib/packaging/{seal-uki,finalize-uki}`, vendored here as
`seal-uki` / `finalize-uki`) rather than the prose docs' split-then-copy
pattern — the latter produces a build-time vs install-time composefs digest
mismatch ("The UKI has the wrong composefs= parameter ..."). The critical
difference: the **measured** rootfs keeps its kernel in `/usr/lib/modules`; the
kernel is only split out into a throwaway stage to feed `--kernel-dir`.

1. **rootfs** *(the measured tree)* — upgrade bootc, swap `bootupd` →
   `systemd-boot-unsigned`, add `systemd-ukify`, drop in the sealing scripts,
   ship a **`rw` kernel arg** (`kargs.d/00-rootfs-rw.toml` — required, since a
   UKI's cmdline is sealed at build time and `bootc install` can't add `rw`
   like it does for BLS boots; without it the physical root and `/var` mount
   read-only), ship `setup-root-conf.toml` (**transient `/etc`**, see below),
   and **regenerate the initramfs with the `bootc` (51bootc) dracut module**.
   That module ships `bootc-root-setup.service`, which at boot mounts the
   composefs root and sets up `/etc` + the `/var` bind-mount; without
   regenerating it the stock initramfs leaves `/etc` and `/var` read-only and
   most services fail. Kernel is **not** split here.
2. **kernel** — `bootc container split-kernel-and-rootfs` into `/kernel/<kver>/`;
   only this directory is consumed (as `--kernel-dir`). Never measured/shipped.
3. **sealed-uki** — `seal-uki` runs `bootc container ukify` against the measured
   rootfs, embedding the composefs digest, unsigned (`--seal-state unsealed`).
4. **final** — `FROM rootfs` (same measured tree) + `finalize-uki` copies the
   UKI to `/boot/EFI/Linux/`. `/boot` is excluded from the digest, so the seal
   stays valid. Then `bootc container lint`.

## Requirements / caveats

- **Recent bootc (handled automatically).** The `container ukify` /
  `split-kernel-and-rootfs` subcommands are experimental and the stream10 base
  image's bootc is too old for them, so the build upgrades bootc from the
  `rhcontainerbot/bootc` COPR (via `bootc-copr.repo`). Needs **network access at
  build time**; the newer bootc also lands in the final image (which the
  installed system needs for composefs `bootc upgrade`).
- **Install target needs an fsverity-capable root fs** (ext4 or btrfs). The
  build is strictly sealed (no `--allow-missing-verity`); on XFS it won't
  validate. To relax, add `--allow-missing-verity` to the `seal-uki` call in the
  Containerfile — note that makes the image *unsealed*.
- **Secure Boot** stays disabled (unsigned). To sign later, change the
  `sealed-uki` stage to `--seal-state sealed` and mount `secureboot_key` /
  `secureboot_cert` secrets (see `seal-uki`), passing them via
  `podman build --secret`.
- **Directory-mtime normalization.** `bootc container ukify` seals using a
  *directory read* of the rootfs (real dir mtimes), but `bootc install`
  recomputes the digest from the *OCI layers* (dir mtimes normalized to 0.0).
  On rootless/overlay builds these diverge, causing install to fail with
  "The UKI has the wrong composefs= parameter" (upstream
  [bootc#1498](https://github.com/bootc-dev/bootc/issues/1498)). The `rootfs`
  stage works around it by zeroing all directory mtimes as its last step — so
  **any extra `RUN` you add that creates directories must end with the same
  `find / -xdev -type d -exec touch -c -m -d @0 {} +`**, or the seal breaks
  again. `diagnose-digest.sh` compares the two digest views if you need to
  debug this.

## Run as a local VM (bcvk)

[`bcvk`](https://github.com/bootc-dev/bcvk) installs the image to a disk and
boots it under libvirt/QEMU — the full firmware → systemd-boot → UKI → composefs
chain. You **must** pass `--filesystem ext4`: the image is strictly sealed, so
the root fs needs fsverity, which `ext4` (or `btrfs`) provides but `xfs` — the
default — does not. Without it the install fails the seal.

```sh
# persistent VM (installs to a disk, then boots it):
bcvk libvirt run --name cfs-test --memory 4096 --cpus 2 \
  --filesystem ext4 \
  localhost/centos-bootc-composefs:stream10

# manage it afterwards:
virsh --connect qemu:///session list
virsh --connect qemu:///session console cfs-test
virsh --connect qemu:///session destroy cfs-test
virsh --connect qemu:///session undefine --nvram cfs-test   # remove
```

Host prerequisites (Arch): `qemu-full libvirt virtiofsd edk2-ovmf dnsmasq`
(plus `swtpm` only if you later test TPM measured boot).

> `bcvk ephemeral run` is **not** equivalent — it boots the container directly
> over virtiofs, skipping systemd-boot/UKI/composefs. Use `libvirt run` to
> exercise the sealed boot chain.

## Install to bare metal / a disk

```sh
podman run --rm --privileged --pid=host \
  -v /var/lib/containers:/var/lib/containers \
  -v /dev:/dev --security-opt label=type:unconfined_t \
  localhost/centos-bootc-composefs:stream10 \
  bootc install to-disk --filesystem ext4 /dev/sdX
```

Because the image contains a UKI, bootc automatically selects the composefs
backend during install. Note the same `--filesystem ext4` requirement applies.

## Persistent logs (`/var` stateless, `/var/log` persistent)

`/var` is a fresh **tmpfs** every boot (`systemd.volatile=state`) — reset-proof,
nothing persistent to corrupt. `/var/log` is made persistent by **bind-mounting
a directory from the writable root partition** (`/dev/vda3`, mounted at
`/sysroot`) onto it:

```
systemd.mount-extra=/sysroot/state/os/default/var/log:/var/log:none:bind,nofail
```

That source is bootc's on-disk `/var` (shared across deployments, seeded from the
image at install); it stays populated even while the live `/var` is tmpfs. **No
extra partition or disk needed — it works on the plain bcvk VM as-is.** journald
uses `Storage=persistent` with `SystemMaxUse=1G` so logs land in
`/var/log/journal` and can't fill the root partition.

Verify inside the VM (after a rebuild + recreate):

```sh
findmnt /var/log            # a bind mount backed by /dev/vda3
echo hi | systemd-cat ; reboot
journalctl -b -1 | tail     # previous boot's logs survived
touch /var/foo              # does NOT survive — /var is tmpfs (by design)
```

**Tradeoff:** logs share the root partition with the composefs store (not
isolated). The `SystemMaxUse` cap prevents them filling it. If you later want
**hardware-level isolation** — `/var/log` on its own filesystem so log I/O and
corruption can't touch the OS partition — put the log store on a dedicated
`/var/log` partition/disk (built with `bootc-image-builder`, or pre-created and
installed via `bootc install to-filesystem`) and change the karg in
`kargs.d/55-varlog-mount.toml` to mount it by label, e.g.
`systemd.mount-extra=LABEL=varlog:/var/log:ext4:nofail`.

For real hardware also consider shipping logs off-box (remote journald/syslog)
as the primary sink, with local `/var/log` as a buffer.

## Updating an installed system

The sealed UKI is baked into the image at build time, so **you never re-run
`ukify` on the machine** — each new image version carries its own freshly
sealed UKI. `bootc upgrade` pulls the new image, creates a new composefs
deployment, extracts that image's UKI into the ESP, and writes a BLS entry for
it. The previous deployment stays for rollback (A/B, reboot to apply).

```sh
bootc status            # booted / staged / rollback deployments
bootc upgrade           # pull newest of the current ref, stage for next boot
bootc upgrade --apply   # ...and reboot to apply
bootc switch quay.io/you/img:tag   # move to a different image ref
bootc rollback          # boot the previous deployment again
```

Two requirements:

1. **Install from a registry ref, not `localhost/...`.** `bootc install`
   records the image reference and `bootc upgrade` pulls *that* ref, so build →
   `podman push quay.io/you/...:stream10` → install from that ref. (If you
   installed from a local image, run `bootc switch quay.io/you/...:stream10`
   once to repoint the origin.)
2. **Rebuild via this Containerfile on every change** (the split + `ukify`
   stages), so the UKI carries the new rootfs's composefs digest. A plain
   `dnf update` inside a container without re-sealing would produce a mismatched
   UKI. Kernel updates are handled automatically (the kernel is re-embedded in
   each build). If you later add signing, every update's UKI must be signed too.
