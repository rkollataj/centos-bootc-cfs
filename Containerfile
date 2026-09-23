# syntax=docker/dockerfile:1.7-labs
#
# Minimal CentOS Stream 10 bootc image with a SEALED, SIGNED composefs UKI
# backend.
#
# This mirrors bootc's own maintained sealed-UKI recipe (the repo-root
# Dockerfile + contrib/packaging/{seal-uki,finalize-uki}) rather than the
# prose docs' split-then-copy pattern, which bootc's own comments call out as
# buggy (it produces a build-time vs install-time composefs digest mismatch:
# "The UKI has the wrong composefs= parameter ...").
#
# Key structural points that make the digest match at install time:
#   * The MEASURED rootfs (stage `rootfs`) keeps its kernel in
#     /usr/lib/modules/<kver>/ — it is NOT split. `split-kernel-and-rootfs`
#     runs only in a throwaway `kernel` stage that provides `--kernel-dir`.
#   * The UKI is produced by `seal-uki` and dropped into the final image by
#     `finalize-uki`, and the final stage is `FROM rootfs` (the same tree that
#     was measured), differing only by /boot — which is excluded from the
#     digest.
#
# "Sealed" vs "signed" are two independent axes here:
#   * seal (composefs digest enforced at boot)  -> controlled by
#     --allow-missing-verity (we OMIT it, so the digest is enforced; the
#     install-target root fs must support fsverity, i.e. ext4 or btrfs).
#   * signing (Secure Boot)                     -> `seal-uki --seal-state`;
#     we use `sealed` = SIGNED, with a local, gitignored key/cert pair
#     (`./gen-secureboot-keys.sh`, run automatically by `build.sh`) passed in
#     as build secrets. See README ("Secure Boot signing").
# Net result: an fsverity-sealed, Secure Boot-signed UKI.
#
# KNOWN BUILD-TIME BUG, WORKED AROUND BY `fix-uki-digest.sh`: `bootc container
# ukify` (in the `sealed-uki` stage) computes its digest via a directory walk
# of the extracted rootfs; `bootc install` verifies against the raw
# storage/layer-ingest digest. These can disagree on some directories'
# mtimes/modes purely from how containers/storage's overlay driver extracts
# layers onto local disk -- unrelated to this image's content. Open upstream
# bug: https://github.com/bootc-dev/bootc/issues/2194. `fix-uki-digest.sh`
# (run automatically by `build.sh`) re-computes the correct digest the same
# way `bootc install` does and binary-patches it into the built UKI, so the
# shipped image is genuinely, correctly sealed despite the upstream bug. See
# README for details.
#
# See: https://bootc.dev/bootc/experimental-composefs.html
#
# Build:
#   ./build.sh
# (equivalent to `podman build -f Containerfile -t <tag> .` followed by
# `./fix-uki-digest.sh <tag>` -- see README before using plain `podman build`.)
#
# Requires network at build time (COPR + gpg key fetch).

ARG BASE_IMAGE=quay.io/centos-bootc/centos-bootc:stream10

########################################################################
# Stage `rootfs`: the measured root filesystem (bootc's `base-penultimate`).
#
# All customization happens here. The kernel STAYS in /usr/lib/modules — do
# not split it out of this stage.
########################################################################
FROM ${BASE_IMAGE} AS rootfs

# The stream10 base image's bootc is too old for the composefs UKI
# subcommands, so pull a current bootc from the rhcontainerbot/bootc COPR
# (packit builds from git main for centos-stream-10). This newer bootc also
# ships in the final image, which the installed system needs for composefs
# `bootc upgrade`. The .repo file is removed in the same layer so it never ships.
COPY bootc-copr.repo /etc/yum.repos.d/_bootc-copr.repo

# Sealing helper scripts (copied verbatim from bootc contrib/packaging).
COPY seal-uki finalize-uki /usr/bin/

# `seal-uki --seal-state sealed` (used below) signs the UKI with `sbsign`,
# which isn't packaged for CentOS Stream 10 itself (`ukify`'s alternative,
# --signtool systemd-sbsign, is broken in this systemd version: its
# verify() unconditionally raises NotImplementedError, and make_uki() always
# calls it). sbsigntools is in EPEL 10; the epel-release package is removed
# again right after so EPEL isn't enabled in the shipped image.

