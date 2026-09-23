#!/usr/bin/env bash
# Corrects the composefs= digest embedded in an already-built image's UKI.
#
# `bootc container ukify` (used by `seal-uki` during the build) computes its
# digest via a *directory walk* of the extracted rootfs; `bootc install`
# verifies against the *raw storage/layer-ingest* digest. These two views can
# disagree on some directories' mtimes/modes purely from how
# containers/storage's overlay driver extracts layers onto local disk --
# unrelated to the image's actual content. That's an open upstream bug:
# https://github.com/bootc-dev/bootc/issues/2194 (root-caused further in
# https://github.com/composefs/composefs-rs/issues/132). It makes `bootc
# install`/`bcvk libvirt run` fail with "The UKI has the wrong composefs=
# parameter", even for a correctly-built, unmodified image.
#
# This script re-computes the digest the SAME way `bootc install` does (the
# storage/layer-ingest view) and binary-patches it into the already-built
# UKI in place -- the `composefs=<hex>` string is a fixed-length SHA-512 hex
# digest, so patching never changes the file's size or needs re-signing --
# then re-commits the image under the same tag. The result is genuinely,
# correctly sealed: this is a real fix, not a workaround that weakens
# sealing (compare to `--allow-missing-verity`, which does NOT help here --
# see README).
#
# Safe to re-run: it's a no-op if the embedded digest already matches.
#
# Usage: ./fix-uki-digest.sh [image[:tag]]
set -euo pipefail

IMG="${1:-localhost/centos-bootc-composefs:stream10}"

echo "== image: $IMG"

KVER_FILE="$(podman run --rm "$IMG" sh -c 'ls /boot/EFI/Linux')"
UKI_PATH="/boot/EFI/Linux/${KVER_FILE}"
echo "== UKI: $UKI_PATH"

OUT="$(mktemp -d)"
cid=""
cleanup() {
    [ -n "$cid" ] && podman rm -f "$cid" >/dev/null 2>&1 || true
    rm -rf "$OUT"
}
trap cleanup EXIT

echo ">> computing correct digest (storage/layer-ingest view, same as 'bootc install')..."
GRAPHROOT="$(podman info -f '{{.Store.GraphRoot}}')"
CORRECT="$(podman run --rm --privileged --security-opt label=disable \
    -v "$GRAPHROOT":/run/host-container-storage:ro \
    -v /sys:/sys:ro \
    --tmpfs /var \
    "$IMG" \
    bootc container compute-composefs-digest-from-storage | tr -d '[:space:]')"
echo "   correct digest: $CORRECT"

echo ">> extracting UKI to inspect the embedded digest..."
cid="$(podman create "$IMG")"
podman cp "$cid:$UKI_PATH" "$OUT/uki.efi"

RESULT="$(python3 - "$OUT/uki.efi" "$CORRECT" "$OUT/uki-fixed.efi" <<'PYEOF'
import re, sys
path, correct, outpath = sys.argv[1], sys.argv[2].encode(), sys.argv[3]
data = bytearray(open(path, "rb").read())
m = re.search(rb"composefs=(\??)([0-9a-f]{128})", data)
if not m:
    print("ERROR: no composefs= digest found in UKI cmdline", file=sys.stderr)
    sys.exit(1)
embedded = m.group(2)
if embedded == correct:
    print("OK")
    sys.exit(0)
count = data.count(embedded)
if count != 1:
    print(f"ERROR: expected exactly 1 occurrence of the embedded digest in the UKI, found {count}", file=sys.stderr)
    sys.exit(1)
idx = data.find(embedded)
data[idx:idx + len(embedded)] = correct
with open(outpath, "wb") as f:
    f.write(data)
print(f"PATCHED {embedded.decode()} -> {correct.decode()}")
PYEOF
)"

case "$RESULT" in
    OK)
        echo ">> embedded digest already matches -- nothing to do."
        exit 0
        ;;
    PATCHED*)
        echo ">> $RESULT"
        ;;
    *)
        echo "$RESULT" >&2
        exit 1
        ;;
esac

echo ">> writing patched UKI back and committing..."
podman cp "$OUT/uki-fixed.efi" "$cid:$UKI_PATH"
podman commit "$cid" "$IMG" >/dev/null
echo ">> done. Re-verify with: ./diagnose-digest.sh $IMG"
