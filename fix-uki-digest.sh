#!/usr/bin/env bash
# Corrects the composefs= digest embedded in an already-built image's UKI,
# then re-signs it (patching invalidates the Secure Boot signature).
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
# UKI -- the `composefs=<hex>` string is a fixed-length SHA-512 hex digest,
# so patching never changes the file's size. Patching invalidates the
# existing Secure Boot signature, so the script also strips it (via
# `pefile`, inside the image) and re-signs cleanly with the local Secure
# Boot key -- `sbsign` on an already-signed file APPENDS a second signature
# rather than replacing the first, and OVMF's verifier doesn't reliably
# accept multi-signed PE files, so a clean single signature is what
# actually boots. The result is genuinely, correctly sealed AND validly
# signed: a real fix, not a workaround that weakens sealing (compare to
# `--allow-missing-verity`, which does NOT help here -- see README).
#
# Safe to re-run: it's a no-op if the embedded digest already matches.
#
# Usage: ./fix-uki-digest.sh [image[:tag]] [key-dir]
set -euo pipefail

IMG="${1:-localhost/centos-bootc-composefs:stream10}"
KEYDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/${2:-secureboot-keys}"

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

echo ">> patching digest and stripping any existing signature (inside the image, via pefile)..."
RESULT="$(podman run --rm -i -v "$OUT":/work:Z "$IMG" python3 - "$CORRECT" <<'PYEOF'
import re, sys
import pefile

correct = sys.argv[1].encode()
path = "/work/uki.efi"
outpath = "/work/uki-unsigned.efi"

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

# Strip any existing Authenticode signature: the security data directory's
# VirtualAddress is a file offset (not an RVA) pointing at the trailing
# WIN_CERTIFICATE table; truncate it away and zero the directory entry.
pe = pefile.PE(data=bytes(data), fast_load=True)
sec_dir = pe.OPTIONAL_HEADER.DATA_DIRECTORY[pefile.DIRECTORY_ENTRY["IMAGE_DIRECTORY_ENTRY_SECURITY"]]
if sec_dir.Size:
    dir_offset = sec_dir.get_file_offset()
    data[dir_offset:dir_offset + 8] = b"\x00" * 8
    data = data[:sec_dir.VirtualAddress]
pe.close()

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

echo ">> signing with $KEYDIR/db.{key,crt}..."
if [ ! -f "$KEYDIR/db.key" ]; then
    echo "ERROR: $KEYDIR/db.key not found -- run ./gen-secureboot-keys.sh first" >&2
    exit 1
fi
podman run --rm \
    -v "$OUT/uki-unsigned.efi":/in.efi:ro \
    -v "$KEYDIR/db.key":/db.key:ro \
    -v "$KEYDIR/db.crt":/db.crt:ro \
    -v "$OUT":/out:Z \
    "$IMG" \
    sbsign --key /db.key --cert /db.crt --output /out/uki-fixed.efi /in.efi

echo ">> writing patched+resigned UKI back and committing..."
podman cp "$OUT/uki-fixed.efi" "$cid:$UKI_PATH"
podman commit "$cid" "$IMG" >/dev/null
echo ">> done. Re-verify with: ./diagnose-digest.sh $IMG"