# Swap the GRUB/bootupd stack for systemd-boot (the composefs UKI bootloader),
# upgrade bootc, add the ukify tool, and scrub dnf/runtime state in the SAME
# layer so `bootc container lint` stays happy.
#
# TRANSIENT /etc: /usr/lib/composefs/setup-root-conf.toml makes /etc a tmpfs
# overlay so ALL runtime edits to /etc are discarded on reboot — the writable
# overlay can't accumulate persistent tampering; /etc always resets to the
# sealed image baseline. (The baked root password lives in the sealed image
# /etc, so console login still works; SSH host keys and machine-id regenerate
# each boot, so SSH clients will see the host key change between boots.) Must be
# written BEFORE dracut so the 51bootc module bakes it into the initramfs.
#
# REGENERATE THE INITRAMFS with the `bootc` (51bootc) dracut module. This is
# what installs `bootc-root-setup.service` into the initramfs, which at boot
# mounts the composefs root, applies setup-root-conf.toml, and sets up /etc and
# the /var bind-mount. The stock centos-bootc initramfs doesn't match the
# upgraded bootc, so without this /etc and /var stay read-only and most
# services fail (logind, sshd-keygen, NetworkManager, random-seed, ...). Must
# run AFTER the bootc upgrade and BEFORE the kernel is split into the UKI.
#
# REQUIRED: /usr/lib/bootc/kargs.d/00-rootfs-rw.toml adds `rw` to the UKI
# cmdline. For BLS boots `bootc install` injects `root=UUID=… rw`, but a UKI's
# cmdline is sealed at build time and install won't touch it, so without `rw`
# the physical root mounts read-only and /var (a bind from it) is read-only —
# breaking logind, sshd-keygen, etc. (ukify embeds all of kargs.d.)
#
# STATELESS /var + PERSISTENT /var/log (reset-proof design):
#   * systemd.volatile=state -> /var is a fresh tmpfs every boot, so no
#     persistent writable state can be corrupted by a power loss.
#   * systemd.mount-extra=/sysroot/state/os/default/var/log:/var/log:none:bind
#     bind-mounts a persistent directory from the (writable) root partition onto
#     the tmpfs /var/log, so logs survive reboots WITHOUT needing a separate
#     partition or disk. That path is bootc's on-disk /var (shared across
#     deployments, seeded from the image at install); it stays populated even
#     when the live /var is volatile. We use a mount-extra KARG, not /etc/fstab,
#     because transient /etc discards fstab (bootc does the same for /boot; see
#     #1388). `nofail` keeps boot working if the path is ever absent.
#     NOTE: logs then share the root partition with the composefs store, so we
#     cap them below. For hardware isolation instead, put /var/log on a
#     dedicated partition and mount it by LABEL — see README.
#   * journald Storage=persistent + SystemMaxUse=1G -> logs land in
#     /var/log/journal on the root partition, capped so they can't fill it.
#     (Placed in /usr since transient /etc won't keep an /etc drop-in.)
#
# TEST-ONLY conveniences (remove for production):
#   * /usr/lib/bootc/kargs.d/10-console.toml adds console=ttyS0 so `virsh
#     console` shows boot output and a login prompt.
#   * `chpasswd` sets root's password to "root" for console login. Swap this
#     for an authorized SSH key if you prefer `bcvk libvirt ssh` (see README).
#
# The final `find ... touch -d @0` normalizes ALL directory mtimes to epoch 0.
# This is REQUIRED for the sealed digest to match at install time: `bootc
# container ukify` seals the UKI using a directory read of this rootfs (which
# sees real, build-time directory mtimes), but `bootc install` recomputes the
# digest from the OCI layers, where composefs normalizes directory mtimes to
# 0.0. Without this, the two digests differ and install fails with
# "The UKI has the wrong composefs= parameter". Must be the LAST thing in the
# layer so nothing re-bumps a directory mtime afterward. (Files/symlinks already
# match; only directory mtimes diverge.)
RUN set -eu; \
    chmod +x /usr/bin/seal-uki /usr/bin/finalize-uki; \
    dnf -y remove bootupd 2>/dev/null || true; \
    dnf -y upgrade bootc; \
    dnf -y install systemd-boot-unsigned systemd-ukify; \
    dnf -y install https://dl.fedoraproject.org/pub/epel/epel-release-latest-10.noarch.rpm; \
    dnf -y install sbsigntools; \
    dnf -y remove epel-release; \
    mkdir -p /usr/lib/composefs; \
    printf '[etc]\ntransient = true\n' \
        > /usr/lib/composefs/setup-root-conf.toml; \
    kver="$(ls -1 /usr/lib/modules | head -1)"; \
    dracut --force --no-hostonly --add bootc \
        --kver "$kver" "/usr/lib/modules/$kver/initramfs.img"; \
    dnf -y clean all; \
    rm -f /etc/yum.repos.d/_bootc-copr.repo; \
    rm -rf /var/cache/* /var/lib/dnf /var/lib/rhsm /var/log/* /run/* /tmp/* \
           /var/roothome/buildinfo; \
    mkdir -p /usr/lib/bootc/kargs.d; \
    printf 'kargs = ["rw"]\n' \
        > /usr/lib/bootc/kargs.d/00-rootfs-rw.toml; \
    printf 'kargs = ["console=tty0", "console=ttyS0,115200n8"]\n' \
        > /usr/lib/bootc/kargs.d/10-console.toml; \
    printf 'kargs = ["systemd.volatile=state"]\n' \
        > /usr/lib/bootc/kargs.d/50-var-volatile.toml; \
    printf 'kargs = ["systemd.mount-extra=/sysroot/state/os/default/var/log:/var/log:none:bind,nofail"]\n' \
        > /usr/lib/bootc/kargs.d/55-varlog-mount.toml; \
    mkdir -p /usr/lib/systemd/journald.conf.d; \
    printf '[Journal]\nStorage=persistent\nSystemMaxUse=1G\n' \
        > /usr/lib/systemd/journald.conf.d/10-persistent.conf; \
    echo 'root:root' | chpasswd; \
    find / -xdev -type d -exec touch -c -m -d @0 {} + 2>/dev/null || true

# ---- add your customizations here (packages, config, users, etc.) ----
# IMPORTANT: any RUN that creates directories re-bumps their mtimes and breaks
# the seal, so end each such RUN with the same cleanup + mtime-zeroing tail:
# RUN dnf -y install vim-minimal && dnf -y clean all && \
#     rm -rf /var/cache/* /var/lib/dnf /var/log/* /run/* /tmp/* && \
#     find / -xdev -type d -exec touch -c -m -d @0 {} + 2>/dev/null || true

########################################################################
# Qt demo: a fullscreen digital clock rendered via Qt's "eglfs" QPA
# platform plugin (EGL + DRM/KMS against /dev/dri/card*, software-
# rendered with Mesa llvmpipe on virtio-gpu) -- no Wayland, no X11, no
# compositor. Runs as a systemd service so it's visible as soon as the
# VM's display comes up (see README: "Qt demo app").
#
# NOT linuxfb: this kernel (RHEL/CentOS 10) doesn't create a legacy
# /dev/fb0 device node even though fbcon/virtio_gpudrmfb bind at boot --
# only DRM/KMS (/dev/dri/card*) is exposed to userspace. eglfs is Qt's
# modern replacement for framebuffer-only embedded targets anyway.
#
# Built here with a throwaway toolchain (gcc-c++/cmake/make and
# qt6-qtbase-devel) that is dnf-removed in this SAME RUN/layer, so only
# the qt6-qtbase-gui runtime (which also pulls in the Mesa/EGL/DRM libs
# eglfs needs), a font, and the compiled binary end up in the final
# image -- the same "build then strip in one layer" trick as the main
# RUN above, just scoped to this one add-on.
#
# The [Install] symlink is created directly under /usr/lib/systemd/system
# instead of via `systemctl enable` (which writes to /etc/systemd/system):
# same reasoning as the journald drop-in above -- transient /etc can't be
# relied on to hold it, while /usr is part of the sealed, measured tree.
########################################################################
COPY qtdemo/ /usr/src/qtdemo/
RUN set -eu; \
    dnf -y install qt6-qtbase-gui qt6-qtbase-devel gcc-c++ cmake make \
        dejavu-sans-fonts; \
    cmake -S /usr/src/qtdemo -B /usr/src/qtdemo/build -DCMAKE_BUILD_TYPE=Release; \
    cmake --build /usr/src/qtdemo/build; \
    install -Dm755 /usr/src/qtdemo/build/qtdemo /usr/bin/qtdemo; \
    install -Dm644 /usr/src/qtdemo/qt-demo.service \
        /usr/lib/systemd/system/qt-demo.service; \
    mkdir -p /usr/lib/systemd/system/multi-user.target.wants; \
    ln -sf ../qt-demo.service \
        /usr/lib/systemd/system/multi-user.target.wants/qt-demo.service; \
    dnf -y remove gcc-c++ cmake make qt6-qtbase-devel; \
    dnf -y clean all; \
    rm -rf /usr/src/qtdemo /var/cache/* /var/lib/dnf /var/lib/rhsm /var/log/* \
           /run/* /tmp/*; \
    find / -xdev -type d -exec touch -c -m -d @0 {} + 2>/dev/null || true

########################################################################
# Stage `kernel`: source of --kernel-dir only.
#
# Splits vmlinuz/initramfs into /kernel/<kver>/. We consume ONLY its /kernel
# directory (via a bind mount); this stage is never measured or shipped.
########################################################################
FROM rootfs AS kernel
RUN mkdir /kernel && \
    bootc container split-kernel-and-rootfs --rootfs / --output /kernel

########################################################################
# Stage `sealed-uki`: build the sealed, Secure Boot-signed UKI.
#
# `seal-uki` runs `bootc container ukify`, which computes the composefs digest
# of --target, embeds it in the cmdline, and invokes ukify. No
# --allow-missing-verity => the composefs digest is strictly enforced at boot.
#
# --seal-state sealed signs the UKI with the `secureboot_key`/`secureboot_cert`
# build secrets (the local "db" key/cert from `gen-secureboot-keys.sh`, passed
# via `build.sh`'s `podman build --secret`). Those never touch the image
# itself -- BuildKit/buildah secrets are only mounted into this RUN's
# ephemeral container, not committed to any layer.
#
# CAVEAT: the digest `ukify` computes here (a directory walk of the extracted
# rootfs) is known to disagree with what `bootc install` verifies against (the
# raw storage/layer-ingest digest) on some images, due to an open upstream bug
# unrelated to this image's content: containers/storage's overlay driver
# doesn't preserve some directories' extracted mtimes/modes, and that leaks
# into ukify's walk. https://github.com/bootc-dev/bootc/issues/2194. This
# repo's `fix-uki-digest.sh` corrects the embedded digest after build (see
# README) — `build.sh` runs it automatically. Once the upstream bug is fixed,
# both should become no-ops.
########################################################################
FROM rootfs AS sealed-uki
RUN --mount=type=bind,from=rootfs,src=/,target=/run/target \
    --mount=type=bind,from=kernel,src=/kernel,target=/run/kernel \
    --mount=type=secret,id=secureboot_key \
    --mount=type=secret,id=secureboot_cert <<'EORUN'
set -euo pipefail
kver="$(ls /run/kernel)"
/usr/bin/seal-uki \
    --target /run/target \
    --output /out \
    --kernel-dir "/run/kernel/${kver}" \
    --seal-state sealed \
    --secrets /run/secrets
EORUN

########################################################################
# Final image: FROM rootfs (the measured tree) + the sealed UKI in /boot.
#
# `finalize-uki` copies /out/<kver>.efi to /boot/EFI/Linux/<kver>.efi. /boot is
# excluded from the composefs digest, so this keeps the seal valid.
########################################################################
FROM rootfs
RUN --mount=type=bind,from=kernel,src=/kernel,target=/run/kernel \
    --mount=type=bind,from=sealed-uki,src=/,target=/run/sealed-uki <<'EORUN'
set -euo pipefail
kver="$(ls /run/kernel)"
/usr/bin/finalize-uki /run/sealed-uki/out "${kver}"
EORUN

# Static analysis on the finished image.
RUN bootc container lint --fatal-warnings
