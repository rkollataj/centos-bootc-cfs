#!/usr/bin/env bash
# Diagnose the "wrong composefs= parameter" install failure.
#
# It compares the two ways bootc computes the composefs digest of an image:
#   1. directory read  -> what `seal-uki`/`bootc container ukify` bakes into the UKI
#   2. OCI-layer read   -> what `bootc install` checks against
# If these differ, that's the root cause; the dumpfile diff shows which files'
# metadata (usually mtime) disagree.
set -euo pipefail

IMG="${1:-localhost/centos-bootc-composefs:stream10}"
OUT="$(mktemp -d)"
GRAPHROOT="$(podman info -f '{{.Store.GraphRoot}}')"

echo "== image: $IMG"
echo "== graphroot: $GRAPHROOT"
echo

echo ">> [1] directory view (what the UKI is sealed with):"
podman run --rm \
  --mount=type=image,source="$IMG",target=/target,rw=false \
  -v "$OUT":/out:Z \
  "$IMG" \
  bootc container compute-composefs-digest --write-dumpfile-to /out/dir.dump /target
echo

echo ">> [2] storage view (what bootc install checks against):"
# NB: no image arg — bootc uses the *running* container's own image id and
# resolves it in the mounted host store at /run/host-container-storage.
podman run --rm --privileged --security-opt label=disable \
  -v "$GRAPHROOT":/run/host-container-storage:ro \
  -v /sys:/sys:ro \
  -v "$OUT":/out:Z \
  --tmpfs /var \
  "$IMG" \
  bootc container compute-composefs-digest-from-storage --write-dumpfile-to /out/storage.dump
echo

echo ">> diff of the two views (dir vs storage), first 80 lines:"
if diff -u "$OUT/dir.dump" "$OUT/storage.dump" > "$OUT/diff.txt"; then
  echo "IDENTICAL — digests should match (mismatch is elsewhere)."
else
  head -80 "$OUT/diff.txt"
  echo
  echo "($(grep -c '^[-+]' "$OUT/diff.txt") changed lines total)"
fi
echo
echo "dumpfiles + full diff saved in: $OUT"
